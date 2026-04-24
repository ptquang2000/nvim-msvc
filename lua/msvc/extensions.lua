---@class MsvcExtensions
---@field listeners table[]

local event_names = setmetatable({
    BUILD_START = "BUILD_START",
    BUILD_OUTPUT = "BUILD_OUTPUT",
    BUILD_DONE = "BUILD_DONE",
    BUILD_CANCEL = "BUILD_CANCEL",
    ENV_RESOLVED = "ENV_RESOLVED",
    STATE_CHANGED = "STATE_CHANGED",
}, {
    __newindex = function()
        error("event_names is frozen")
    end,
})

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
                    "msvc extension listener error for "
                        .. tostring(event)
                        .. ": "
                        .. tostring(err),
                    vim.log.levels.ERROR
                )
            end
        end
    end
end

local extensions = MsvcExtensions:new()

return {
    MsvcExtensions = MsvcExtensions,
    event_names = event_names,
    extensions = extensions,
}
