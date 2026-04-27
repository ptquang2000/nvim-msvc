-- msvc.log — ring buffer + vim.notify wrapper + persistent live-build buffer.

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
local LIVE_BUF_NAME = "msvc://live-build-log"
local MAX_LINES = 50

---@class MsvcLog
---@field level integer
---@field lines string[]
local MsvcLog = {}
MsvcLog.__index = MsvcLog

function MsvcLog:new()
    return setmetatable({ level = levels.INFO, lines = {} }, self)
end

function MsvcLog:set_level(name_or_number)
    if type(name_or_number) == "string" then
        local lvl = NAME_TO_LEVEL[string.lower(name_or_number)]
        if not lvl then
            error(("msvc.log: unknown level %q"):format(name_or_number), 2)
        end
        self.level = lvl
    elseif type(name_or_number) == "number" then
        self.level = name_or_number
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

function MsvcLog:_emit(level, msg, ...)
    if level < self.level then
        return
    end
    local text = format_msg(msg, ...)
    vim.notify(text, level, { title = TITLE })
    self.lines[#self.lines + 1] = "["
        .. (LEVEL_TO_NAME[level] or "?")
        .. "] "
        .. text
    while #self.lines > MAX_LINES do
        table.remove(self.lines, 1)
    end
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

local function ensure_live_buf(self)
    local state = self._live or {}
    self._live = state
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        return state.buf
    end
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

local function ensure_live_win(self)
    local buf = ensure_live_buf(self)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == buf then
            return win
        end
    end
    local prev = vim.api.nvim_get_current_win()
    vim.cmd("botright vsplit")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    if vim.api.nvim_win_is_valid(prev) then
        vim.api.nvim_set_current_win(prev)
    end
    return win
end

local function append_line(buf, line)
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

local function reset_buf(buf, banner)
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { banner })
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

--- Open / focus the build log window.
function MsvcLog:show_build()
    local buf = ensure_live_buf(self)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if #lines == 0 or (#lines == 1 and lines[1] == "") then
        reset_buf(buf, "-- no build output yet --")
    end
    ensure_live_win(self)
end

--- Wire the live-tail listener to the extension bus. Idempotent.
function MsvcLog:install_live_tail()
    if self._tail_installed then
        return
    end
    self._tail_installed = true
    local Ext = require("msvc.extensions")
    Ext.extensions:add_listener({
        [Ext.event_names.BUILD_START] = function()
            vim.schedule(function()
                local buf = ensure_live_buf(self)
                reset_buf(buf, "-- build started --")
                ensure_live_win(self)
            end)
        end,
        [Ext.event_names.BUILD_OUTPUT] = function(line)
            local state = self._live
            if state and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
                append_line(state.buf, line)
            end
        end,
        [Ext.event_names.BUILD_DONE] = function(ok, ms)
            local state = self._live
            if state and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
                append_line(
                    state.buf,
                    ("-- build %s in %d ms --"):format(
                        ok and "OK" or "FAILED",
                        ms or 0
                    )
                )
            end
        end,
        [Ext.event_names.BUILD_CANCEL] = function()
            local state = self._live
            if state and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
                append_line(state.buf, "-- build cancelled --")
            end
        end,
    })
end

return MsvcLog:new()
