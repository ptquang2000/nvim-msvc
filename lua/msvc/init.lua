local Log = require("msvc.log")
local Util = require("msvc.util")
local Config = require("msvc.config")
local Ext = require("msvc.extensions")
local Autocmd = require("msvc.autocmd")
local DevEnv = require("msvc.devenv")
local VsWhere = require("msvc.vswhere")
local Discover = require("msvc.discover")
local State = require("msvc.state").MsvcState
local Build = require("msvc.build").MsvcBuild
local QuickFix = require("msvc.quickfix")

---@class Msvc
---@field config MsvcConfig
---@field state MsvcState
---@field extensions MsvcExtensions
---@field log MsvcLog
---@field current_build MsvcBuild|nil
---@field hooks_setup boolean
---@field solution_projects { name: string, path: string, guid: string }[]
local Msvc = {}
Msvc.__index = Msvc

--- Construct a fresh Msvc singleton with default config + state.
---@return Msvc
function Msvc:new()
    return setmetatable({
        config = Config.merge_config({}),
        state = State:new(),
        extensions = Ext.extensions,
        log = Log,
        current_build = nil,
        hooks_setup = false,
        -- Projects parsed from the active solution. Populated by
        -- `_warm_solution` during setup; drives `:Msvc project` completion.
        solution_projects = {},
        -- Transient `:Msvc update` overrides keyed by profile / resolve
        -- name. Cleared whenever the corresponding selection changes via
        -- `set_profile` / `set_resolve`, so picking a profile or resolve
        -- always starts from the configured baseline.
        profile_overrides = {},
        resolve_overrides = {},
        -- Cached list of Visual Studio installations discovered by the
        -- async vswhere lookup kicked off in `setup`. Used to drive
        -- `:Msvc update install_path` completion.
        vs_installations = {},
    }, self)
end

--- Sorted list of user-defined profile names (excludes `settings`,
--- `default`, `resolves`).
---@return string[]
local function list_profile_names(config)
    local names = {}
    for k, v in pairs(config or {}) do
        if
            type(v) == "table"
            and k ~= "settings"
            and k ~= "default"
            and k ~= "resolves"
        then
            names[#names + 1] = k
        end
    end
    table.sort(names)
    return names
end

--- Sorted list of user-defined resolve names.
---@return string[]
local function list_resolve_names(config)
    local names = {}
    for k, v in pairs((config or {}).resolves or {}) do
        if type(v) == "table" then
            names[#names + 1] = k
        end
    end
    table.sort(names)
    return names
end

--- Idempotent setup. Safe to call multiple times — the second call merges
--- new options into the existing config without re-registering autocmds.
---@param partial_config MsvcPartialConfig|nil
---@return Msvc self
function Msvc:setup(partial_config)
    -- Tolerate dot-call (`require("msvc").setup(opts)`) in addition to
    -- colon-call (`require("msvc"):setup(opts)`). README and most plugin
    -- managers (lazy.nvim, packer) use the dot form, which would otherwise
    -- bind `self` to the user's config table and silently drop every key.
    if self ~= Msvc and getmetatable(self) ~= Msvc then
        partial_config = self
        self = Msvc
    end
    -- Re-resolve the singleton when invoked statically so we mutate the
    -- same instance that `require("msvc")` returns to the rest of the code.
    if self == Msvc then
        self = require("msvc")
    end
    self.config = Config.merge_config(partial_config, self.config)
    Config.validate(self.config)
    Log:set_level(
        self.config.settings.log_level
            or self.config.settings.notify_level
            or vim.log.levels.INFO
    )
    if self.hooks_setup then
        return self
    end
    self.hooks_setup = true
    self:_warm_solution()
    Log:install_live_tail()
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = Autocmd.group,
        pattern = {
            "*.cpp",
            "*.h",
            "*.hpp",
            "*.c",
            "*.vcxproj",
            "*.sln",
        },
        callback = function(args)
            if not self.config.settings.build_on_save then
                return
            end
            self:build({ trigger = "BufWritePost", bufnr = args.buf })
        end,
    })
    self:_auto_select_defaults()
    self:_warm_install_path()
    return self
end

--- Walk up from cwd to find the nearest `.sln`, pin it on
--- `state.solution`, then parse and cache its project list. The solution
--- is treated as "always present and unique" for the lifetime of the
--- session — the project list is captured once at setup and is what
--- `:Msvc project` completes against.
function Msvc:_warm_solution()
    if self.state.solution and self.state.solution ~= "" then
        local existing = self.state.solution
        if Util.is_file(existing) then
            self.solution_projects = Discover.parse_solution_projects(existing)
            return
        end
    end
    local sln = Discover.find_solution()
    if not sln then
        Log:debug("warm solution: no .sln found above cwd")
        return
    end
    local norm = Util.normalize_path(sln) or sln
    self.state:set("solution", norm)
    self.solution_projects = Discover.parse_solution_projects(norm)
    Log:debug(
        "warm solution: %s (%d projects)",
        norm,
        #self.solution_projects
    )
end

--- On first setup, select the alphabetically-first user-defined profile
--- and resolve when nothing is active yet. Picking a stable order keeps
--- behaviour deterministic across Neovim restarts.
function Msvc:_auto_select_defaults()
    if not self.state:profile_name() then
        local profiles = list_profile_names(self.config)
        if profiles[1] then
            self:set_profile(profiles[1])
            Log:debug("auto-selected profile %q", profiles[1])
        end
    end
    if not self.state:resolve_name() then
        local resolves = list_resolve_names(self.config)
        if resolves[1] then
            self:set_resolve(resolves[1])
            Log:debug("auto-selected resolve %q", resolves[1])
        end
    end
end

--- Kick off an asynchronous vswhere lookup so that `state.install_path`
--- is populated by the time the user triggers a build / resolve. No-op
--- when an install_path is already known (state, configured default, or
--- the active resolve entry). Failures are silent — the synchronous
--- fallbacks in `Msvc:build` still run if needed.
function Msvc:_warm_install_path()
    if self.state.install_path and self.state.install_path ~= "" then
        return
    end
    local d = (self.config or {}).default or {}
    if type(d.install_path) == "string" and d.install_path ~= "" then
        return
    end
    local resolve_name = self.state:resolve_name()
    if resolve_name then
        local entry = Config.get_resolve(self.config, resolve_name) or {}
        if type(entry.install_path) == "string" and entry.install_path ~= "" then
            return
        end
    end
    local vswhere_path = d.vswhere_path
    if resolve_name then
        local entry = Config.get_resolve(self.config, resolve_name) or {}
        vswhere_path = entry.vswhere_path or vswhere_path
    end
    VsWhere.list_installations_async(
        { vswhere_path = vswhere_path },
        function(installs, err)
            if err then
                Log:debug("warm install_path: %s", err)
            end
            self.vs_installations = installs or {}
            local inst = VsWhere.pick_latest(installs)
            if not inst or not inst.installationPath then
                return
            end
            -- Don't clobber a value the user set between the spawn and
            -- the callback (e.g. via `:Msvc update install_path`).
            if self.state.install_path and self.state.install_path ~= "" then
                return
            end
            local install = Util.normalize_path(inst.installationPath)
            self.state:set("install_path", install)
            Log:debug("warm install_path resolved: %s", install)
        end
    )
end

--- Resolve the MSVC developer environment for the active resolve.
--- Reads parameters (arch / install_path / vcvars_ver / vs_*) from the
--- named entry under `config.resolves[<state.resolve>]` (merged over
--- `config.default`). `opts` overrides any field from the resolved entry.
--- On success returns the env table and stores `install_path` on state.
---@param opts table|nil
---@return table|nil env
function Msvc:resolve(opts)
    opts = opts or {}
    local name = opts.name or self.state:resolve_name()
    local entry = Config.get_resolve(self.config, name)
    local overrides = name and (self.resolve_overrides or {})[name] or nil
    if overrides and next(overrides) then
        entry = vim.tbl_extend("force", entry or {}, overrides)
    end
    opts.arch = opts.arch or self.state.arch or entry.arch
    opts.install_path = opts.install_path
        or self.state.install_path
        or entry.install_path
    if opts.vcvars_ver == nil then
        opts.vcvars_ver = entry.vcvars_ver
    end
    if opts.vswhere_path == nil then
        opts.vswhere_path = entry.vswhere_path
    end
    local env, err = DevEnv.resolve(opts)
    if not env then
        Log:error("env resolve failed: %s", tostring(err))
        return nil
    end
    if opts.install_path then
        self.state:set("install_path", opts.install_path)
    end
    return env
end

--- Resolve and cache only the VS installation path (no VsDevCmd).
--- Used by the build path when settings.use_dev_env = false so we avoid
--- sourcing VsDevCmd's default toolset into the spawned MSBuild env.
---@return string|nil install_path
function Msvc:resolve_install_path()
    if self.state.install_path and self.state.install_path ~= "" then
        return self.state.install_path
    end
    local d = self.config and self.config.default or {}
    local inst = VsWhere.find_latest({ vswhere_path = d.vswhere_path })
    if not inst or not inst.installationPath then
        Log:error("no Visual Studio installation found")
        return nil
    end
    local install = Util.normalize_path(inst.installationPath)
    self.state:set("install_path", install)
    return install
end

--- Run discover.find_solution from cwd and store the result on state.
---@return string|nil solution
function Msvc:auto_discover()
    self.state:auto_discover()
    return self.state.solution
end

--- Resolve a profile (named or default) into a flat table.
---@param name string|nil
---@return table profile
function Msvc:get_profile(name)
    local base
    if type(Config.get_config) == "function" then
        base = Config.get_config(self.config, name)
    else
        base = Config.get_profile(self.config, name)
    end
    local overrides = name and (self.profile_overrides or {})[name] or nil
    if overrides and next(overrides) then
        return vim.tbl_extend("force", base or {}, overrides)
    end
    return base
end

--- Kick off a new MSBuild invocation. Returns the MsvcBuild handle (or nil
--- on failure). Refuses to start if a build is already running.
--- Requires an active profile to be selected (`:Msvc profile <name>`).
--- The active resolve is consulted only when `settings.use_dev_env = true`
--- — in that case the env is sourced via `Msvc:resolve`, which itself
--- requires a resolve to be selected.
---@param opts table|nil
---@return MsvcBuild|nil
function Msvc:build(opts)
    opts = opts or {}
    if self.current_build and self.current_build:is_running() then
        Log:warn("a build is already running — cancel it first")
        return nil
    end
    local profile_name = opts.profile or self.state:profile_name()
    if not profile_name then
        Log:error("no profile selected — use `:Msvc profile <name>`")
        return nil
    end
    local profile = self:get_profile(profile_name)
    local project = opts.project
        or self.state.project
        or self.state.solution
    if not project then
        local sln = Discover.find_solution()
        if sln then
            self.state:set("solution", sln)
            project = sln
        end
    end
    if not project then
        Log:error("no .sln/.vcxproj found")
        return nil
    end
    local use_dev_env = self.config
            and self.config.settings
            and self.config.settings.use_dev_env
        or false
    local env, install_path
    if use_dev_env then
        local resolve_name = opts.resolve or self.state:resolve_name()
        if not resolve_name then
            Log:error(
                "use_dev_env=true but no resolve selected — use `:Msvc resolve <name>`"
            )
            return nil
        end
        env = self:resolve({ name = resolve_name })
        if not env then
            return nil
        end
        install_path = self.state.install_path
    else
        install_path = self:resolve_install_path()
        if not install_path then
            return nil
        end
    end
    local msbuild_path = (env and DevEnv.find_msbuild(env))
        or DevEnv.find_msbuild(install_path)
    if not msbuild_path then
        Log:error("MSBuild.exe not found")
        return nil
    end
    local configuration = opts.configuration or profile.configuration
    local platform = opts.platform or profile.platform
    if not configuration or configuration == "" then
        Log:error(
            "configuration is not set on profile %q — set `configuration` in the profile",
            profile_name
        )
        return nil
    end
    if not platform or platform == "" then
        Log:error(
            "platform is not set on profile %q — set `platform` in the profile",
            profile_name
        )
        return nil
    end
    local extra_args = profile.extra_args or profile.msbuild_args or {}
    if project:lower():match("%.vcxproj$") then
        local sln_dir
        if self.state.solution and self.state.solution ~= "" then
            sln_dir = vim.fn.fnamemodify(self.state.solution, ":h")
        else
            sln_dir = vim.fn.fnamemodify(project, ":h")
        end
        sln_dir = Util.normalize_path(sln_dir) or sln_dir
        local merged = {}
        for _, a in ipairs(extra_args) do
            merged[#merged + 1] = a
        end
        merged[#merged + 1] = "/p:SolutionDir=" .. sln_dir .. "\\"
        extra_args = merged
    end
    local ctx = {
        project = project,
        configuration = configuration,
        platform = platform,
        target = opts.target or profile.target,
        verbosity = profile.verbosity or "minimal",
        max_cpu_count = profile.max_cpu_count or profile.jobs or 0,
        no_logo = profile.no_logo ~= false,
        extra_args = extra_args,
        env = env,
        msbuild_path = msbuild_path,
        cwd = vim.fn.fnamemodify(project, ":h"),
    }
    local b = Build:new(ctx, opts):start()
    self.current_build = b
    return b
end

--- Cancel the in-flight build, if any.
function Msvc:cancel_build()
    if self.current_build and self.current_build:is_running() then
        self.current_build:cancel()
    else
        Log:info("no build running")
    end
end

--- Set the active named profile (looked up in `config[name]`).
---@param name string
function Msvc:set_profile(name)
    if name and self.profile_overrides then
        self.profile_overrides[name] = nil
    end
    self.state:set("profile", name)
end

--- Set the active named resolve (looked up in `config.resolves[name]`).
---@param name string
function Msvc:set_resolve(name)
    if name and self.resolve_overrides then
        self.resolve_overrides[name] = nil
    end
    self.state:set("resolve", name)
end

--- Pin the active project. Accepts either a project name from the cached
--- solution project list or an absolute / relative .vcxproj path. Returns
--- true on success.
---@param name_or_path string
---@return boolean
function Msvc:set_project(name_or_path)
    if not name_or_path or name_or_path == "" then
        self.state:set("project", nil)
        return true
    end
    for _, p in ipairs(self.solution_projects or {}) do
        if p.name == name_or_path then
            self.state:set("project", p.path)
            return true
        end
    end
    -- Fall back to treating the argument as a path. Normalize to absolute
    -- so internal state always holds a fully qualified location regardless
    -- of how the user typed it.
    local abs = vim.fn.fnamemodify(name_or_path, ":p")
    if abs == nil or abs == "" then
        abs = name_or_path
    end
    self.state:set("project", Util.normalize_path(abs) or abs)
    return true
end

--- Re-discover the .sln above cwd and refresh the cached project list.
---@return string|nil solution
function Msvc:auto_discover()
    self.state:auto_discover()
    if self.state.solution and self.state.solution ~= "" then
        self.solution_projects = Discover.parse_solution_projects(self.state.solution)
    else
        self.solution_projects = {}
    end
    return self.state.solution
end

--- Log a snapshot of the active solution / project / profile / resolve / install.
function Msvc:status()
    local s = self.state:get_snapshot()
    Log:info("solution = %s", tostring(s.solution or "<none>"))
    Log:info("project  = %s", tostring(s.project or "<none>"))
    Log:info("profile  = %s", tostring(self.state:profile_name() or "<none>"))
    Log:info("resolve  = %s", tostring(self.state:resolve_name() or "<none>"))
    Log:info("install  = %s", tostring(s.install_path or "<none>"))
end

local instance = Msvc:new()
return instance
