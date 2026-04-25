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
local CompileCommands = require("msvc.compile_commands")

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
        -- Transient `:Msvc update` overrides keyed by profile name.
        -- Cleared whenever the profile is re-selected via `set_profile`,
        -- so picking a profile always starts from the configured baseline.
        profile_overrides = {},
        -- Cached list of Visual Studio installations discovered by the
        -- async vswhere lookup kicked off in `setup`. Used to drive
        -- `:Msvc update install_path` completion.
        vs_installations = {},
    }, self)
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
    self:_install_compile_commands_listener()
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

--- Register an extension listener that auto-runs the
--- msbuild-extractor-sample tool after a successful `:Msvc build` to
--- (re)generate compile_commands.json. Idempotent: setup() is guarded by
--- `hooks_setup`, but we additionally guard against accidental
--- re-installation by checking a flag on the singleton.
function Msvc:_install_compile_commands_listener()
    if self._compile_commands_listener_installed then
        return
    end
    self._compile_commands_listener_installed = true
    local self_ = self
    self.extensions:add_listener({
        [Ext.event_names.BUILD_DONE] = function(build, ok, _elapsed_ms)
            if not ok then
                return
            end
            local cc = self_.config
                and self_.config.settings
                and self_.config.settings.compile_commands
            if not CompileCommands.is_enabled(cc) then
                return
            end
            local ctx = (build and build.ctx) or {}
            -- Prefer the active solution as the extractor's primary
            -- input; fall back to whatever project MSBuild ran against.
            local solution = self_.state.solution
            local project = ctx.project
            local is_sln = type(project) == "string"
                and project:lower():match("%.sln[x]?$") ~= nil
            if is_sln and (not solution or solution == "") then
                solution = project
                project = nil
            end
            -- The extractor MUST be invoked under a fully-populated
            -- developer-prompt env; without it MSBuildLocator falls
            -- back to a .NET SDK probe and crashes when no SDK is
            -- installed ("No .NET SDKs were found" / 0xE0434352). The
            -- build path may have run without sourcing the dev env
            -- (its preferred mode for mixed-toolset solutions), so we
            -- resolve it here unconditionally. `DevEnv.resolve` is
            -- cached per (install_path, arch, vcvars_ver) so the call
            -- is cheap on subsequent builds.
            local env = ctx.env
            if type(env) ~= "table" or env.VSINSTALLDIR == nil then
                env = self_:resolve({ profile = self_.state:profile_name() })
                    or env
            end
            CompileCommands.generate({
                solution = solution,
                project = project,
                configuration = ctx.configuration,
                platform = ctx.platform,
                env = env,
                cc = cc,
            })
        end,
    })
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
    Log:debug("warm solution: %s (%d projects)", norm, #self.solution_projects)
end

--- On first setup, select the alphabetically-first user-defined profile
--- when nothing is active yet. Picking a stable order keeps behaviour
--- deterministic across Neovim restarts.
function Msvc:_auto_select_defaults()
    if not self.state:profile_name() then
        local profiles = Config.list_profile_names(self.config)
        if profiles[1] then
            self:set_profile(profiles[1], true)
            Log:debug("auto-selected profile %q", profiles[1])
        end
    end
end

--- Kick off an asynchronous vswhere lookup so that `state.install_path`
--- is populated by the time the user triggers a build / resolve. No-op
--- when an install_path is already known (state or configured profile).
--- Failures are silent — the synchronous fallbacks in `Msvc:build`
--- still run if needed.
function Msvc:_warm_install_path()
    if self.state.install_path and self.state.install_path ~= "" then
        return
    end
    local profile_name = self.state:profile_name()
    local profile_view = Config.get_profile(self.config, profile_name)
    if
        type(profile_view.install_path) == "string"
        and profile_view.install_path ~= ""
    then
        return
    end
    local vswhere_path = profile_view.vswhere_path
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

--- Resolve the MSVC developer environment for the active profile. Reads
--- parameters (arch / install_path / vcvars_ver / vs_*) from the merged
--- profile view (`profiles.default` ⨉ `profiles[name]`) plus any active
--- `:Msvc update` overrides. `opts` overrides any field from the
--- resolved entry.
--- On success returns the env table and stores `install_path` on state.
---@param opts table|nil
---@return table|nil env
function Msvc:resolve(opts)
    opts = opts or {}
    local profile_name = opts.profile or self.state:profile_name()
    local entry = self:get_profile(profile_name)
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
--- Used by the build path so we avoid sourcing VsDevCmd's default
--- toolset into the spawned MSBuild env (MSBuild resolves per-project
--- toolsets from <PlatformToolset> on its own).
---@return string|nil install_path
function Msvc:resolve_install_path()
    if self.state.install_path and self.state.install_path ~= "" then
        return self.state.install_path
    end
    local profile_view =
        Config.get_profile(self.config, self.state:profile_name())
    local inst =
        VsWhere.find_latest({ vswhere_path = profile_view.vswhere_path })
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
    if self.state.solution and self.state.solution ~= "" then
        self.solution_projects =
            Discover.parse_solution_projects(self.state.solution)
    else
        self.solution_projects = {}
    end
    return self.state.solution
end

--- Resolve a profile (named or default) into a flat table holding both
--- MSBuild and dev-env fields. Includes any active `:Msvc update`
--- overrides.
---@param name string|nil
---@return table profile
function Msvc:get_profile(name)
    local base = Config.get_profile(self.config, name)
    local overrides = name and (self.profile_overrides or {})[name] or nil
    if overrides and next(overrides) then
        return vim.tbl_extend("force", base or {}, overrides)
    end
    return base
end

--- Kick off a new MSBuild invocation. Returns the MsvcBuild handle (or nil
--- on failure). Refuses to start if a build is already running.
--- Requires an active profile to be selected (`:Msvc profile <name>`).
--- The build path resolves only the VS installation root (no VsDevCmd
--- sourcing) so MSBuild can pick per-project toolsets from
--- <PlatformToolset>. The compile_commands extractor, in contrast,
--- always receives a fully-resolved developer-prompt env (see
--- `_install_compile_commands_listener`).
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
    local project = opts.project or self.state.project or self.state.solution
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
    local install_path = self:resolve_install_path()
    if not install_path then
        return nil
    end
    local msbuild_path = DevEnv.find_msbuild(install_path)
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
        env = nil,
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

--- Emit a multi-line, sorted "key = value" log of the active profile's
--- effective fields (config + transient overrides).
---@param name string
function Msvc:log_profile(name)
    if not name then
        return
    end
    local entry = self:get_profile(name)
    local lines = Config.format_entry_lines(("profile=%s"):format(name), entry)
    for _, line in ipairs(lines) do
        Log:info("%s", line)
    end
end

--- Set the active named profile (looked up in `config.profiles[name]`).
--- Clears any transient overrides on the profile.
---@param name string
---@param silent? boolean Skip verbose logging (used during setup auto-select).
function Msvc:set_profile(name, silent)
    if name and self.profile_overrides then
        self.profile_overrides[name] = nil
    end
    self.state:set("profile", name)
    if name and not silent then
        self:log_profile(name)
    end
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

--- Log a snapshot of the active solution / project / profile / install.
--- The profile section is expanded with its full field set (sorted, one
--- key per line) for verbose introspection.
function Msvc:status()
    local s = self.state:get_snapshot()
    Log:info("solution = %s", tostring(s.solution or "<none>"))
    Log:info("project  = %s", tostring(s.project or "<none>"))
    Log:info("install  = %s", tostring(s.install_path or "<none>"))
    local profile_name = self.state:profile_name()
    if profile_name then
        self:log_profile(profile_name)
    else
        Log:info("profile  = <none>")
    end
end

local instance = Msvc:new()
return instance
