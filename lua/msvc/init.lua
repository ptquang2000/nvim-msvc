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
local ProjectScan = require("msvc.project_scan")

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
        -- async vswhere lookup kicked off in `setup`. Used to drive the
        -- `vs_*` field completion candidates.
        vs_installations = {},
        -- Async-warmed completion candidates derived from the vswhere
        -- output. Each list is empty until `_warm_vs_installations`
        -- completes; `commands.lua` falls back to a static list while
        -- the warm is in flight.
        vs_completion_candidates = {
            vs_version = {},
            vs_prerelease = { "false", "true" },
            vs_products = {},
            vs_requires = {},
        },
        -- Project-level completion candidates derived from .sln /
        -- .vcxproj scanning. Populated by `_warm_project_targets`.
        project_targets = {
            configurations = {},
            platforms = {},
        },
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
    -- `settings.default_profile` is required: it names the root profile
    -- that is both activated on setup and merged under every named
    -- profile during build resolution.
    local s = self.config.settings or {}
    if type(s.default_profile) ~= "string" or s.default_profile == "" then
        error(
            "msvc.setup: `settings.default_profile` is required — set it to the name of an entry in `profiles`",
            2
        )
    end
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
    self:_warm_vs_installations()
    self:_warm_project_targets()
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
            -- Pass every project parsed from the solution as an extra
            -- --project input. The extractor's solution-mode pass alone
            -- yields very few flags for some project types (notably WDK
            -- kernel-mode driver projects); the per-project pass +
            -- `--deduplicate` recovers the richer command for IntelliSense.
            local extra_projects = {}
            for _, p in ipairs(self_.solution_projects or {}) do
                if type(p) == "table" and type(p.path) == "string" then
                    extra_projects[#extra_projects + 1] = p.path
                end
            end
            CompileCommands.generate({
                solution = solution,
                project = project,
                extra_projects = extra_projects,
                configuration = ctx.configuration,
                platform = ctx.platform,
                env = env,
                vs_path = self_.state.install_path,
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

--- On first setup, activate the configured root profile. Validation has
--- already guaranteed `settings.default_profile` names an existing
--- profile, so this is a deterministic, fall-back-free operation.
function Msvc:_auto_select_defaults()
    if self.state:profile_name() then
        return
    end
    local name = self.config.settings.default_profile
    self:set_profile(name, true)
    Log:debug("loaded default_profile %q", name)
end

--- Build a sorted, deduplicated copy of `list` (string entries only).
---@param list string[]
---@return string[]
local function sorted_unique(list)
    local seen, out = {}, {}
    for _, v in ipairs(list) do
        if type(v) == "string" and v ~= "" and not seen[v] then
            seen[v] = true
            out[#out + 1] = v
        end
    end
    table.sort(out)
    return out
end

--- Extract the leading major (integer) from a vswhere installationVersion.
---@param iv string|nil
---@return integer|nil
local function major_of(iv)
    if type(iv) ~= "string" then
        return nil
    end
    local m = iv:match("^(%d+)")
    return m and tonumber(m) or nil
end

--- Sort `vs_version` candidates: `"latest"` first, then by parsed major
--- desc, then by full numeric tuple desc, ties alphabetical. Mutates and
--- returns a deduplicated copy of `list`.
---@param list string[]
---@return string[]
local function sort_vs_versions(list)
    local seen, deduped = {}, {}
    for _, v in ipairs(list) do
        if type(v) == "string" and v ~= "" and not seen[v] then
            seen[v] = true
            deduped[#deduped + 1] = v
        end
    end
    local function tuple(s)
        local t = {}
        for n in s:gmatch("(%d+)") do
            t[#t + 1] = tonumber(n) or 0
        end
        return t
    end
    table.sort(deduped, function(a, b)
        if a == "latest" then
            return true
        end
        if b == "latest" then
            return false
        end
        local ma = tonumber(a:match("^%[?(%d+)")) or 0
        local mb = tonumber(b:match("^%[?(%d+)")) or 0
        if ma ~= mb then
            return ma > mb
        end
        local ta, tb = tuple(a), tuple(b)
        for i = 1, math.max(#ta, #tb) do
            local ai, bi = ta[i] or 0, tb[i] or 0
            if ai ~= bi then
                return ai > bi
            end
        end
        return a < b
    end)
    return deduped
end

--- Derive the four `vs_*` completion lists from a vswhere installs array
--- and store them on `self.vs_completion_candidates`. Safe to call with
--- an empty/nil install list — the result is a deterministic static
--- fallback (`"latest"`, the four well-known product IDs, etc).
---
--- `vs_version` shape (canonical vswhere inputs only):
---   * `"latest"` — sentinel; translates to "no -version flag".
---   * Each install's full `installationVersion` (e.g. `"17.14.37216.2"`).
---   * For each unique major M parsed from `installationVersion`: the
---     range string `"[M.0,(M+1).0)"` (e.g. `"[17.0,18.0)"`).
--- Marketing-year (`"2017"` / `"2022"`) and bare-major (`"15"` / `"17"`)
--- forms are deliberately **not** suggested — they are still accepted as
--- freehand input and translated by `vswhere.translate_version`.
---@param installs table[]|nil
function Msvc:_populate_vs_completion_candidates(installs)
    installs = installs or {}

    local versions = { "latest" }
    local seen_versions = { latest = true }
    local majors_seen = {}

    local products = {
        "Microsoft.VisualStudio.Product.Community",
        "Microsoft.VisualStudio.Product.Professional",
        "Microsoft.VisualStudio.Product.Enterprise",
        "Microsoft.VisualStudio.Product.BuildTools",
    }
    local requires = {}

    for _, inst in ipairs(installs) do
        local iv = inst.installationVersion
        if type(iv) == "string" and iv ~= "" and not seen_versions[iv] then
            seen_versions[iv] = true
            versions[#versions + 1] = iv
        end
        local maj = major_of(iv)
        if maj and not majors_seen[maj] then
            majors_seen[maj] = true
            local rng = string.format("[%d.0,%d.0)", maj, maj + 1)
            if not seen_versions[rng] then
                seen_versions[rng] = true
                versions[#versions + 1] = rng
            end
        end
        if type(inst.productId) == "string" and inst.productId ~= "" then
            products[#products + 1] = inst.productId
        end
        if type(inst.packages) == "table" then
            for _, pkg in ipairs(inst.packages) do
                if
                    type(pkg) == "table"
                    and type(pkg.id) == "string"
                    and pkg.id ~= ""
                    and (pkg.type == "Component" or pkg.type == "Workload")
                then
                    requires[#requires + 1] = pkg.id
                end
            end
        end
        -- NOTE: catalog.productLineVersion intentionally NOT added —
        -- vswhere does not accept marketing-year tokens on -version.
    end

    self.vs_completion_candidates = {
        vs_version = sort_vs_versions(versions),
        vs_prerelease = { "false", "true" },
        vs_products = sorted_unique(products),
        vs_requires = sorted_unique(requires),
    }
end

--- Atomically write `state.install_path` and the friendly metadata
--- (`install_display_name`, `install_version`,
--- `install_product_line_version`) derived from a vswhere install record.
--- Missing/empty record fields clear the corresponding state field.
---@param inst table  vswhere install entry (must have installationPath)
function Msvc:_set_install_from_record(inst)
    local path = Util.normalize_path(inst.installationPath)
        or inst.installationPath
    local catalog = type(inst.catalog) == "table" and inst.catalog or {}
    local function s_or_nil(v)
        if type(v) == "string" and v ~= "" then
            return v
        end
        return nil
    end
    self.state:set("install_path", path)
    self.state:set("install_display_name", s_or_nil(inst.displayName))
    self.state:set("install_version", s_or_nil(inst.installationVersion))
    self.state:set(
        "install_product_line_version",
        s_or_nil(catalog.productLineVersion)
    )
end

--- Atomically clear `state.install_path` and all install_* friendlies.
function Msvc:_clear_install()
    self.state:set("install_path", nil)
    self.state:set("install_display_name", nil)
    self.state:set("install_version", nil)
    self.state:set("install_product_line_version", nil)
end

--- Kick off two asynchronous vswhere lookups in parallel:
---
--- (1) UNFILTERED warm — drives `vs_completion_candidates` so the menu
---     lists every install on the machine regardless of the active
---     profile filters. Always passes `vs_prerelease=true` and
---     `include_packages=true`; never forwards `vs_version` /
---     `vs_products` / `vs_requires` from the profile.
---
--- (2) FILTERED resolve — populates `state.install_path` (+ friendlies)
---     using the active profile filters. Skipped when `install_path` is
---     already cached (the user has a pinned selection we should not
---     silently overwrite).
---
--- Failures are independent and silent: a failing unfiltered warm leaves
--- completion candidates empty (the static fallback in `commands.lua`
--- still kicks in); a failing filtered resolve leaves `install_path` nil.
function Msvc:_warm_vs_installations()
    local profile_name = self.state:profile_name()
    local profile_view = self:get_profile(profile_name)
    local vswhere_path = profile_view.vswhere_path

    -- (1) Unfiltered warm — completion candidates only.
    VsWhere.list_installations_async({
        vswhere_path = vswhere_path,
        vs_prerelease = true,
        include_packages = true,
    }, function(installs, err)
        if err then
            Log:debug("warm vs_installations (unfiltered): %s", err)
        end
        self.vs_installations = installs or {}
        self:_populate_vs_completion_candidates(installs or {})
    end)

    -- (2) Filtered resolve — only when no install_path is cached.
    if self.state.install_path and self.state.install_path ~= "" then
        return
    end
    VsWhere.list_installations_async({
        vswhere_path = vswhere_path,
        vs_version = profile_view.vs_version,
        vs_prerelease = profile_view.vs_prerelease,
        vs_products = profile_view.vs_products,
        vs_requires = profile_view.vs_requires,
    }, function(installs, err)
        if err then
            Log:debug("warm vs_installations (active): %s", err)
        end
        local inst = VsWhere.pick_latest(installs)
        if not inst or not inst.installationPath then
            return
        end
        -- Don't clobber a value the user set between the spawn and
        -- the callback (e.g. via an explicit state mutation). Callers
        -- that want a re-resolve (e.g. `:Msvc update vs_version <X>`)
        -- must clear `state.install_path` BEFORE calling this so the
        -- callback fills the freshly-empty cache.
        if self.state.install_path and self.state.install_path ~= "" then
            return
        end
        self:_set_install_from_record(inst)
        Log:debug(
            "warm vs_installations resolved install_path: %s",
            self.state.install_path
        )
    end)
end

--- Scan the active solution + its referenced projects for the set of
--- `Configuration|Platform` tuples and store them on
--- `self.project_targets`. Falls back to a minimal default list when no
--- .sln/.vcxproj files are found, so completion always returns
--- something useful even outside a project tree.
function Msvc:_warm_project_targets()
    vim.schedule(function()
        local files = {}
        local solution = self.state.solution
        if type(solution) == "string" and Util.is_file(solution) then
            files[#files + 1] = solution
            for _, p in ipairs(self.solution_projects or {}) do
                if type(p) == "table" and type(p.path) == "string" then
                    files[#files + 1] = p.path
                end
                if #files >= 1 + 8 then
                    break
                end
            end
        else
            files = ProjectScan.find_targets_in_cwd({ depth = 2, cap = 50 })
        end
        if #files == 0 then
            self.project_targets = ProjectScan.fallback_defaults()
            return
        end
        local pairs_acc = {}
        for _, path in ipairs(files) do
            local content = ProjectScan.read_file(path)
            if content then
                local lower = path:lower()
                local parsed
                if lower:match("%.sln$") or lower:match("%.slnx$") then
                    parsed = ProjectScan.parse_sln(content)
                elseif lower:match("%.vcxproj$") then
                    parsed = ProjectScan.parse_vcxproj(content)
                end
                if parsed then
                    for _, t in ipairs(parsed) do
                        pairs_acc[#pairs_acc + 1] = t
                    end
                end
            end
        end
        local result = ProjectScan.dedup_sort(pairs_acc)
        if #result.configurations == 0 and #result.platforms == 0 then
            result = ProjectScan.fallback_defaults()
        end
        self.project_targets = result
        Log:debug(
            "warm project_targets: %d cfg, %d plat",
            #result.configurations,
            #result.platforms
        )
    end)
end

--- Resolve the MSVC developer environment for the active profile. Reads
--- parameters (arch / install_path / vcvars_ver / vs_*) from the merged
--- profile view (engine defaults ⨉ root profile ⨉ named profile) plus
--- any active `:Msvc update` overrides. `opts` overrides any field from
--- the resolved entry.
--- On success returns the env table and stores `install_path` on state.
---@param opts table|nil
---@return table|nil env
function Msvc:resolve(opts)
    opts = opts or {}
    local profile_name = opts.profile or self.state:profile_name()
    local entry = self:get_profile(profile_name)
    opts.arch = opts.arch or self.state.arch or entry.arch
    opts.install_path = opts.install_path or self.state.install_path
    if opts.vcvars_ver == nil then
        opts.vcvars_ver = entry.vcvars_ver
    end
    if opts.vswhere_path == nil then
        opts.vswhere_path = entry.vswhere_path
    end
    if opts.vs_version == nil then
        opts.vs_version = entry.vs_version
    end
    if opts.vs_prerelease == nil then
        opts.vs_prerelease = entry.vs_prerelease
    end
    if opts.vs_products == nil then
        opts.vs_products = entry.vs_products
    end
    if opts.vs_requires == nil then
        opts.vs_requires = entry.vs_requires
    end
    local env, err = DevEnv.resolve(opts)
    if not env then
        Log:error("env resolve failed: %s", tostring(err))
        return nil
    end
    if opts.install_path and opts.install_path ~= self.state.install_path then
        -- External / overridden path — friendlies become stale; clear
        -- them so `:Msvc status` falls back to the path-only line.
        self.state:set("install_path", opts.install_path)
        self.state:set("install_display_name", nil)
        self.state:set("install_version", nil)
        self.state:set("install_product_line_version", nil)
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
    local profile_view = self:get_profile(self.state:profile_name())
    local inst = VsWhere.find_latest({
        vswhere_path = profile_view.vswhere_path,
        vs_version = profile_view.vs_version,
        vs_prerelease = profile_view.vs_prerelease,
        vs_products = profile_view.vs_products,
        vs_requires = profile_view.vs_requires,
    })
    if not inst or not inst.installationPath then
        Log:error("no Visual Studio installation found")
        return nil
    end
    self:_set_install_from_record(inst)
    return self.state.install_path
end

--- Synchronous, override-aware re-resolve of `state.install_path`.
--- Used by `:Msvc update <vs_*>` so the immediately following
--- `:Msvc status` reflects the new selection without waiting on the
--- async warm. Skips the `-include packages` flag (only needed for
--- `vs_requires` completion, which the async warm refreshes).
---
--- Side effects:
---   * Clears `state.install_path` first.
---   * On match: populates `state.install_path` with the resolved root.
---   * On no match: leaves `state.install_path` nil and emits a warning
---     naming the offending vs_version value.
---
---@return string|nil install_path
function Msvc:_resolve_install_path_sync()
    self:_clear_install()
    local name = self.state:profile_name()
    local profile_view = self:get_profile(name)
    local inst = VsWhere.find_latest({
        vswhere_path = profile_view.vswhere_path,
        vs_version = profile_view.vs_version,
        vs_prerelease = profile_view.vs_prerelease,
        vs_products = profile_view.vs_products,
        vs_requires = profile_view.vs_requires,
    })
    if not inst or not inst.installationPath then
        Log:warn(
            "no Visual Studio installation matches vs_version=%s",
            tostring(profile_view.vs_version or "<unset>")
        )
        return nil
    end
    self:_set_install_from_record(inst)
    Log:debug("re-resolved install_path: %s", self.state.install_path)
    return self.state.install_path
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

--- Log a snapshot of the active solution / project / profile / install,
--- plus the `compile_commands` settings the post-build extractor will
--- consume. The profile section is expanded with its full field set
--- (sorted, one key per line) for verbose introspection.
function Msvc:status()
    local s = self.state:get_snapshot()
    Log:info("solution = %s", tostring(s.solution or "<none>"))
    Log:info("project  = %s", tostring(s.project or "<none>"))

    if not s.install_path or s.install_path == "" then
        Log:info("install  = <none>")
    elseif s.install_display_name and s.install_display_name ~= "" then
        local v = s.install_version
        if v and v ~= "" then
            Log:info("install  = %s (%s)", s.install_display_name, v)
        else
            Log:info("install  = %s", s.install_display_name)
        end
        Log:info("path     = %s", s.install_path)
    elseif
        s.install_product_line_version
        and s.install_product_line_version ~= ""
    then
        local v = (s.install_version and s.install_version ~= "")
                and s.install_version
            or "unknown"
        Log:info(
            "install  = Visual Studio %s (%s)",
            s.install_product_line_version,
            v
        )
        Log:info("path     = %s", s.install_path)
    else
        -- Legacy / externally-written install_path (no friendlies).
        Log:info("install  = %s", s.install_path)
    end

    local cc = self.config
        and self.config.settings
        and self.config.settings.compile_commands
    if type(cc) == "table" then
        local cc_lines = Config.format_entry_lines("compile_commands", cc)
        for _, line in ipairs(cc_lines) do
            Log:info("%s", line)
        end
    end
    local profile_name = self.state:profile_name()
    if profile_name then
        self:log_profile(profile_name)
    else
        Log:info("profile  = <none>")
    end
end

local instance = Msvc:new()
return instance
