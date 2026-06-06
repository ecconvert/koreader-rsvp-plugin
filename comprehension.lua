--[[--
Comprehension test module for FastReader plugin.
Generates multiple-choice questions via LLM after an RSVP session.
--]]--

local json = require("dkjson")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local ButtonDialog = require("ui/widget/buttondialog")
local InputDialog = require("ui/widget/inputdialog")
local TextViewer = require("ui/widget/textviewer")
local Screen = require("device").screen
local logger = require("logger")
local socket = require("socket")
local http = require("socket.http")
require("ssl.https")  -- registers the https scheme handler used by http.request
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local _ = require("gettext")
local T = require("ffi/util").template

local OPENROUTER_ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"
local GROQ_ENDPOINT = "https://api.groq.com/openai/v1/chat/completions"

local OPENROUTER_MODELS = {
    { id = "google/gemini-flash-1.5-8b:free", label = "Gemini Flash 1.5 8B (free)" },
    { id = "nvidia/llama-3.1-nemotron-70b-instruct:free", label = "Nemotron 70B (free)" },
    { id = "meta-llama/llama-3.2-3b-instruct:free", label = "Llama 3.2 3B (free, fastest)" },
    { id = "mistralai/mistral-7b-instruct:free", label = "Mistral 7B (free)" },
    { id = "custom", label = "Custom model..." },
}

local GROQ_MODELS = {
    { id = "llama-3.3-70b-versatile", label = "Llama 3.3 70B Versatile" },
    { id = "llama-3.1-8b-instant", label = "Llama 3.1 8B Instant (fastest)" },
    { id = "gemma2-9b-it", label = "Gemma 2 9B" },
    { id = "mixtral-8x7b-32768", label = "Mixtral 8x7B" },
    { id = "custom", label = "Custom model..." },
}

local Comprehension = {}
Comprehension.__index = Comprehension

function Comprehension:new(settings)
    local o = setmetatable({}, self)
    o.settings = settings
    o.log_file = DataStorage:getSettingsDir() .. "/fastreader_comprehension_log.lua"
    o.log = LuaSettings:open(o.log_file)
    return o
end

-- Load API key: UI-stored key takes priority; fall back to dev settings file.
function Comprehension:getApiKey(provider)
    local key = self.settings:readSetting("comprehension_" .. provider .. "_api_key")
    if key and key ~= "" then
        return key
    end
    -- Dev fallback: read from a plain settings file next to the plugin
    local dev_file = DataStorage:getSettingsDir() .. "/fastreader_dev.lua"
    local dev = LuaSettings:open(dev_file)
    return dev:readSetting(provider .. "_api_key")
end

function Comprehension:getProvider()
    return self.settings:readSetting("comprehension_provider") or "groq"
end

function Comprehension:getModel()
    return self.settings:readSetting("comprehension_model") or "llama-3.1-8b-instant"
end

function Comprehension:getBaseQuestions()
    return self.settings:readSetting("comprehension_question_count") or 3
end

function Comprehension:getWordsPerExtraQuestion()
    return self.settings:readSetting("comprehension_words_per_extra") or 100
end

function Comprehension:getExtraQuestionsPerInterval()
    return self.settings:readSetting("comprehension_extra_per_interval") or 1
end

function Comprehension:calcQuestionCount(word_count)
    local base = self:getBaseQuestions()
    local words_per = self:getWordsPerExtraQuestion()
    local extra_per = self:getExtraQuestionsPerInterval()
    local extra = math.floor(word_count / words_per) * extra_per
    return math.min(base + extra, 20)
end

function Comprehension:getBufferSize()
    return self.settings:readSetting("comprehension_buffer_size") or 50000
end

-- Truncate word list to the rolling buffer size.
function Comprehension:trimBuffer(words)
    local limit = self:getBufferSize()
    if #words <= limit then
        return words
    end
    local trimmed = {}
    local start = #words - limit + 1
    for i = start, #words do
        table.insert(trimmed, words[i])
    end
    return trimmed
end

function Comprehension:buildPrompt(words, book_meta, avoid_questions, count)
    local text = table.concat(words, " ")
    count = count or self:calcQuestionCount(#words)
    local title = book_meta.title or "Unknown"
    local author = book_meta.author or "Unknown"
    local subject = book_meta.subject or ""

    local meta_line = string.format('Book: "%s" by %s', title, author)
    if subject ~= "" then
        meta_line = meta_line .. " | Subject: " .. subject
    end

    -- When the reader asks for more questions, tell the model what it already
    -- asked so it produces fresh ones instead of repeating itself.
    local avoid_block = ""
    if avoid_questions and #avoid_questions > 0 then
        local items = {}
        for _, qtext in ipairs(avoid_questions) do
            table.insert(items, "- " .. qtext)
        end
        avoid_block = "\n\nThese questions have already been asked. Generate DIFFERENT questions covering other parts of the passage. Do NOT repeat or rephrase any of these:\n"
            .. table.concat(items, "\n")
    end

    local template = "You are a reading comprehension tutor. Generate exactly %d multiple-choice questions based on the passage below.\n\n"
        .. "%s\n\nPASSAGE:\n%s%s\n\n"
        .. 'Return ONLY a JSON object with no extra text or markdown. The object must have a single key "questions" whose value is an array of %d items. Each item must have:\n'
        .. '- "question": string\n'
        .. '- "options": array of exactly 4 strings (A, B, C, D)\n'
        .. '- "correct": 0-indexed integer (0=A, 1=B, 2=C, 3=D)\n'
        .. '- "explanation": one short sentence explaining the correct answer\n\n'
        .. 'Example: {"questions":[{"question":"...","options":["...","...","...","..."],"correct":0,"explanation":"..."}]}'
    return string.format(template, count, meta_line, text, avoid_block, count)
end

-- HTTPS POST using KOReader's built-in socketutil/ltn12 pattern.
function Comprehension:httpPost(url, headers, body)
    local sink = {}
    headers["Content-Length"] = tostring(#body)

    local request = {
        url     = url,
        method  = "POST",
        headers = headers,
        source  = ltn12.source.string(body),
        sink    = ltn12.sink.table(sink),
    }

    socketutil:set_timeout(20, 60)
    local code, _, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    local response_body = table.concat(sink)
    logger.dbg("Comprehension: HTTP response code=" .. tostring(code) .. " status=" .. tostring(status))
    if code ~= 200 then
        logger.warn("Comprehension: HTTP error", status, response_body:sub(1, 200))
        return nil, string.format("HTTP error %s: %s", tostring(code), response_body:sub(1, 150))
    end
    if response_body == "" then
        return nil, "Empty response body"
    end
    return response_body
end

function Comprehension:callLLM(prompt)
    local provider = self:getProvider()
    local model = self:getModel()
    local api_key = self:getApiKey(provider)

    if not api_key or api_key == "" then
        return nil, _("No API key configured. Go to Settings → FastReader → Comprehension to add one.")
    end

    local endpoint = provider == "groq" and GROQ_ENDPOINT or OPENROUTER_ENDPOINT
    logger.dbg("Comprehension: provider=" .. provider .. " model=" .. model)

    -- Scale token budget with question count so larger tests don't get
    -- truncated mid-JSON (~250 tokens per MCQ, with headroom).
    local max_tokens = math.max(1024, self:calcQuestionCount(self:getBufferSize()) * 300)

    local request_body = json.encode({
        model = model,
        messages = {
            { role = "user", content = prompt }
        },
        -- Slightly higher temperature gives variety across "more questions" rounds.
        temperature = 0.6,
        max_tokens = max_tokens,
        -- JSON mode: both OpenRouter and Groq honor this and guarantee parseable
        -- output (requires the word "JSON" in the prompt, which buildPrompt includes).
        response_format = { type = "json_object" },
    })

    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. api_key,
    }

    local response_body, err = self:httpPost(endpoint, headers, request_body)
    if not response_body then
        return nil, _("Network error: ") .. tostring(err)
    end

    local parsed, _, parse_err = json.decode(response_body)
    if not parsed then
        return nil, _("Failed to parse API response: ") .. tostring(parse_err)
    end

    if parsed.error then
        return nil, _("API error: ") .. (parsed.error.message or tostring(parsed.error))
    end

    local content = parsed.choices
        and parsed.choices[1]
        and parsed.choices[1].message
        and parsed.choices[1].message.content

    if not content then
        return nil, _("Unexpected API response format")
    end

    return content
end

function Comprehension:parseQuestions(content)
    -- Strip markdown code fences if present
    local clean = content:gsub("^```[%w]*\n?", ""):gsub("\n?```$", ""):match("^%s*(.-)%s*$")

    local decoded, _, err = json.decode(clean)
    if not decoded then
        -- Fallback: try to locate a JSON object or array anywhere in the string
        local json_start = clean:find("[%[{]")
        if json_start then
            decoded, _, err = json.decode(clean:sub(json_start))
        end
        if not decoded then
            return nil, "JSON parse failed: " .. tostring(err)
        end
    end

    -- Accept either a bare array or an object wrapping it under "questions".
    local questions = decoded
    if decoded.questions ~= nil then
        questions = decoded.questions
    end
    if type(questions) ~= "table" or #questions == 0 then
        return nil, "No questions array found in response"
    end

    -- Validate structure
    for i, q in ipairs(questions) do
        if type(q.question) ~= "string"
            or type(q.options) ~= "table"
            or #q.options ~= 4
            or type(q.correct) ~= "number" then
            return nil, string.format("Question %d has invalid structure", i)
        end
        -- Coerce correct index into the valid 0-3 range. Some models return
        -- 1-indexed answers or values out of range; clamp rather than crash.
        q.correct = math.floor(q.correct)
        if q.correct < 0 or q.correct > 3 then
            -- If it looks 1-indexed (1-4), shift down; otherwise clamp to 0.
            if q.correct >= 1 and q.correct <= 4 then
                q.correct = q.correct - 1
            else
                q.correct = 0
            end
        end
    end

    return questions
end

function Comprehension:saveResult(doc_hash, result)
    local history = self.log:readSetting(doc_hash) or {}
    table.insert(history, {
        timestamp = os.time(),
        score = result.score,
        total = result.total,
        questions = result.questions,
    })
    -- Keep last 20 test results per book
    while #history > 20 do
        table.remove(history, 1)
    end
    self.log:saveSetting(doc_hash, history)
    self.log:flush()
end

local OPTION_LABELS = {"A", "B", "C", "D"}

function Comprehension:runTest(questions, doc_hash, words, book_meta, prior_results)
    -- results accumulates across "more questions" rounds so the final review
    -- shows every question answered, not just the latest round.
    local results = prior_results or {}
    local current_q = 1

    local function showQuestion()
        if current_q > #questions then
            self:showResults(results, doc_hash, words, book_meta)
            return
        end

        local q = questions[current_q]
        local is_last = (current_q == #questions)
        local buttons = {}
        for i, opt in ipairs(q.options) do
            local label = OPTION_LABELS[i]
            local opt_text = label .. ". " .. opt
            local idx = i
            table.insert(buttons, {
                {
                    text = opt_text,
                    align = "left",
                    callback = function()
                        UIManager:close(self.current_dialog)
                        local correct = (idx - 1) == q.correct
                        local result = {
                            question = q.question,
                            chosen = idx - 1,
                            correct_idx = q.correct,
                            options = q.options,
                            explanation = q.explanation,
                            is_correct = correct,
                        }
                        table.insert(results, result)
                        self:showFeedback(result, is_last, function()
                            current_q = current_q + 1
                            showQuestion()
                        end, function()
                            -- Regenerate, carrying answered results forward.
                            self:startTest(words, book_meta, doc_hash, results)
                        end)
                    end,
                }
            })
        end

        local progress = string.format(_("Question %d of %d"), current_q, #questions)
        self.current_dialog = ButtonDialog:new{
            title = progress .. "\n\n" .. q.question,
            buttons = buttons,
        }
        UIManager:show(self.current_dialog)
    end

    showQuestion()
end

function Comprehension:showFeedback(result, is_last, on_continue, on_more)
    local mark = result.is_correct and "✓ Correct!" or "✗ Wrong"
    local lines = { mark, "" }

    if not result.is_correct then
        table.insert(lines, _("Correct answer:"))
        table.insert(lines, OPTION_LABELS[result.correct_idx + 1] .. ". " .. result.options[result.correct_idx + 1])
        table.insert(lines, "")
    end

    if result.explanation and result.explanation ~= "" then
        table.insert(lines, result.explanation)
    end

    local next_row = {
        {
            text = is_last and _("Results →") or _("Next →"),
            callback = function()
                UIManager:close(self.feedback_dialog)
                on_continue()
            end,
        }
    }
    if is_last then
        table.insert(next_row, {
            text = _("More questions"),
            callback = function()
                UIManager:close(self.feedback_dialog)
                on_more()
            end,
        })
    end

    self.feedback_dialog = ButtonDialog:new{
        title = table.concat(lines, "\n"),
        buttons = { next_row },
    }
    UIManager:show(self.feedback_dialog)
end

function Comprehension:showResults(results, doc_hash, words, book_meta)
    local score = 0
    for _, r in ipairs(results) do
        if r.is_correct then score = score + 1 end
    end

    local lines = {}
    table.insert(lines, string.format(_("Score: %d / %d"), score, #results))
    table.insert(lines, "")

    for i, r in ipairs(results) do
        local mark = r.is_correct and "✓" or "✗"
        table.insert(lines, string.format("%s Q%d: %s", mark, i, r.question))
        -- Always show what the user chose
        table.insert(lines, string.format(
            _("   Your answer: %s. %s"),
            OPTION_LABELS[r.chosen + 1], r.options[r.chosen + 1]))
        if not r.is_correct then
            -- Show correct answer on wrong answers
            table.insert(lines, string.format(
                _("   Correct: %s. %s"),
                OPTION_LABELS[r.correct_idx + 1], r.options[r.correct_idx + 1]))
        end
        -- Always show explanation
        if r.explanation and r.explanation ~= "" then
            table.insert(lines, "   " .. r.explanation)
        end
        table.insert(lines, "")
    end

    self:saveResult(doc_hash, {
        score = score,
        total = #results,
        questions = results,
    })

    local buttons = {}
    if words and book_meta then
        table.insert(buttons, {
            {
                text = _("More questions"),
                callback = function()
                    UIManager:close(self._results_viewer)
                    -- Carry results forward so the next review accumulates.
                    self:startTest(words, book_meta, doc_hash, results)
                end,
            },
            {
                text = _("Close"),
                callback = function()
                    UIManager:close(self._results_viewer)
                end,
            },
        })
    end

    self._results_viewer = TextViewer:new{
        title = _("Comprehension Results"),
        text = table.concat(lines, "\n"),
        width = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.85),
        buttons_table = #buttons > 0 and buttons or nil,
    }
    UIManager:show(self._results_viewer)
end

-- Entry point called from FastReader:stopRSVP()
function Comprehension:offerTest(words, book_meta, doc_hash)
    local min_words = 30
    if #words < min_words then
        return
    end

    UIManager:show(ConfirmBox:new{
        text = _("Would you like to take a comprehension test based on what you just read?"),
        ok_text = _("Yes, test me"),
        cancel_text = _("No thanks"),
        ok_callback = function()
            self:startTest(words, book_meta, doc_hash)
        end,
    })
end

function Comprehension:startTest(words, book_meta, doc_hash, prior_results)
    local buffer = self:trimBuffer(words)
    local count = self:calcQuestionCount(#buffer)

    -- Collect already-asked questions so regeneration produces fresh ones.
    local avoid = {}
    if prior_results then
        for _, r in ipairs(prior_results) do
            table.insert(avoid, r.question)
        end
    end

    local prompt = self:buildPrompt(buffer, book_meta, avoid, count)

    local generating_msg = InfoMessage:new{ text = _("Generating questions…") }
    UIManager:show(generating_msg)
    UIManager:forceRePaint()

    -- Blocking call — runs synchronously
    local content, err = self:callLLM(prompt)

    UIManager:close(generating_msg)

    if not content then
        UIManager:show(InfoMessage:new{ text = err, timeout = 4 })
        return
    end

    local questions, parse_err = self:parseQuestions(content)
    if not questions then
        logger.warn("FastReader: question parse failed (" .. tostring(parse_err) .. "), retrying")
        local generating_msg2 = InfoMessage:new{ text = _("Retrying…") }
        UIManager:show(generating_msg2)
        UIManager:forceRePaint()
        content, err = self:callLLM(prompt)
        UIManager:close(generating_msg2)
        if content then
            questions, parse_err = self:parseQuestions(content)
        end
        if not questions then
            UIManager:show(InfoMessage:new{
                text = _("Could not generate questions. Please try again."),
                timeout = 3,
            })
            return
        end
    end

    self:runTest(questions, doc_hash, words, book_meta, prior_results)
end

-- Settings UI items to inject into FastReader's menu
function Comprehension:getMenuItems()
    return {
        {
            text = _("Comprehension Tests"),
            sub_item_table = {
                {
                    text_func = function()
                        local p = self:getProvider()
                        return T(_("Provider: %1"), p == "groq" and "Groq" or "OpenRouter")
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        UIManager:show(ButtonDialog:new{
                            title = _("Select LLM Provider"),
                            buttons = {
                                {{
                                    text = "OpenRouter",
                                    callback = function()
                                        UIManager:close(self._provider_dialog)
                                        self.settings:saveSetting("comprehension_provider", "openrouter")
                                        -- reset model to provider default
                                        self.settings:saveSetting("comprehension_model", "google/gemini-flash-1.5-8b:free")
                                        self.settings:flush()
                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                    end,
                                }},
                                {{
                                    text = "Groq",
                                    callback = function()
                                        UIManager:close(self._provider_dialog)
                                        self.settings:saveSetting("comprehension_provider", "groq")
                                        self.settings:saveSetting("comprehension_model", "llama-3.3-70b-versatile")
                                        self.settings:flush()
                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                    end,
                                }},
                            },
                        })
                    end,
                },
                {
                    text_func = function()
                        return T(_("Model: %1"), self:getModel())
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local prov = self:getProvider()
                        local models = prov == "groq" and GROQ_MODELS or OPENROUTER_MODELS
                        local buttons = {}
                        for _, m in ipairs(models) do
                            local model_id = m.id
                            if model_id == "custom" then
                                table.insert(buttons, {{
                                    text = m.label,
                                    callback = function()
                                        UIManager:close(self._model_dialog)
                                        local input = InputDialog:new{
                                            title = _("Enter model ID"),
                                            input = self:getModel(),
                                            input_type = "string",
                                            buttons = {{
                                                {
                                                    text = _("Cancel"),
                                                    callback = function()
                                                        UIManager:close(input)
                                                    end,
                                                },
                                                {
                                                    text = _("Save"),
                                                    is_enter_default = true,
                                                    callback = function()
                                                        local val = input:getInputText()
                                                        if val and val ~= "" then
                                                            self.settings:saveSetting("comprehension_model", val)
                                                            self.settings:flush()
                                                        end
                                                        UIManager:close(input)
                                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                                    end,
                                                },
                                            }},
                                        }
                                        UIManager:show(input)
                                    end,
                                }})
                            else
                                table.insert(buttons, {{
                                    text = m.label,
                                    callback = function()
                                        UIManager:close(self._model_dialog)
                                        self.settings:saveSetting("comprehension_model", model_id)
                                        self.settings:flush()
                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                    end,
                                }})
                            end
                        end
                        self._model_dialog = ButtonDialog:new{
                            title = _("Select Model"),
                            buttons = buttons,
                        }
                        UIManager:show(self._model_dialog)
                    end,
                },
                {
                    text = _("Set API Key"),
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local prov = self:getProvider()
                        local existing = self.settings:readSetting("comprehension_" .. prov .. "_api_key") or ""
                        local input = InputDialog:new{
                            title = T(_("%1 API Key"), prov == "groq" and "Groq" or "OpenRouter"),
                            input = existing,
                            input_type = "string",
                            description = _("Key is stored in plaintext in KOReader settings."),
                            buttons = {{
                                {
                                    text = _("Cancel"),
                                    callback = function() UIManager:close(input) end,
                                },
                                {
                                    text = _("Save"),
                                    is_enter_default = true,
                                    callback = function()
                                        local val = input:getInputText()
                                        self.settings:saveSetting("comprehension_" .. prov .. "_api_key", val or "")
                                        self.settings:flush()
                                        UIManager:close(input)
                                    end,
                                },
                            }},
                        }
                        UIManager:show(input)
                    end,
                },
                {
                    text_func = function()
                        return T(_("Base questions: %1"), self:getBaseQuestions())
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local SpinWidget = require("ui/widget/spinwidget")
                        UIManager:show(SpinWidget:new{
                            title_text = _("Base questions"),
                            info_text = _("Minimum questions regardless of passage length"),
                            value = self:getBaseQuestions(),
                            value_min = 1,
                            value_max = 20,
                            value_step = 1,
                            default_value = 3,
                            callback = function(spin)
                                self.settings:saveSetting("comprehension_question_count", spin.value)
                                self.settings:flush()
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                            end,
                        })
                    end,
                },
                {
                    text_func = function()
                        return T(_("Words per extra question: %1"), self:getWordsPerExtraQuestion())
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local SpinWidget = require("ui/widget/spinwidget")
                        UIManager:show(SpinWidget:new{
                            title_text = _("Words per extra question"),
                            info_text = _("Earn 1 extra question for every N words read"),
                            value = self:getWordsPerExtraQuestion(),
                            value_min = 10,
                            value_max = 1000,
                            value_step = 10,
                            default_value = 100,
                            unit = _("words"),
                            callback = function(spin)
                                self.settings:saveSetting("comprehension_words_per_extra", spin.value)
                                self.settings:flush()
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                            end,
                        })
                    end,
                },
                {
                    text_func = function()
                        return T(_("Extra questions per interval: %1"), self:getExtraQuestionsPerInterval())
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local SpinWidget = require("ui/widget/spinwidget")
                        UIManager:show(SpinWidget:new{
                            title_text = _("Extra questions per interval"),
                            value = self:getExtraQuestionsPerInterval(),
                            value_min = 1,
                            value_max = 5,
                            value_step = 1,
                            default_value = 1,
                            callback = function(spin)
                                self.settings:saveSetting("comprehension_extra_per_interval", spin.value)
                                self.settings:flush()
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                            end,
                        })
                    end,
                },
                {
                    text_func = function()
                        return T(_("Word buffer size: %1"), self:getBufferSize())
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local SpinWidget = require("ui/widget/spinwidget")
                        UIManager:show(SpinWidget:new{
                            title_text = _("Word buffer size"),
                            info_text = _("Last N words sent to LLM for question generation"),
                            value = self:getBufferSize(),
                            value_min = 100,
                            value_max = 100000,
                            value_step = 1000,
                            default_value = 50000,
                            unit = _("words"),
                            callback = function(spin)
                                self.settings:saveSetting("comprehension_buffer_size", spin.value)
                                self.settings:flush()
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                            end,
                        })
                    end,
                },
            },
        },
    }
end

return Comprehension
