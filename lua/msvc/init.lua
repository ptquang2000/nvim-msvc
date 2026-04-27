-- msvc — singleton entry point. Modeled on harpoon2: `setup({...})` mutates
-- and returns the same singleton, so callers can keep a reference around
-- and observe state changes (e.g. `Msvc.solution`) directly.

local Config = require("msvc.config")
local Discover = require("msvc.discover")
local DevEnv = require("msvc.devenv")
local VsWhere = require("msvc.vswhere")
local Build = require("msvc.build")
local Log = require("msvc.log")
local Ext = require("msvc.extensions")
local Util = require("msvc.util")
local CompileCommands = require("msvc.compile_commands")

---@class Msvc
---@field config table             merged config (settings/default/profiles)
---@field solution string|nil      absolute path to active .sln (auto-discovered)
---@field project string|nil       absolute path to pinned .vcxproj (optional)
---@field profile_name string|nil  active profile name
---@field install table|nil        last-resolved vswhere installation record
---@field overrides table          per-session overrides keyed by profile field
---@field solution_projects table  cached `{ name=, path= }` from the active sln
---@field solution_candidates string[] paths of all `.sln` files reachable from cwd
local Msvc = {
    config = Config.get_default_config(),
    solution = nil,
    project = nil,
    profile_name = nil,
    install = nil,
    overrides = {},
    solution_projects = {},
    solution_candidates = {},
    _setup_called = false,
}

local function log_warn(...)
    Log:warn(...)
end

--- Return the active profile merged with any session-overrides.
function Msvc:active_profile()
    local prof = Config.get_profile(self.config, self.profile_name)
    if not prof then
        return nil
    end
    for k, v in pairs(self.overrides) do
        prof[k] = v
    end
    return prof
end

--- Resolve a Visual Studio installation matching the active profile.
--- Synchronous (vswhere is fast); cached on `self.install`. Force a refresh
--- by passing `{ refresh = true }`.
function Msvc:resolve_install(opts)
    opts = opts or {}
    if self.install and not opts.refresh then
        return self.install
    end
    local prof = self:active_profile() or {}
    self.install = VsWhere.find_latest({
        vswhere_path = prof.vswhere_path,
        vs_version = prof.vs_version,
        vs_prerelease = prof.vs_prerelease,
        vs_products = prof.vs_products,
        vs_requires = prof.vs_requires,
    })
    return self.install
end

--- Scan for `.sln` candidates (git-aware, excluding submodules and the
--- active profile's compile_commands `builddir`). When the previously
--- active solution still appears in the candidate set it is preserved;
--- when a unique candidate is discovered it is auto-selected; otherwise
--- the user must pick one with `:Msvc solution <path>`.
function Msvc:discover_solution()
    local prof = self:active_profile() or {}
    local cc = prof.compile_commands or {}
    local extra_dirs = {}
    if type(cc.builddir) == "string" and cc.builddir ~= "" then
        extra_dirs[#extra_dirs + 1] = cc.builddir
    end
    local cands = Discover.find_solutions(vim.fn.getcwd(), {
        extra_dirs = extra_dirs,
    })
    self.solution_candidates = cands

    local current = self.solution
    local kept = false
    if current and Util.is_file(current) then
        local lower = current:lower()
        for _, c in ipairs(cands) do
            if c:lower() == lower then
                kept = true
                break
            end
        end
    end
    if not kept then
        if #cands == 1 then
            self.solution = cands[1]
        else
            self.solution = nil
            self.project = nil
        end
    end
    self.solution_projects = self.solution
            and Discover.parse_solution_projects(self.solution)
        or {}
    return self.solution_candidates
end

--- Set the active profile by name. Returns true on success.
function Msvc:set_profile(name)
    if not self.config.profiles[name] then
        Log:error("msvc: unknown profile %q", tostring(name))
        return false
    end
    self.profile_name = name
    self.overrides = {}
    self.install = nil
    return true
end

--- Set a per-session override on the active profile (e.g. flip platform
--- between Win32 and x64 for one build). Cleared by `:Msvc profile <name>`.
function Msvc:set_override(field, value)
    self.overrides[field] = value
    if
        field == "vs_version"
        or field == "vs_prerelease"
        or field == "vs_products"
        or field == "vs_requires"
        or field == "vswhere_path"
    then
        self.install = nil
    end
end

--- Pin a .vcxproj as the build target. Accepts either a project name
--- (matching one of `solution_projects`) or a filesystem path. Pass nil
--- or "" to clear.
function Msvc:set_project(path)
    if path == nil or path == "" then
        self.project = nil
        return true
    end
    -- Try to match a name from the active solution first.
    for _, entry in ipairs(self.solution_projects or {}) do
        if entry.name == path then
            self.project = entry.path
            return true
        end
    end
    local norm = Util.normalize_path(path)
    if not Util.is_file(norm) then
        Log:error("msvc: project not found: %s", tostring(path))
        return false
    end
    self.project = norm
    return true
end

--- Select an active solution from the discovered candidate set, by
--- absolute path or basename. Pass nil / "" / "-" to clear. Switching
--- solutions clears any pinned project (it almost certainly belongs to
--- the previous solution) and refreshes `solution_projects` so the
--- `:Msvc project` completion list reflects the new sln.
function Msvc:set_solution(path)
    if path == nil or path == "" then
        self.solution = nil
        self.solution_projects = {}
        self.project = nil
        return true
    end
    local cands = self.solution_candidates or {}
    -- Match against full path or basename within the candidate set.
    for _, cand in ipairs(cands) do
        if cand == path or cand:lower() == tostring(path):lower() then
            self.solution = cand
            self.solution_projects = Discover.parse_solution_projects(cand)
            self.project = nil
            return true
        end
    end
    for _, cand in ipairs(cands) do
        if Util.basename(cand) == path then
            self.solution = cand
            self.solution_projects = Discover.parse_solution_projects(cand)
            self.project = nil
            return true
        end
    end
    local norm = Util.normalize_path(path)
    if not norm or not Util.is_file(norm) then
        Log:error("msvc: solution not found: %s", tostring(path))
        return false
    end
    self.solution = norm
    self.solution_projects = Discover.parse_solution_projects(norm)
    self.project = nil
    return true
end

local function pick_target(self)
    return self.project or self.solution
end

--- Run a build. `target_override` is the optional MSBuild `/t:` argument
--- (defaults to MSBuild's own default — Build for sln, Build for vcxproj).
function Msvc:build(target_override)
    local target_path = pick_target(self)
    if not target_path then
        Log:error(
            "msvc: no .sln or .vcxproj selected (cd into a project tree, then `:Msvc discover`)"
        )
        return false
    end
    local prof = self:active_profile()
    if not prof then
        Log:error(
            "msvc: no active profile (set `settings.default_profile` or call `:Msvc profile <name>`)"
        )
        return false
    end

    local install = self:resolve_install()
    if not install or not install.installationPath then
        Log:error(
            "msvc: failed to resolve a Visual Studio install for profile %q",
            tostring(self.profile_name)
        )
        return false
    end
    local install_path = install.installationPath

    local msbuild = DevEnv.find_msbuild(install_path)
    if not msbuild then
        Log:error("msvc: MSBuild.exe not found under %s", install_path)
        return false
    end

    -- MSBuild self-bootstraps the per-project toolset from
    -- <PlatformToolset>; it does NOT need vcvars sourced. Resolving
    -- vcvars takes ~5s and would freeze the UI before the live log
    -- can paint, so we leave `env = nil` here. The compile_commands
    -- extractor (post-build, asynchronous) resolves vcvars on its
    -- own when it actually needs MSBuildLocator.

    local msbuild_args = prof.msbuild_args or {}
    -- When the target is a bare .vcxproj, MSBuild resolves $(SolutionDir)
    -- to the project directory by default — which breaks projects that
    -- reference shared `$(SolutionDir)` paths (intermediate / output
    -- dirs, NuGet packages, etc.). Pin it to the active solution dir.
    if target_path:lower():match("%.vcxproj$") then
        local sln_dir = self.solution and Util.dirname(self.solution)
            or Util.dirname(target_path)
        sln_dir = Util.normalize_path(sln_dir)
        local merged = {}
        for _, a in ipairs(msbuild_args) do
            merged[#merged + 1] = a
        end
        merged[#merged + 1] = "/p:SolutionDir=" .. sln_dir .. "\\"
        msbuild_args = merged
    end

    local self_ref = self
    return Build.spawn({
        msbuild = msbuild,
        target_path = target_path,
        configuration = prof.configuration,
        platform = prof.platform,
        jobs = prof.jobs,
        msbuild_args = msbuild_args,
        target = target_override or prof.target,
        on_done = function(ok)
            if ok then
                self_ref:_run_compile_commands(prof, install_path)
            end
        end,
    })
end

function Msvc:rebuild()
    return self:build("Rebuild")
end

function Msvc:clean()
    return self:build("Clean")
end

function Msvc:cancel()
    return Build.cancel()
end

function Msvc:_run_compile_commands(prof, install_path)
    local cc = (prof and prof.compile_commands) or {}
    if not CompileCommands.is_enabled(cc) then
        return
    end
    -- Resolve the dev-prompt env lazily here. The extractor's
    -- MSBuildLocator needs INCLUDE / LIB / .NET probe paths; resolving
    -- ~5s here is fine because it runs in the BUILD_DONE callback after
    -- MSBuild already exited (the live log is fully painted).
    local env, err = DevEnv.resolve({
        install = install_path,
        arch = prof.arch or "x64",
        vcvars_ver = prof.vcvars_ver,
        winsdk = prof.winsdk,
    })
    if err then
        Log:build_append("compile_commands [WARN]: %s", err)
        return
    end
    local extra_projects = {}
    for _, entry in ipairs(self.solution_projects or {}) do
        extra_projects[#extra_projects + 1] = entry.path
    end
    CompileCommands.generate({
        solution = self.solution,
        project = self.project,
        extra_projects = extra_projects,
        configuration = prof.configuration,
        platform = prof.platform,
        cc = cc,
        env = env,
        vs_path = install_path,
    })
end

--- Public setup. Merges user config, validates, applies log level, and
--- auto-discovers a .sln in cwd. Returns the singleton.
local function do_setup(self, user_config)
    self._setup_called = true
    self.config = Config.merge_config(user_config)
    Config.validate(self.config)

    Log:set_level(self.config.settings.log_level or "info")
    Log:install_live_tail()

    if self.config.settings.default_profile then
        self.profile_name = self.config.settings.default_profile
    end

    self:discover_solution()

    if self.config.settings.build_on_save then
        local group = vim.api.nvim_create_augroup("Msvc", { clear = true })
        vim.api.nvim_create_autocmd("BufWritePost", {
            group = group,
            pattern = { "*.c", "*.cpp", "*.h", "*.hpp", "*.cxx", "*.cc" },
            callback = function()
                self:build()
            end,
        })
    end

    require("msvc.commands").setup(self)
    Ext.extensions:emit(Ext.event_names.SETUP_CALLED, self)
    return self
end

-- Allow either `Msvc.setup(opts)` (dot-call) or `Msvc:setup(opts)` (colon-call).
function Msvc.setup(arg, maybe_opts)
    if arg == Msvc then
        return do_setup(Msvc, maybe_opts)
    end
    return do_setup(Msvc, arg)
end

return Msvc
