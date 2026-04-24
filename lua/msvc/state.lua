local Ext = require("msvc.extensions")
local Discover = require("msvc.discover")
local Util = require("msvc.util")

local ALLOWED_FIELDS = {
    solution = true,
    project = true,
    profile = true,
    resolve = true,
    install_path = true,
    arch = true,
}

local function default_fields()
    return {
        solution = nil,
        project = nil,
        profile = nil,
        resolve = nil,
        install_path = nil,
        arch = "x64",
    }
end

---@class MsvcState
---@field solution string|nil
---@field project string|nil
---@field profile string|nil
---@field resolve string|nil
---@field install_path string|nil
---@field arch string
local MsvcState = {}
MsvcState.__index = MsvcState

--- Construct a new MsvcState with default values, optionally merging
--- the fields from `initial` (only whitelisted fields are accepted).
---@param initial table|nil
---@return MsvcState
function MsvcState:new(initial)
    local self_ = setmetatable(default_fields(), MsvcState)
    if type(initial) == "table" then
        for k, v in pairs(initial) do
            if not ALLOWED_FIELDS[k] then
                error("MsvcState:new unknown field: " .. tostring(k))
            end
            self_[k] = v
        end
    end
    return self_
end

--- Return a shallow copy of the current field values.
---@return table
function MsvcState:get_snapshot()
    return {
        solution = self.solution,
        project = self.project,
        profile = self.profile,
        resolve = self.resolve,
        install_path = self.install_path,
        arch = self.arch,
    }
end

--- Mutate a single whitelisted field and emit STATE_CHANGED.
---@param field string
---@param value any
function MsvcState:set(field, value)
    if not ALLOWED_FIELDS[field] then
        error("MsvcState:set unknown field: " .. tostring(field))
    end
    self[field] = value
    Ext.extensions:emit(Ext.event_names.STATE_CHANGED, {
        field = field,
        value = value,
        snapshot = self:get_snapshot(),
    })
end

--- Mutate many fields at once. Emits a single STATE_CHANGED with
--- field = "*" once all assignments are done.
---@param tbl table
function MsvcState:set_many(tbl)
    if type(tbl) ~= "table" then
        error("MsvcState:set_many expects a table")
    end
    for field, value in pairs(tbl) do
        if not ALLOWED_FIELDS[field] then
            error("MsvcState:set_many unknown field: " .. tostring(field))
        end
        self[field] = value
    end
    local snap = self:get_snapshot()
    Ext.extensions:emit(Ext.event_names.STATE_CHANGED, {
        field = "*",
        value = snap,
        snapshot = snap,
    })
end

--- Walk upward from `start_dir` (or cwd) looking for a .sln. If found,
--- assign it via :set so listeners are notified. Returns the path or nil.
---@param start_dir string|nil
---@return string|nil
function MsvcState:auto_discover(start_dir)
    local origin = start_dir or vim.fn.getcwd()
    local found = Discover.find_solution(origin)
    if found then
        self:set("solution", Util.normalize_path(found) or found)
        return self.solution
    end
    return nil
end

--- Return the active profile name (or nil if not selected).
---@return string|nil
function MsvcState:profile_name()
    if self.profile and self.profile ~= "" then
        return self.profile
    end
    return nil
end

--- Return the active resolve name (or nil if not selected).
---@return string|nil
function MsvcState:resolve_name()
    if self.resolve and self.resolve ~= "" then
        return self.resolve
    end
    return nil
end

--- Reset to the default field values and emit STATE_CHANGED with
--- field = "*".
function MsvcState:reset()
    local defaults = default_fields()
    for k in pairs(ALLOWED_FIELDS) do
        self[k] = defaults[k]
    end
    local snap = self:get_snapshot()
    Ext.extensions:emit(Ext.event_names.STATE_CHANGED, {
        field = "*",
        value = snap,
        snapshot = snap,
    })
end

return {
    MsvcState = MsvcState,
}
