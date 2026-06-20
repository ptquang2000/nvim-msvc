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
---@field config table             merged config (settings layer only)
---@field solution string|nil      absolute path to active .sln
---@field project string|nil       absolute path to pinned .vcxproj (optional)
---@field settings table           flat build-settings for the active context
---@field install table|nil        last-resolved vswhere installation record
---@field solution_projects table  cached `{ name=, path= }` from the active sln
---@field solutions string[] paths of all registered `.sln` files
local Msvc = {
    config = Config.get_default_config(),
    solution = nil,
    project = nil,
    settings = vim.deepcopy(Config.DEFAULT_SETTINGS),
    install = nil,
    solution_projects = {},
    solutions = {},
    _setup_called = false,
    _context_store = {},
    _last_build_key = nil,
    _default_settings = nil,
}

local function log_warn(...)
    Log:warn(...)
end

local function make_context_key(solution, project)
    return (solution or "") .. "\0" .. (project or "")
end

function Msvc:_save_context()
    local key = make_context_key(self.solution, self.project)
    self._context_store[key] = vim.deepcopy(self.settings)
end

function Msvc:_load_context(solution, project)
    local key = make_context_key(solution, project)
    local stored = self._context_store[key]
    if stored then
        self.settings = vim.deepcopy(stored)
    else
        self.settings = vim.deepcopy(self._default_settings or Config.DEFAULT_SETTINGS)
    end
    self.install = nil
end

--- Discard all context-store entries whose solution component matches `path`
--- (case-insensitive). Called when a solution is unstaged to prevent stale
--- settings from silently re-applying if the solution is staged again.
function Msvc:_discard_solution_context(path)
    if not path then return end
    local lower = path:lower()
    local to_delete = {}
    for key in pairs(self._context_store) do
        local sep = key:find("\0", 1, true)
        if sep then
            local sln_part = key:sub(1, sep - 1)
            if sln_part:lower() == lower then
                to_delete[#to_delete + 1] = key
            end
        end
    end
    for _, key in ipairs(to_delete) do
        self._context_store[key] = nil
    end
end

--- Resolve a Visual Studio installation matching the active settings.
--- Synchronous (vswhere is fast); cached on `self.install`. Force a refresh
--- by passing `{ refresh = true }`.
function Msvc:resolve_install(opts)
    opts = opts or {}
    if self.install and not opts.refresh then
        return self.install
    end
    local s = self.settings or {}
    local cfg = self.config.settings or {}
    self.install = VsWhere.find_latest({
        vswhere_path = cfg.vswhere_path,
        vs_version = s.vs_version,
        vs_requires = cfg.vs_requires,
    })
    return self.install
end

--- Pin a .vcxproj as the build target. Accepts either a project name
--- (matching one of `solution_projects`) or a filesystem path. Pass nil
--- or "" to clear.
function Msvc:set_project(path)
    local new_project
    if path == nil or path == "" then
        new_project = nil
    else
        for _, entry in ipairs(self.solution_projects or {}) do
            if entry.name == path then
                new_project = entry.path
                break
            end
        end
        if not new_project then
            local norm = Util.normalize_path(path)
            if not Util.is_file(norm) then
                Log:error("msvc: project not found: %s", tostring(path))
                return false
            end
            new_project = norm
        end
    end

    self:_save_context()
    self.project = new_project
    self:_load_context(self.solution, new_project)
    return true
end

--- Select an active solution from the discovered candidate set, by
--- absolute path or basename. Pass nil / "" to clear. Switching
--- solutions clears any pinned project and refreshes `solution_projects`.
function Msvc:set_solution(path)
    local new_solution
    if path == nil or path == "" then
        new_solution = nil
    else
        local cands = self.solutions or {}
        for _, cand in ipairs(cands) do
            if cand == path or cand:lower() == tostring(path):lower() then
                new_solution = cand
                break
            end
        end
        if not new_solution then
            for _, cand in ipairs(cands) do
                if Util.basename(cand) == path then
                    new_solution = cand
                    break
                end
            end
        end
        if not new_solution then
            local norm = Util.normalize_path(path)
            if not norm or not Util.is_file(norm) then
                Log:error("msvc: solution not found: %s", tostring(path))
                return false
            end
            new_solution = norm
        end
    end

    self:_save_context()
    self.solution = new_solution
    self.solution_projects = new_solution
            and Discover.parse_solution_projects(new_solution)
        or {}
    self.project = nil
    self:_load_context(new_solution, nil)

    if new_solution then
        local install = self:resolve_install()
        self:_run_compile_commands(
            self.settings,
            install and install.installationPath
        )
    end

    return true
end

local function pick_target(self)
    return self.project or self.solution
end

--- Run a build. `target_override` is the optional MSBuild `/t:` argument.
function Msvc:build(target_override)
    local target_path = pick_target(self)
    if not target_path then
        Log:error(
            "msvc: no .sln or .vcxproj selected (open a .sln buffer or use the msvc:// buffer)"
        )
        return false
    end
    local s = self.settings or {}
    if not s.configuration or s.configuration == "" then
        Log:error(
            "msvc: configuration is not set — open the msvc:// buffer and set it"
        )
        return false
    end
    if not s.platform or s.platform == "" then
        Log:error(
            "msvc: platform is not set — open the msvc:// buffer and set it"
        )
        return false
    end

    local install = self:resolve_install()
    if not install or not install.installationPath then
        Log:error("msvc: failed to resolve a Visual Studio installation")
        return false
    end
    local install_path = install.installationPath

    local msbuild = DevEnv.find_msbuild(install_path)
    if not msbuild then
        Log:error("msvc: MSBuild.exe not found under %s", install_path)
        return false
    end

    -- When building a bare .vcxproj, pin SolutionDir to the active solution
    -- directory (or the vcxproj directory) so $(SolutionDir) resolves correctly.
    local solution_dir
    if target_path:lower():match("%.vcxproj$") then
        local sln_dir = self.solution and Util.dirname(self.solution)
            or Util.dirname(target_path)
        solution_dir = Util.normalize_path(sln_dir)
    end

    local self_ref = self
    self._last_build_key = make_context_key(self.solution, self.project)
    return Build.spawn({
        msbuild = msbuild,
        target_path = target_path,
        configuration = s.configuration,
        platform = s.platform,
        jobs = s.jobs,
        solution_dir = solution_dir,
        target = target_override,
        on_done = function(ok)
            if ok then
                self_ref:_run_compile_commands(s, install_path)
            end
        end,
    })
end

--- Dispatch single-file compile via MSBuild ClCompile target.
function Msvc:build_file(file_path)
    if not self.project then
        Log:error(
            "msvc: single-file compile requires a pinned .vcxproj project"
        )
        return false
    end
    if not file_path or file_path == "" then
        Log:error("msvc: no source file captured (was msvc:// opened from a source buffer?)")
        return false
    end
    local s = self.settings or {}
    if not s.configuration or not s.platform then
        Log:error("msvc: configuration and platform must be set before building")
        return false
    end
    local install = self:resolve_install()
    if not install or not install.installationPath then
        Log:error("msvc: failed to resolve a Visual Studio installation")
        return false
    end
    local msbuild = DevEnv.find_msbuild(install.installationPath)
    if not msbuild then
        Log:error("msvc: MSBuild.exe not found")
        return false
    end
    local sln_dir = self.solution and Util.dirname(self.solution)
        or Util.dirname(self.project)
    self._last_build_key = make_context_key(self.solution, self.project)
    return Build.spawn({
        msbuild = msbuild,
        target_path = self.project,
        configuration = s.configuration,
        platform = s.platform,
        jobs = s.jobs,
        target = "ClCompile",
        solution_dir = Util.normalize_path(sln_dir),
        selected_files = file_path,
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

function Msvc:_run_compile_commands(settings, install_path)
    local cc = (self.config.settings or {}).compile_commands or {}
    if not CompileCommands.is_enabled(cc) then
        return
    end
    CompileCommands.generate({
        solution = self.solution,
        project = self.project,
        configuration = settings and settings.configuration,
        platform = settings and settings.platform,
        jobs = settings and settings.jobs,
        cc = cc,
        vs_path = install_path,
    })
end

--- Public setup. Merges user config, validates, applies log level, and
--- auto-discovers a .sln in cwd. Returns the singleton.
local function do_setup(self, user_config)
    self._setup_called = true
    self.config = Config.merge_config(user_config)
    Config.validate(self.config)
    self._default_settings = self.config.default_settings

    Log:set_level(self.config.settings.log_level or "info")
    Log:install_live_tail()

    -- Startup: auto-select if exactly one .sln in cwd
    local cwd = vim.fn.getcwd()
    local startup_slns = vim.fn.glob(Util.join_path(cwd, "*.sln"), true, true)
    if type(startup_slns) == "table" and #startup_slns == 1 then
        local norm = Util.normalize_path(startup_slns[1])
        if norm and Util.is_file(norm) then
            self.solutions = { norm }
            self:set_solution(norm)
        end
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
