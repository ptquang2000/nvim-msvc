-- msvc.config — config schema. Settings layer only; no named profiles.

local M = {}

--- Context-level fields the msvc:// buffer can display and modify.
M.SETTINGS_FIELDS = { "configuration", "platform", "arch", "vs_version", "jobs" }

--- Default flat settings applied to a new (solution, project) context.
M.DEFAULT_SETTINGS = {
    configuration = nil,
    platform = nil,
    arch = "x64",
    vs_version = "latest",
    jobs = nil,
}

local VALID_ARCH = { x86 = true, x64 = true, arm = true, arm64 = true }

--- Default plugin config. Plugin-wide knobs only — no profiles.
function M.get_default_config()
    return {
        settings = {
            vswhere_path = nil,
            vs_requires = {},
            log_level = "info",
            compile_commands = {
                enabled = true,
                builddir = "bin/cmake",
                outdir = "bin",
                merge = true,
                deduplicate = true,
                extra_args = {},
            },
        },
    }
end

local function copy_value(v)
    if type(v) ~= "table" then
        return v
    end
    local out = {}
    for k, vv in pairs(v) do
        out[k] = copy_value(vv)
    end
    return out
end

--- Merge user config over plugin defaults. Only the `settings` table is
--- recognized; `profiles` / `default` / `default_profile` are ignored.
function M.merge_config(user)
    local out = M.get_default_config()
    user = user or {}
    if type(user.settings) == "table" then
        for k, v in pairs(user.settings) do
            if k == "compile_commands" and type(v) == "table" then
                local merged = {}
                for kk, vv in pairs(out.settings.compile_commands or {}) do
                    merged[kk] = copy_value(vv)
                end
                for kk, vv in pairs(v) do
                    merged[kk] = copy_value(vv)
                end
                out.settings.compile_commands = merged
            else
                out.settings[k] = copy_value(v)
            end
        end
    end
    return out
end

--- Validate the merged config. Throws on misconfiguration.
function M.validate(config)
    assert(type(config) == "table", "msvc.config: config must be a table")
    assert(
        type(config.settings) == "table",
        "msvc.config: settings must be a table"
    )
    local s = config.settings
    assert(
        s.log_level == nil or type(s.log_level) == "string",
        "msvc.config: settings.log_level must be a string"
    )
    if s.vs_requires ~= nil then
        assert(
            type(s.vs_requires) == "table",
            "msvc.config: settings.vs_requires must be a table"
        )
    end
    if s.compile_commands ~= nil then
        assert(
            type(s.compile_commands) == "table",
            "msvc.config: settings.compile_commands must be a table"
        )
    end
end

return M
