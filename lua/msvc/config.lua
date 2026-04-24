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

---@class MsvcPartialConfigItem
---@field vs_version? string
---@field vs_prerelease? boolean
---@field vs_products? string[]
---@field vs_requires? string[]
---@field vswhere_path? string|nil
---@field arch? string
---@field host_arch? string
---@field msbuild_args? string[]
---@field jobs? integer

---@class MsvcConfig
---@field settings MsvcSettings
---@field default MsvcPartialConfigItem
---@field resolves table<string, MsvcPartialConfigItem>
---@field [string] MsvcPartialConfigItem

---@class MsvcPartialConfig
---@field settings? MsvcPartialSettings
---@field default? MsvcPartialConfigItem
---@field resolves? table<string, MsvcPartialConfigItem>
---@field [string] MsvcPartialConfigItem

local Log = require("msvc.log")

local M = {}

--- Sentinel name used when no profile is active.
M.DEFAULT_PROFILE = "__msvc_default"

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
    use_dev_env = "boolean",
    on_build_start = "function",
    on_build_done = "function",
    on_build_cancel = "function",
}

local KNOWN_DEFAULT = {
    vs_version = "string",
    vs_prerelease = "boolean",
    vs_products = "table",
    vs_requires = "table",
    vswhere_path = "string",
    vcvars_ver = "string",
    arch = "string",
    host_arch = "string",
    install_path = "string",
    configuration = "string",
    platform = "string",
    target = "string",
    verbosity = "string",
    max_cpu_count = "number",
    no_logo = "boolean",
    extra_args = "table",
    msbuild_args = "table",
    jobs = "number",
}

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
            -- Source VsDevCmd.bat/vcvarsall.bat and forward the resolved env
            -- to MSBuild. Off by default: MSBuild.exe resolves per-project
            -- toolsets from <PlatformToolset> on its own, and a sourced env
            -- pins INCLUDE/LIB/PATH to VsDevCmd's default (latest) toolset
            -- which breaks mixed-toolset solutions (v141/v142/v143/v144).
            use_dev_env = false,
            on_build_start = nil,
            on_build_done = nil,
            on_build_cancel = nil,
        },
        default = {
            vs_version = "latest",
            vs_prerelease = false,
            vs_products = {
                "Microsoft.VisualStudio.Product.Community",
                "Microsoft.VisualStudio.Product.Professional",
                "Microsoft.VisualStudio.Product.Enterprise",
                "Microsoft.VisualStudio.Product.BuildTools",
            },
            vs_requires = {
                "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
            },
            vswhere_path = nil,
            -- Passed to VsDevCmd.bat / vcvarsall.bat as -vcvars_ver=<value>
            -- when set. Only effective when settings.use_dev_env = true.
            -- A single value cannot be correct for mixed-toolset solutions;
            -- prefer leaving use_dev_env disabled.
            vcvars_ver = nil,
            arch = "x64",
            host_arch = "x64",
            msbuild_args = { "/nologo", "/v:minimal" },
            jobs = 0,
        },
        resolves = {},
    }
end

--- Flatten `default` ⨉ named resolve into a single table.
---@param config MsvcConfig
---@param name string|nil
---@return MsvcPartialConfigItem
function M.get_resolve(config, name)
    local r = (config.resolves or {})[name or ""] or {}
    return vim.tbl_extend("force", {}, config.default or {}, r)
end

--- Flatten `default` ⨉ named profile into a single table.
---@param config MsvcConfig
---@param name string|nil
---@return MsvcPartialConfigItem
function M.get_config(config, name)
    name = name or M.DEFAULT_PROFILE
    return vim.tbl_extend("force", {}, config.default or {}, config[name] or {})
end

--- Shallow-merge `partial` over `latest` (or freshly-built defaults).
--- `settings`, `default`, and `resolves` are merged per-layer; any other key
--- is treated as a profile name. Never recurses — array values are replaced
--- wholesale.
---@param partial_config MsvcPartialConfig|nil
---@param latest_config MsvcConfig|nil
---@return MsvcConfig
function M.merge_config(partial_config, latest_config)
    partial_config = partial_config or {}
    local config = latest_config or M.get_default_config()
    for k, v in pairs(partial_config) do
        if k == "settings" then
            config.settings = vim.tbl_extend("force", config.settings, v)
        elseif k == "default" then
            config.default = vim.tbl_extend("force", config.default, v)
        elseif k == "resolves" then
            config.resolves = config.resolves or {}
            for rname, rdef in pairs(v or {}) do
                config.resolves[rname] =
                    vim.tbl_extend("force", config.resolves[rname] or {}, rdef)
            end
        else
            config[k] = vim.tbl_extend("force", config[k] or {}, v)
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

local function validate_settings(settings)
    if settings == nil then
        return
    end
    check_type("settings", settings, "table")
    for k, v in pairs(settings) do
        local expected = KNOWN_SETTINGS[k] or KNOWN_DEFAULT[k]
        if expected == nil then
            Log:warn("config: unknown settings key %q", tostring(k))
        elseif KNOWN_SETTINGS[k] == nil then
            error(
                ("msvc.config: %q belongs in `default`, not `settings`"):format(
                    tostring(k)
                ),
                2
            )
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
end

local function validate_profile(label, profile)
    check_type(label, profile, "table")
    for k, v in pairs(profile) do
        local expected = KNOWN_DEFAULT[k]
        if expected == nil then
            Log:warn("config: unknown %s key %q", label, tostring(k))
        elseif v ~= nil then
            local got = type(v)
            if expected == "string" and k == "vswhere_path" then
                if got ~= "string" and got ~= "nil" then
                    error(
                        ("msvc.config: %s.vswhere_path must be a string, got %s"):format(
                            label,
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
    if config.default ~= nil then
        validate_profile("default", config.default)
    end
    if config.resolves ~= nil then
        check_type("resolves", config.resolves, "table")
        for k, v in pairs(config.resolves) do
            if type(k) ~= "string" then
                error(
                    ("msvc.config: resolve names must be strings, got %s"):format(
                        type(k)
                    ),
                    2
                )
            end
            validate_profile("resolves." .. k, v)
        end
    end
    for k, v in pairs(config) do
        if k ~= "settings" and k ~= "default" and k ~= "resolves" then
            if type(k) ~= "string" then
                error(
                    ("msvc.config: profile names must be strings, got %s"):format(
                        type(k)
                    ),
                    2
                )
            end
            validate_profile(k, v)
        end
    end
end

return M
