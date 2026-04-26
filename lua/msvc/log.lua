---@class MsvcLog
---@field level integer
---@field lines string[]
---@field max_lines integer
---@field _enabled boolean

local MsvcLog = {}
MsvcLog.__index = MsvcLog

local levels = vim.log.levels

local NAME_TO_LEVEL = {
    trace = levels.TRACE,
    debug = levels.DEBUG,
    info = levels.INFO,
    warn = levels.WARN,
    error = levels.ERROR,
}

local LEVEL_TO_NAME = {
    [levels.TRACE] = "TRACE",
    [levels.DEBUG] = "DEBUG",
    [levels.INFO] = "INFO",
    [levels.WARN] = "WARN",
    [levels.ERROR] = "ERROR",
}

local TITLE = "msvc"

--- Construct a new MsvcLog instance.
--- @return MsvcLog
function MsvcLog:new()
    return setmetatable({
        level = levels.INFO,
        lines = {},
        max_lines = 50,
        _enabled = true,
    }, self)
end

--- Set the active log level.
--- @param name_or_number string|integer
function MsvcLog:set_level(name_or_number)
    if type(name_or_number) == "string" then
        local lvl = NAME_TO_LEVEL[string.lower(name_or_number)]
        if lvl == nil then
            error(("msvc.log: unknown level name %q"):format(name_or_number), 2)
        end
        self.level = lvl
    elseif type(name_or_number) == "number" then
        self.level = name_or_number
    else
        error("msvc.log: set_level expects string or number", 2)
    end
end

function MsvcLog:enable()
    self._enabled = true
end

function MsvcLog:disable()
    self._enabled = false
end

function MsvcLog:clear()
    self.lines = {}
end

--- Append a raw message to the in-memory ring buffer.
--- @param msg string
function MsvcLog:log(msg)
    if type(msg) ~= "string" then
        msg = tostring(msg)
    end
    self.lines[#self.lines + 1] = msg
    while #self.lines > self.max_lines do
        table.remove(self.lines, 1)
    end
end

local function format_msg(msg, ...)
    if type(msg) ~= "string" then
        msg = tostring(msg)
    end
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, msg, ...)
        if ok then
            return formatted
        end
    end
    return msg
end

--- @param level integer
--- @param msg string
function MsvcLog:_emit(level, msg, ...)
    if not self._enabled then
        return
    end
    if level < self.level then
        return
    end
    local text = format_msg(msg, ...)
    vim.notify(text, level, { title = TITLE })
    local label = LEVEL_TO_NAME[level] or tostring(level)
    self:log("[" .. label .. "] " .. text)
end

function MsvcLog:debug(msg, ...)
    self:_emit(levels.DEBUG, msg, ...)
end
function MsvcLog:info(msg, ...)
    self:_emit(levels.INFO, msg, ...)
end
function MsvcLog:warn(msg, ...)
    self:_emit(levels.WARN, msg, ...)
end
function MsvcLog:error(msg, ...)
    self:_emit(levels.ERROR, msg, ...)
end

--- Open (or focus) the build log buffer. While a build is running this
--- streams live output; otherwise it shows the captured output of the
--- most recent build (until the next build starts and resets it).
function MsvcLog:show_build()
    local buf = self:_ensure_live_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local empty = #lines == 0 or (#lines == 1 and lines[1] == "")
    if empty then
        vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
        vim.api.nvim_buf_set_lines(
            buf,
            0,
            -1,
            false,
            { "-- no build output yet --" }
        )
        vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    end
    self:_ensure_live_win()
end

local LIVE_BUF_NAME = "msvc://live-build-log"

--- Return (creating if necessary) the persistent live-build-log buffer.
--- @return integer bufnr
function MsvcLog:_ensure_live_buf()
    local state = self._live_tail
    if state and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        return state.buf
    end
    state = state or {}
    self._live_tail = state

    -- Reuse a pre-existing live-log buffer (e.g. left over from a plugin
    -- reload) — otherwise nvim_buf_set_name would raise E95.
    local existing = vim.fn.bufnr(LIVE_BUF_NAME)
    if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
        state.buf = existing
        return existing
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, LIVE_BUF_NAME)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
    vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    state.buf = buf
    return buf
end

--- Return a visible window displaying the live buffer, opening one if none.
--- @return integer winid
function MsvcLog:_ensure_live_win()
    local buf = self:_ensure_live_buf()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == buf then
            return win
        end
    end
    local prev = vim.api.nvim_get_current_win()
    vim.cmd("botright vsplit")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    -- Return focus to the originating window so the user keeps their cursor.
    if vim.api.nvim_win_is_valid(prev) then
        vim.api.nvim_set_current_win(prev)
    end
    self._live_tail.win = win
    return win
end

--- Append a single line to the live-build-log buffer and scroll to bottom.
--- @param line string
function MsvcLog:_live_append(line)
    local state = self._live_tail
    if
        not state
        or not state.buf
        or not vim.api.nvim_buf_is_valid(state.buf)
    then
        return
    end
    local buf = state.buf
    vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
        local n = vim.api.nvim_buf_line_count(buf)
        local first_empty = n == 1
            and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
        vim.api.nvim_buf_set_lines(
            buf,
            first_empty and 0 or -1,
            -1,
            false,
            { line }
        )
        vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_buf(win) == buf then
                local last = vim.api.nvim_buf_line_count(buf)
                pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
            end
        end
    end)
end

--- Install the idempotent live-tail listener. Every MSBuild invocation
--- (BUILD_START) resets the live buffer and ensures it's visible; every
--- output line streams in; finish/cancel banners are appended.
function MsvcLog:install_live_tail()
    if self._live_tail_installed then
        return
    end
    self._live_tail_installed = true
    local Ext = require("msvc.extensions")
    Ext.extensions:add_listener({
        [Ext.event_names.BUILD_START] = function()
            vim.schedule(function()
                local buf = self:_ensure_live_buf()
                vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
                vim.api.nvim_buf_set_lines(
                    buf,
                    0,
                    -1,
                    false,
                    { "-- build started --" }
                )
                vim.api.nvim_set_option_value(
                    "modifiable",
                    false,
                    { buf = buf }
                )
                self:_ensure_live_win()
            end)
        end,
        [Ext.event_names.BUILD_OUTPUT] = function(_, line)
            self:_live_append(line)
        end,
        [Ext.event_names.BUILD_DONE] = function(_, ok, ms)
            self:_live_append(
                ("-- build %s in %d ms --"):format(ok and "OK" or "FAILED", ms)
            )
        end,
        [Ext.event_names.BUILD_CANCEL] = function()
            self:_live_append("-- build cancelled --")
        end,
    })
end

return MsvcLog:new()
