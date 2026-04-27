-- msvc.config — config schema. Two layers: `default` is merged under every
-- named profile; `settings` holds plugin-wide knobs.

local M = {}

--- All profile fields the engine recognizes. Used by :Msvc update completion
--- and validation. Keep this list in sync with build.lua / devenv.lua.
M.PROFILE_FIELDS = {
    "configuration",
    "platform",
    "arch",
    "msbuild_args",
    "jobs",
    "target",
    "vs_version",
    "vs_prerelease",
    "vs_products",
    "vs_requires",
    "vswhere_path",
    "vcvars_ver",
    "winsdk",
    "compile_commands",
}

local PROFILE_FIELD_SET = {}
for _, k in ipairs(M.PROFILE_FIELDS) do
    PROFILE_FIELD_SET[k] = true
end

local VALID_ARCH = { x86 = true, x64 = true, arm = true, arm64 = true }

--- Default plugin config. Note `settings.default_profile` has no fallback —
--- the user must name a profile to activate (or pass one via `:Msvc profile`).
function M.get_default_config()
    return {
        settings = {
            default_profile = nil,
            log_level = "info",
            build_on_save = false,
        },
        default = {
            msbuild_args = { "/nologo", "/v:minimal" },
            jobs = nil,
            arch = "x64",
            vs_version = "latest",
            vs_prerelease = false,
            compile_commands = {
                enabled = true,
                builddir = "bin/cmake",
                outdir = "bin",
                merge = true,
                deduplicate = true,
                extra_args = {},
            },
        },
        profiles = {},
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

local function shallow_merge(into, from)
    for k, v in pairs(from or {}) do
        if into[k] == nil then
            into[k] = copy_value(v)
        end
    end
    return into
end

--- Deep-merge user config over defaults. `settings` is shallow-merged
--- (compile_commands sub-table is merged), `default` is shallow-merged,
--- `profiles` table replaces wholesale (each entry kept verbatim).
function M.merge_config(user)
    local out = M.get_default_config()
    user = user or {}

    if type(user.settings) == "table" then
        for k, v in pairs(user.settings) do
            out.settings[k] = copy_value(v)
        end
    end

    if type(user.default) == "table" then
        for k, v in pairs(user.default) do
            if k == "compile_commands" and type(v) == "table" then
                local merged = {}
                for kk, vv in pairs(out.default.compile_commands or {}) do
                    merged[kk] = copy_value(vv)
                end
                for kk, vv in pairs(v) do
                    merged[kk] = copy_value(vv)
                end
                out.default.compile_commands = merged
            else
                out.default[k] = copy_value(v)
            end
        end
    end

    if type(user.profiles) == "table" then
        out.profiles = {}
        for name, prof in pairs(user.profiles) do
            if type(prof) == "table" then
                out.profiles[name] = copy_value(prof)
            end
        end
    end

    return out
end

--- Resolve a profile by name: shallow-merge `default` under the named entry.
--- Returns nil when the name is missing.
function M.get_profile(config, name)
    if config == nil or name == nil or name == "" then
        return nil
    end
    local entry = config.profiles and config.profiles[name]
    if type(entry) ~= "table" then
        return nil
    end
    local merged = copy_value(entry)
    shallow_merge(merged, config.default)
    return merged
end

function M.list_profile_names(config)
    local out = {}
    for name, _ in pairs((config or {}).profiles or {}) do
        out[#out + 1] = name
    end
    table.sort(out)
    return out
end

--- Validate the merged config. Throws on misconfiguration.
function M.validate(config)
    assert(type(config) == "table", "msvc.config: config must be a table")
    assert(
        type(config.settings) == "table",
        "msvc.config: settings must be a table"
    )
    assert(
        type(config.profiles) == "table",
        "msvc.config: profiles must be a table"
    )

    local s = config.settings
    if s.default_profile ~= nil then
        assert(
            type(s.default_profile) == "string" and s.default_profile ~= "",
            "msvc.config: settings.default_profile must be a non-empty string"
        )
        assert(
            config.profiles[s.default_profile] ~= nil,
            ("msvc.config: settings.default_profile %q has no matching profiles entry"):format(
                s.default_profile
            )
        )
    end
    assert(
        s.log_level == nil or type(s.log_level) == "string",
        "msvc.config: settings.log_level must be a string"
    )
    assert(
        s.build_on_save == nil or type(s.build_on_save) == "boolean",
        "msvc.config: settings.build_on_save must be a boolean"
    )
    assert(
        s.compile_commands == nil,
        "msvc.config: settings.compile_commands has moved to a profile field — set it under `default = { compile_commands = {...} }` or per-profile"
    )

    for _, k in ipairs({ "default" }) do
        assert(
            config[k] == nil or type(config[k]) == "table",
            ("msvc.config: %s must be a table"):format(k)
        )
        local layer = config[k]
        if layer ~= nil then
            for fk, _ in pairs(layer) do
                assert(
                    PROFILE_FIELD_SET[fk],
                    ("msvc.config: unknown profile field %q in %s"):format(
                        fk,
                        k
                    )
                )
            end
        end
    end

    for name, prof in pairs(config.profiles) do
        assert(
            type(prof) == "table",
            ("msvc.config: profile %q must be a table"):format(name)
        )
        for fk, _ in pairs(prof) do
            assert(
                PROFILE_FIELD_SET[fk],
                ("msvc.config: unknown field %q in profile %q"):format(fk, name)
            )
        end
        local merged = M.get_profile(config, name)
        assert(
            type(merged.configuration) == "string"
                and merged.configuration ~= "",
            ("msvc.config: profile %q is missing `configuration`"):format(name)
        )
        assert(
            type(merged.platform) == "string" and merged.platform ~= "",
            ("msvc.config: profile %q is missing `platform`"):format(name)
        )
        if merged.arch ~= nil then
            assert(
                VALID_ARCH[merged.arch],
                ("msvc.config: profile %q has invalid arch %q (expected x86|x64|arm|arm64)"):format(
                    name,
                    tostring(merged.arch)
                )
            )
        end
        if merged.jobs ~= nil then
            assert(
                type(merged.jobs) == "number" and merged.jobs > 0,
                ("msvc.config: profile %q has invalid jobs %s"):format(
                    name,
                    tostring(merged.jobs)
                )
            )
        end
        if merged.msbuild_args ~= nil then
            assert(
                type(merged.msbuild_args) == "table",
                ("msvc.config: profile %q msbuild_args must be a table"):format(
                    name
                )
            )
        end
        if merged.compile_commands ~= nil then
            assert(
                type(merged.compile_commands) == "table",
                ("msvc.config: profile %q compile_commands must be a table"):format(
                    name
                )
            )
        end
    end
end

return M
