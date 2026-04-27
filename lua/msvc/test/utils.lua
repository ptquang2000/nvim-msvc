-- Shared helpers for msvc plenary-busted specs.

local M = {}

--- Reset all msvc.* singletons via plenary.reload — call in before_each so
--- each `it` block gets a fresh module graph.
function M.reset()
    require("plenary.reload").reload_module("msvc")
end

--- Build a fake MsvcConfig for tests. `overrides` is deep-merged on top.
--- @param overrides table|nil
--- @return table
function M.fake_config(overrides)
    local Config = require("msvc.config")
    local cfg = Config.merge_config(overrides or {})
    return cfg
end

--- Capture vim.notify calls. Returns { restore=fn, calls={...} }.
--- Each entry in `calls` is { msg = string, level = integer, opts = table }.
function M.capture_notify()
    local original = vim.notify
    local calls = {}
    vim.notify = function(msg, level, opts)
        calls[#calls + 1] = {
            msg = msg,
            level = level,
            opts = opts,
        }
    end
    return {
        calls = calls,
        restore = function()
            vim.notify = original
        end,
    }
end

return M
