---@class MsvcSettings
---@field notify_level integer
---@field echo_command boolean
---@field build_on_save boolean
---@field open_quickfix boolean
---@field qf_height integer
---@field auto_select_sln boolean
---@field search_depth integer
---@field cache_env boolean
---@field env_cache_path string
---@field last_log_path string
---@field on_build_start fun(ctx: table)|nil
---@field on_build_done fun(ctx: table, ok: boolean, elapsed_ms: integer)|nil
---@field on_build_cancel fun(ctx: table)|nil
---@field compile_commands MsvcCompileCommandsSettings

---@class MsvcCompileCommandsSettings
---@field enabled? boolean        Auto-generate after a successful :Msvc build (default true when extractor is set).
---@field extractor? string[]     argv prefix to invoke msbuild-extractor-sample. nil disables the feature.
---@field outdir? string          Directory to write compile_commands.json (defaults to the solution's directory). Absolute or relative; relative paths are resolved against the solution dir, then project dir, then cwd.
---@field builddir? string        If set, recursively scan for *.vcxproj and merge into compile_commands.json. Absolute or relative; relative paths are resolved against the solution dir, then project dir, then cwd.
---@field merge? boolean          Pass `--merge` to the extractor (default true).
---@field deduplicate? boolean    Pass `--deduplicate` to the extractor (default true).
---@field extra_args? string[]    Extra args appended to the extractor invocation.

---@class MsvcPartialSettings
---@field notify_level? integer
---@field echo_command? boolean
---@field build_on_save? boolean
---@field open_quickfix? boolean
---@field qf_height? integer
---@field auto_select_sln? boolean
---@field search_depth? integer
---@field cache_env? boolean
---@field env_cache_path? string
---@field last_log_path? string
---@field on_build_start? fun(ctx: table)
---@field on_build_done? fun(ctx: table, ok: boolean, elapsed_ms: integer)
---@field on_build_cancel? fun(ctx: table)
---@field compile_commands? MsvcCompileCommandsSettings

---@class MsvcProfileItem
---@field configuration? string
---@field platform? string
---@field target? string
---@field verbosity? string
---@field max_cpu_count? integer
---@field no_logo? boolean
---@field extra_args? string[]
---@field msbuild_args? string[]
---@field jobs? integer
---@field arch? string
---@field host_arch? string
---@field vs_version? string
---@field vs_prerelease? boolean
---@field vs_products? string[]
---@field vs_requires? string[]
---@field vswhere_path? string|nil
---@field vcvars_ver? string
---@field winsdk? string
---@field vcvars_spectre_libs? string
---@field install_path? string

---@class MsvcConfig
---@field settings MsvcSettings
---@field profiles table<string, MsvcProfileItem>

---@class MsvcPartialConfig
---@field settings? MsvcPartialSettings
---@field profiles? table<string, MsvcProfileItem>

local Log = require("msvc.log")

local M = {}

--- Sentinel name used when no profile is active.
M.DEFAULT_PROFILE = "default"

local VALID_VERBOSITY = {
    quiet = true,
    minimal = true,
    normal = true,
    detailed = true,
    diagnostic = true,
}

local KNOWN_SETTINGS = {
    notify_level = "number",
    echo_command = "boolean",
    build_on_save = "boolean",
    open_quickfix = "boolean",
    qf_height = "number",
    auto_select_sln = "boolean",
    search_depth = "number",
    cache_env = "boolean",
    env_cache_path = "string",
    last_log_path = "string",
    on_build_start = "function",
    on_build_done = "function",
    on_build_cancel = "function",
    compile_commands = "table",
}

-- Inner schema for `settings.compile_commands`. Validated separately
-- because the value lives nested under `settings`, not on a profile.
local KNOWN_COMPILE_COMMANDS = {
    enabled = "boolean",
    outdir = "string",
    builddir = "string",
    merge = "boolean",
    deduplicate = "boolean",
    extra_args = "table",
}

-- Fields that may appear on a profile entry. A profile carries the full
-- merged surface area: MSBuild parameters (configuration, platform,
-- target, msbuild_args, jobs, ...) plus the developer-env parameters
-- (arch, host_arch, vcvars_ver, winsdk, vs_*, vswhere_path, install_path)
-- that used to live on a separate "resolve" table. There is no nesting.
local KNOWN_PROFILE = {
    configuration = "string",
    platform = "string",
    target = "string",
    verbosity = "string",
    max_cpu_count = "number",
    no_logo = "boolean",
    extra_args = "table",
    msbuild_args = "table",
    jobs = "number",
    vs_version = "string",
    vs_prerelease = "boolean",
    vs_products = "table",
    vs_requires = "table",
    vswhere_path = "string",
    vcvars_ver = "string",
    winsdk = "string",
    vcvars_spectre_libs = "string",
    arch = "string",
    host_arch = "string",
    install_path = "string",
}

-- Keys accepted at the top level of `setup({ ... })`. Anything outside
-- this set is a misplacement (typically a settings.* key written one
-- level too high) and is logged as a warning so it is not silently
-- dropped during merge.
local KNOWN_TOP_LEVEL = {
    settings = true,
    profiles = true,
}

M.KNOWN_SETTINGS = KNOWN_SETTINGS
M.KNOWN_PROFILE = KNOWN_PROFILE
M.KNOWN_COMPILE_COMMANDS = KNOWN_COMPILE_COMMANDS
M.KNOWN_TOP_LEVEL = KNOWN_TOP_LEVEL

--- Hard-coded defaults. A fresh table is returned on every call so callers
--- can freely mutate the result without poisoning future invocations.
---@return MsvcConfig
function M.get_default_config()
    return {
        settings = {
            notify_level = vim.log.levels.INFO,
            echo_command = false,
            build_on_save = false,
            open_quickfix = true,
            qf_height = 10,
            auto_select_sln = true,
            search_depth = 4,
            cache_env = true,
            env_cache_path = vim.fn.stdpath("cache") .. "/nvim-msvc-env.json",
            last_log_path = vim.fn.stdpath("cache") .. "/nvim-msvc-last.log",
            on_build_start = nil,
            on_build_done = nil,
            on_build_cancel = nil,
            -- Integration with msbuild-extractor-sample
            -- (https://github.com/microsoft/msbuild-extractor-sample).
            -- The `msbuild-extractor-sample` executable must be on PATH;
            -- when present, `:Msvc build` auto-runs it after a successful
            -- build to (re)generate compile_commands.json.
            compile_commands = {
                enabled = true,
                outdir = nil,
                builddir = nil,
                merge = true,
                deduplicate = true,
                extra_args = nil,
            },
        },
        profiles = {
            default = {
                vs_version = "latest",
                vs_prerelease = false,
                vs_products = {
                    "Microsoft.VisualStudio.Product.Community",
                    "Microsoft.VisualStudio.Product.Professional",
                    "Microsoft.VisualStudio.Product.Enterprise",
                    "Microsoft.VisualStudio.Product.BuildTools",
                },
                vs_requires = {},
                vswhere_path = nil,
                vcvars_ver = nil,
                arch = "x64",
                host_arch = "x64",
                msbuild_args = { "/nologo", "/v:minimal" },
                jobs = 0,
            },
        },
    }
end

--- Sorted list of named profiles excluding `default`.
---@param config MsvcConfig
---@return string[]
function M.list_profile_names(config)
    local names = {}
    for k in pairs((config or {}).profiles or {}) do
        if k ~= M.DEFAULT_PROFILE then
            names[#names + 1] = k
        end
    end
    table.sort(names)
    return names
end

--- Flatten `profiles.default` ⨉ `profiles[name]` into a single table
--- holding both MSBuild and dev-env fields.
---@param config MsvcConfig
---@param name string|nil
---@return MsvcProfileItem
function M.get_profile(config, name)
    name = name or M.DEFAULT_PROFILE
    local profiles = (config or {}).profiles or {}
    local default = profiles[M.DEFAULT_PROFILE] or {}
    if name == M.DEFAULT_PROFILE then
        return vim.tbl_extend("force", {}, default)
    end
    local profile = profiles[name] or {}
    return vim.tbl_extend("force", {}, default, profile)
end

--- Shallow-merge `partial` over `latest` (or freshly-built defaults).
--- `settings` is merged per-key; `profiles[name]` is merged per-key
--- so multiple `setup` calls extend rather than clobber a profile.
---@param partial_config MsvcPartialConfig|nil
---@param latest_config MsvcConfig|nil
---@return MsvcConfig
function M.merge_config(partial_config, latest_config)
    partial_config = partial_config or {}
    local config = latest_config or M.get_default_config()
    config.profiles = config.profiles or {}
    -- Surface misplaced top-level keys early. The most common mistake is
    -- writing a `settings.*` key (e.g. `compile_commands`) at the top
    -- level of `setup({ ... })`, where `merge_config` would otherwise
    -- silently drop it. Hint at the right location when we can.
    for k, _ in pairs(partial_config) do
        if not KNOWN_TOP_LEVEL[k] then
            if KNOWN_SETTINGS[k] then
                Log:warn(
                    "config: top-level key %q belongs in `settings.%s` — value ignored",
                    tostring(k),
                    tostring(k)
                )
            elseif KNOWN_PROFILE[k] then
                Log:warn(
                    "config: top-level key %q belongs in `profiles.default.%s` — value ignored",
                    tostring(k),
                    tostring(k)
                )
            else
                Log:warn(
                    "config: unknown top-level setup key %q — value ignored",
                    tostring(k)
                )
            end
        end
    end
    for k, v in pairs(partial_config) do
        if k == "settings" then
            local cur = config.settings or {}
            local incoming = v or {}
            -- Merge nested `compile_commands` per-key so users can override
            -- a single field without clobbering the rest.
            local cc_partial = incoming.compile_commands
            local merged = vim.tbl_extend("force", cur, incoming)
            if cc_partial ~= nil then
                merged.compile_commands = vim.tbl_extend(
                    "force",
                    cur.compile_commands or {},
                    cc_partial
                )
            end
            config.settings = merged
        elseif k == "profiles" then
            for pname, pdef in pairs(v or {}) do
                local prev = config.profiles[pname] or {}
                config.profiles[pname] =
                    vim.tbl_extend("force", prev, pdef or {})
            end
        end
    end
    return config
end

--- Sugar — build a config by passing only the `settings` table.
---@param settings MsvcPartialSettings|nil
---@return MsvcConfig
function M.create_config(settings)
    return M.merge_config({ settings = settings or {} })
end

local function check_type(label, value, expected)
    local got = type(value)
    if got ~= expected then
        error(
            ("msvc.config: %s must be a %s, got %s"):format(
                label,
                expected,
                got
            ),
            2
        )
    end
end

local REMOVED_SETTINGS = {
    use_dev_env = "removed in favor of always-on developer-prompt resolution for the compile_commands extractor; delete this key from your config",
}

local function validate_settings(settings)
    if settings == nil then
        return
    end
    check_type("settings", settings, "table")
    for k, v in pairs(settings) do
        local removed_msg = REMOVED_SETTINGS[k]
        if removed_msg ~= nil then
            error(
                ("msvc.config: settings.%s has been removed: %s"):format(
                    k,
                    removed_msg
                ),
                2
            )
        end
        local expected = KNOWN_SETTINGS[k]
        if expected == nil then
            if KNOWN_PROFILE[k] then
                error(
                    ("msvc.config: %q belongs in `profiles.default`, not `settings`"):format(
                        tostring(k)
                    ),
                    2
                )
            end
            Log:warn("config: unknown settings key %q", tostring(k))
        elseif v ~= nil then
            local got = type(v)
            if expected == "function" then
                if got ~= "function" and got ~= "nil" then
                    error(
                        ("msvc.config: settings.%s must be a function, got %s"):format(
                            k,
                            got
                        ),
                        2
                    )
                end
            elseif got ~= expected then
                error(
                    ("msvc.config: settings.%s must be a %s, got %s"):format(
                        k,
                        expected,
                        got
                    ),
                    2
                )
            end
        end
    end
    if type(settings.qf_height) == "number" and settings.qf_height < 1 then
        error("msvc.config: settings.qf_height must be >= 1", 2)
    end
    if
        type(settings.search_depth) == "number"
        and settings.search_depth < 0
    then
        error("msvc.config: settings.search_depth must be >= 0", 2)
    end
    if settings.compile_commands ~= nil then
        check_type(
            "settings.compile_commands",
            settings.compile_commands,
            "table"
        )
        for k, v in pairs(settings.compile_commands) do
            local expected = KNOWN_COMPILE_COMMANDS[k]
            if expected == nil then
                Log:warn(
                    "config: unknown settings.compile_commands key %q",
                    tostring(k)
                )
            elseif v ~= nil then
                local got = type(v)
                if got ~= expected then
                    error(
                        ("msvc.config: settings.compile_commands.%s must be a %s, got %s"):format(
                            k,
                            expected,
                            got
                        ),
                        2
                    )
                end
                if expected == "table" and k == "extra_args" then
                    for i, item in ipairs(v) do
                        if type(item) ~= "string" then
                            error(
                                ("msvc.config: settings.compile_commands.%s[%d] must be a string, got %s"):format(
                                    k,
                                    i,
                                    type(item)
                                ),
                                2
                            )
                        end
                    end
                end
            end
        end
    end
end

local function validate_profile(label, profile)
    check_type(label, profile, "table")
    for k, v in pairs(profile) do
        local expected = KNOWN_PROFILE[k]
        if expected == nil then
            Log:warn("config: unknown %s key %q", label, tostring(k))
        elseif v ~= nil then
            local got = type(v)
            if
                expected == "string"
                and (k == "vswhere_path" or k == "install_path")
            then
                if got ~= "string" and got ~= "nil" then
                    error(
                        ("msvc.config: %s.%s must be a string, got %s"):format(
                            label,
                            k,
                            got
                        ),
                        2
                    )
                end
            elseif got ~= expected then
                error(
                    ("msvc.config: %s.%s must be a %s, got %s"):format(
                        label,
                        k,
                        expected,
                        got
                    ),
                    2
                )
            end
        end
    end
    if type(profile.jobs) == "number" and profile.jobs < 0 then
        error(("msvc.config: %s.jobs must be >= 0"):format(label), 2)
    end
    if type(profile.msbuild_args) == "table" then
        for i, arg in ipairs(profile.msbuild_args) do
            if type(arg) ~= "string" then
                error(
                    ("msvc.config: %s.msbuild_args[%d] must be a string, got %s"):format(
                        label,
                        i,
                        type(arg)
                    ),
                    2
                )
            end
            local lower = string.lower(arg)
            local v = lower:match("^/v:(%a+)$")
                or lower:match("^/verbosity:(%a+)$")
            if v and not VALID_VERBOSITY[v] then
                Log:warn(
                    "config: %s.msbuild_args has unknown verbosity %q",
                    label,
                    v
                )
            end
        end
    end
end

--- Validate a merged or partial config. Logs warnings for unknown keys via
--- `MsvcLog:warn`; raises on type mismatches.
---@param config MsvcPartialConfig|MsvcConfig
function M.validate(config)
    check_type("config", config, "table")
    validate_settings(config.settings)
    if config.profiles ~= nil then
        check_type("profiles", config.profiles, "table")
        for pname, pdef in pairs(config.profiles) do
            if type(pname) ~= "string" then
                error(
                    ("msvc.config: profile names must be strings, got %s"):format(
                        type(pname)
                    ),
                    2
                )
            end
            validate_profile("profiles." .. pname, pdef)
        end
    end
end

--- Format a profile entry as a sorted multi-line description suitable
--- for verbose logging. The first line is `header`; each subsequent
--- line is `  <key> = <value>` with values formatted via `vim.inspect`
--- (single-line).
---@param header string
---@param entry table
---@return string[]
function M.format_entry_lines(header, entry)
    local lines = { header }
    if type(entry) ~= "table" then
        return lines
    end
    local keys = {}
    for k, v in pairs(entry) do
        if v ~= nil then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local rendered = vim.inspect(entry[k], { newline = "", indent = "" })
        lines[#lines + 1] = ("  %s = %s"):format(k, rendered)
    end
    return lines
end

return M
