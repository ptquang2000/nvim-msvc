-- msvc.extensions — frozen event names + listener bus (harpoon-style).

local event_names = setmetatable({
    BUILD_START = "BUILD_START",
    BUILD_OUTPUT = "BUILD_OUTPUT",
    BUILD_DONE = "BUILD_DONE",
    BUILD_CANCEL = "BUILD_CANCEL",
    SETUP_CALLED = "SETUP_CALLED",
}, {
    __newindex = function()
        error("event_names is frozen")
    end,
})

---@class MsvcExtensions
local MsvcExtensions = {}
MsvcExtensions.__index = MsvcExtensions

function MsvcExtensions:new()
    return setmetatable({ listeners = {} }, self)
end

function MsvcExtensions:add_listener(ext)
    table.insert(self.listeners, ext)
end

function MsvcExtensions:clear_listeners()
    self.listeners = {}
end

function MsvcExtensions:emit(event, ...)
    for _, listener in ipairs(self.listeners) do
        local cb = listener[event]
        if type(cb) == "function" then
            local ok, err = pcall(cb, ...)
            if not ok then
                vim.notify(
                    ("msvc extension error for %s: %s"):format(event, err),
                    vim.log.levels.ERROR
                )
            end
        end
    end
end

return {
    MsvcExtensions = MsvcExtensions,
    event_names = event_names,
    extensions = MsvcExtensions:new(),
}
