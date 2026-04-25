-- msvc.compile_commands: integration with the msbuild-extractor-sample tool
-- (https://github.com/microsoft/msbuild-extractor-sample) used to derive a
-- clang-style compile_commands.json from a Visual C++ solution / project
-- tree without invoking the real compiler.
--
-- Modeled on nvim-treesitter's `tree-sitter` CLI integration: the
-- `msbuild-extractor-sample` executable is *implicit* — it must be on PATH
-- and is not configurable. The feature is enabled by default and
-- automatically runs after a successful `:Msvc build`; if the binary is
-- missing the run is skipped (with a single warning) so the build itself
-- is unaffected. See `:checkhealth msvc` for a quick way to confirm the
-- tool is discoverable.

local Util = require("msvc.util")
local Log = require("msvc.log")
local Discover = require("msvc.discover")
local DevEnv = require("msvc.devenv")

local M = {}

--- Name of the extractor executable. Intentionally hardcoded — to match
--- nvim-treesitter's `tree-sitter-cli` model the binary must live on PATH
--- and is not exposed as a config option.
M.EXTRACTOR_BIN = "msbuild-extractor-sample"

--- Resolve `msbuild-extractor-sample` on PATH. Returns the absolute path
--- when found, nil otherwise. Result is cached on the module to avoid
--- re-running `exepath` for every build.
---@return string|nil
function M.find_extractor()
    if M._extractor_path ~= nil then
        return M._extractor_path or nil
    end
    local p = vim.fn.exepath(M.EXTRACTOR_BIN)
    if type(p) == "string" and p ~= "" then
        M._extractor_path = p
        return p
    end
    M._extractor_path = false
    return nil
end

--- Reset the cached extractor lookup. Tests / `:checkhealth` may call
--- this so subsequent runs re-probe PATH.
function M.reset_cache()
    M._extractor_path = nil
end

--- True when the compile_commands integration should run after a
--- successful build. Default ON; users opt out with
--- `settings.compile_commands.enabled = false`. Discovery of the
--- extractor binary itself happens lazily in `generate` so that a
--- missing tool only logs once instead of disabling the feature
--- silently.
---@param cc table|nil
---@return boolean
function M.is_enabled(cc)
    if type(cc) ~= "table" then
        return true
    end
    if cc.enabled == false then
        return false
    end
    return true
end

--- Resolve the directory to anchor a relative `builddir` / `outdir` against.
--- Priority: solution dir → project dir → cwd. Always returns a non-empty
--- normalized absolute path (cwd is the floor). The anchor is ONLY used
--- when the user-supplied path is relative; absolute paths are passed
--- through unchanged.
---@param solution string|nil
---@param project string|nil
---@return string
local function resolve_anchor(solution, project)
    if solution and solution ~= "" then
        local d = Util.dirname(solution)
        if d and d ~= "" then
            return Util.normalize_path(d) or d
        end
    end
    if project and project ~= "" then
        local d = Util.dirname(project)
        if d and d ~= "" then
            return Util.normalize_path(d) or d
        end
    end
    local cwd = (vim.uv and vim.uv.cwd and vim.uv.cwd()) or vim.fn.getcwd()
    return Util.normalize_path(cwd) or cwd
end

--- Resolve the output path for compile_commands.json. When `outdir` is
--- relative, it is anchored to the solution / project / cwd (in that
--- order). When unset, falls back to the same anchor directly. Creates
--- the directory tree if missing.
---@param outdir string|nil
---@param solution string|nil
---@param project string|nil
---@return string|nil path
local function resolve_outpath(outdir, solution, project)
    local anchor = resolve_anchor(solution, project)
    local dir
    if outdir and outdir ~= "" then
        dir = Util.resolve_path(outdir, anchor)
    else
        dir = anchor
    end
    dir = Util.normalize_path(dir) or dir
    if dir == nil or dir == "" then
        return nil
    end
    if not Util.is_dir(dir) then
        local ok = pcall(vim.fn.mkdir, dir, "p")
        if not ok or not Util.is_dir(dir) then
            return nil
        end
    end
    return Util.join_path(dir, "compile_commands.json")
end

--- Recursively collect `*.vcxproj` paths under `builddir` for merging into
--- the main compile_commands.json. Empty/missing dirs return an empty list.
--- Relative `builddir` is anchored to the solution / project / cwd.
---@param builddir string|nil
---@param solution string|nil
---@param project string|nil
---@return string[]
local function collect_builddir_vcxprojs(builddir, solution, project)
    if type(builddir) ~= "string" or builddir == "" then
        return {}
    end
    local anchor = resolve_anchor(solution, project)
    local resolved = Util.resolve_path(builddir, anchor) or builddir
    local norm = Util.normalize_path(resolved) or resolved
    if builddir ~= norm then
        Log:debug(
            "compile_commands: builddir %q → %s",
            tostring(builddir),
            tostring(norm)
        )
    end
    if not Util.is_dir(norm) then
        Log:warn(
            "compile_commands: builddir does not exist: %s",
            tostring(norm)
        )
        return {}
    end
    return Discover.find_vcxprojs(norm)
end

--- Build the argv to invoke msbuild-extractor-sample. Mirrors the CLI in
--- the upstream README: `--solution`/`--project` are repeatable, `-c` and
--- `-a` carry the active configuration / platform, `-o` is the output
--- file, and `--merge --deduplicate` produces one entry per source file
--- when both the solution and individual vcxprojs are extracted.
---@param opts table
---@return string[]
local function build_argv(opts)
    local argv = {}
    local extractor = opts.extractor
    if type(extractor) == "string" then
        argv[#argv + 1] = extractor
    elseif type(extractor) == "table" then
        for _, a in ipairs(extractor) do
            argv[#argv + 1] = a
        end
    end
    if opts.solution and opts.solution ~= "" then
        argv[#argv + 1] = "--solution"
        argv[#argv + 1] = opts.solution
    end
    for _, p in ipairs(opts.projects or {}) do
        argv[#argv + 1] = "--project"
        argv[#argv + 1] = p
    end
    if opts.configuration and opts.configuration ~= "" then
        argv[#argv + 1] = "-c"
        argv[#argv + 1] = opts.configuration
    end
    if opts.platform and opts.platform ~= "" then
        argv[#argv + 1] = "-a"
        argv[#argv + 1] = opts.platform
    end
    -- The dev-prompt env vars (VSINSTALLDIR, INCLUDE, PATH, ...) are
    -- always forwarded to the extractor via vim.system. `--use-dev-env`
    -- tells the extractor to consume them in lieu of MSBuildLocator's
    -- .NET SDK probe — which is the failure mode that produced the
    -- upstream "No .NET SDKs were found" / CLR exception 0xE0434352.
    argv[#argv + 1] = "--use-dev-env"
    -- Force out-of-process mode against the MSBuild we already located
    -- under VSINSTALLDIR. This avoids loading MSBuild assemblies into the
    -- extractor process for the actual extraction step.
    if opts.msbuild_path and opts.msbuild_path ~= "" then
        argv[#argv + 1] = "--msbuild-path"
        argv[#argv + 1] = opts.msbuild_path
    end
    argv[#argv + 1] = "-o"
    argv[#argv + 1] = opts.outpath
    -- Merge + deduplicate so the union of solution + builddir vcxprojs
    -- produces a single, IntelliSense-friendly entry per source file.
    local merge = true
    if opts.merge == false then
        merge = false
    end
    if merge then
        argv[#argv + 1] = "--merge"
    end
    if opts.deduplicate ~= false then
        argv[#argv + 1] = "--deduplicate"
    end
    for _, a in ipairs(opts.extra_args or {}) do
        argv[#argv + 1] = a
    end
    return argv
end

--- Generate compile_commands.json by invoking msbuild-extractor-sample.
--- All inputs are validated; the spawn itself is asynchronous via
--- `vim.system`. `on_done(ok, outpath, code)` is invoked once the tool
--- exits (best-effort, scheduled on the main loop).
---@param opts table
---     @field solution string|nil
---     @field project string|nil
---     @field configuration string
---     @field platform string
---     @field cc table -- settings.compile_commands
---     @field env table|nil -- developer-prompt env (PATH/INCLUDE/LIB/...) to
---                          -- inherit so MSBuild / .NET SDK lookups succeed
---                          -- even when nvim was launched outside a VS
---                          -- Developer PowerShell.
---     @field on_done fun(ok: boolean, outpath: string|nil, code: integer|nil)|nil
---@return boolean spawned
function M.generate(opts)
    opts = opts or {}
    local cc = opts.cc or {}
    if not M.is_enabled(cc) then
        return false
    end
    local solution = opts.solution
    local project = opts.project
    if (not solution or solution == "") and (not project or project == "") then
        Log:warn("compile_commands: no solution / project to extract from")
        return false
    end
    local outpath = resolve_outpath(cc.outdir, solution, project)
    if not outpath then
        Log:error(
            "compile_commands: could not resolve output directory %q",
            tostring(cc.outdir)
        )
        return false
    end
    local projects = collect_builddir_vcxprojs(cc.builddir, solution, project)
    -- When we don't have a solution we still need at least one --project
    -- input; fall back to the active project so the extractor has work
    -- to do.
    if (not solution or solution == "") and project and project ~= "" then
        local seen = {}
        for _, p in ipairs(projects) do
            seen[(Util.normalize_path(p) or p):lower()] = true
        end
        local norm = Util.normalize_path(project) or project
        if not seen[norm:lower()] then
            table.insert(projects, 1, norm)
        end
    end
    local exe = M.find_extractor()
    if not exe then
        if not M._missing_warned then
            M._missing_warned = true
            Log:warn(
                "compile_commands: %s not found on PATH — install it from https://github.com/microsoft/msbuild-extractor-sample to enable compile_commands.json generation",
                M.EXTRACTOR_BIN
            )
        end
        return false
    end
    -- Hand off to the extractor's own dev-prompt reader (--use-dev-env)
    -- and locate MSBuild.exe so it can run out-of-process. Both rely on
    -- the env (`opts.env`) the plugin forwards via vim.system; without
    -- that env the extractor would fall back to MSBuildLocator's .NET
    -- SDK discovery and crash when no SDK is installed. The caller is
    -- responsible for resolving the developer-prompt env before calling
    -- generate so we always emit `--use-dev-env` and a `--msbuild-path`
    -- when one can be located under VSINSTALLDIR.
    local env = opts.env
    local msbuild_path
    if type(env) == "table" then
        local ok_mb, found = pcall(DevEnv.find_msbuild, env)
        if ok_mb and type(found) == "string" and found ~= "" then
            msbuild_path = found
        end
    end
    local argv = build_argv({
        extractor = exe,
        solution = solution,
        projects = projects,
        configuration = opts.configuration,
        platform = opts.platform,
        outpath = outpath,
        merge = cc.merge,
        deduplicate = cc.deduplicate,
        extra_args = cc.extra_args,
        msbuild_path = msbuild_path,
    })

    Log:info(
        "compile_commands: generating %s (%d extra projects from builddir)",
        outpath,
        #projects
    )
    Log:debug("compile_commands: argv = %s", vim.inspect(argv))

    local on_done = opts.on_done
    -- Inherit the resolved MSVC developer environment so the extractor's
    -- MSBuildLocator can find MSBuild, and so hostfxr can resolve a .NET
    -- SDK / runtime via the dev-prompt PATH. Without this, launching
    -- Neovim from a vanilla shell yields the upstream error:
    --   "No .NET SDKs were found" / unhandled CLR exception 0xE0434352.
    local sys_opts = { text = true }
    if type(opts.env) == "table" and next(opts.env) ~= nil then
        sys_opts.env = opts.env
    end
    local ok_spawn, err = pcall(function()
        vim.system(argv, sys_opts, function(res)
            vim.schedule(function()
                local ok = res and res.code == 0
                if ok then
                    Log:info("compile_commands: wrote %s", outpath)
                else
                    local code = res and res.code or -1
                    local stderr = (res and res.stderr) or ""
                    Log:error(
                        "compile_commands: extractor exited with code %d%s",
                        code,
                        (
                            stderr ~= ""
                                and (": " .. stderr:gsub("%s+$", ""))
                            or ""
                        )
                    )
                end
                if type(on_done) == "function" then
                    pcall(on_done, ok, outpath, res and res.code or nil)
                end
            end)
        end)
    end)
    if not ok_spawn then
        Log:error(
            "compile_commands: failed to spawn extractor: %s",
            tostring(err)
        )
        return false
    end
    return true
end

-- Test seam: expose internals so specs can assert argv composition without
-- spawning a real process.
M._internal = {
    build_argv = build_argv,
    resolve_outpath = resolve_outpath,
    collect_builddir_vcxprojs = collect_builddir_vcxprojs,
    resolve_anchor = resolve_anchor,
}

return M
