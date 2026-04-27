-- msvc.compile_commands — drive `msbuild-extractor-sample` to produce a
-- compile_commands.json after a successful :Msvc build.

local Util = require("msvc.util")
local Log = require("msvc.log")
local Discover = require("msvc.discover")

local M = {}

M.EXTRACTOR_BIN = "msbuild-extractor-sample"

local function cc_info(fmt, ...)
    Log:build_append("compile_commands: " .. fmt, ...)
end

local function cc_warn(fmt, ...)
    Log:build_append("compile_commands [WARN]: " .. fmt, ...)
end

local function cc_error(fmt, ...)
    Log:build_append("compile_commands [ERROR]: " .. fmt, ...)
end

local function cc_debug(fmt, ...)
    Log:debug("compile_commands: " .. fmt, ...)
end

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

function M.reset_cache()
    M._extractor_path = nil
    M._missing_warned = nil
end

function M.is_enabled(cc)
    if type(cc) ~= "table" then
        return true
    end
    return cc.enabled ~= false
end

local function resolve_anchor(solution, project)
    for _, p in ipairs({ solution, project }) do
        if p and p ~= "" then
            local d = Util.dirname(p)
            if d and d ~= "" then
                return Util.normalize_path(d) or d
            end
        end
    end
    local cwd = (vim.uv and vim.uv.cwd and vim.uv.cwd()) or vim.fn.getcwd()
    return Util.normalize_path(cwd) or cwd
end

local function resolve_outpath(outdir, solution, project)
    local anchor = resolve_anchor(solution, project)
    local dir = (outdir and outdir ~= "") and Util.resolve_path(outdir, anchor)
        or anchor
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

local function collect_builddir_vcxprojs(builddir, solution, project)
    if type(builddir) ~= "string" or builddir == "" then
        return {}
    end
    local anchor = resolve_anchor(solution, project)
    local resolved = Util.resolve_path(builddir, anchor) or builddir
    local norm = Util.normalize_path(resolved) or resolved
    if not Util.is_dir(norm) then
        -- cc_warn("builddir does not exist: %s", tostring(norm))
        return {}
    end
    return Discover.find_vcxprojs(norm)
end

local function build_argv(opts)
    local argv = { opts.extractor }
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
    if opts.vs_path and opts.vs_path ~= "" then
        argv[#argv + 1] = "--vs-path"
        argv[#argv + 1] = opts.vs_path
    end
    argv[#argv + 1] = "-o"
    argv[#argv + 1] = opts.outpath
    if opts.merge ~= false then
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

--- Generate compile_commands.json. Async; spawns the extractor under the
--- supplied dev-prompt env (required so MSBuildLocator finds MSBuild).
function M.generate(opts)
    opts = opts or {}
    local cc = opts.cc or {}
    if not M.is_enabled(cc) then
        return false
    end
    local solution, project = opts.solution, opts.project
    if (not solution or solution == "") and (not project or project == "") then
        cc_warn("no solution / project to extract from")
        return false
    end

    local outpath = resolve_outpath(cc.outdir, solution, project)
    if not outpath then
        cc_error("could not resolve output directory %q", tostring(cc.outdir))
        return false
    end

    local projects = collect_builddir_vcxprojs(cc.builddir, solution, project)
    local seen = {}
    for _, p in ipairs(projects) do
        seen[(Util.normalize_path(p) or p):lower()] = true
    end
    local function add_project(p)
        if type(p) ~= "string" or p == "" then
            return
        end
        if not p:lower():match("%.vcxproj$") then
            return
        end
        local norm = Util.normalize_path(p) or p
        local key = norm:lower()
        if seen[key] then
            return
        end
        seen[key] = true
        projects[#projects + 1] = norm
    end
    add_project(project)
    if type(opts.extra_projects) == "table" then
        for _, p in ipairs(opts.extra_projects) do
            add_project(p)
        end
    end

    local exe = M.find_extractor()
    if not exe then
        if not M._missing_warned then
            M._missing_warned = true
            cc_warn(
                "%s not found on PATH — install from https://github.com/microsoft/msbuild-extractor-sample",
                M.EXTRACTOR_BIN
            )
        end
        return false
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
        vs_path = opts.vs_path,
    })
    cc_info("generating %s (%d project(s))", outpath, #projects)
    cc_debug("argv = %s", vim.inspect(argv))

    if vim.uv and vim.uv.fs_unlink then
        pcall(vim.uv.fs_unlink, outpath)
    end

    local on_done = opts.on_done
    local sys_opts = { text = true }
    if type(opts.env) == "table" and next(opts.env) ~= nil then
        sys_opts.env = opts.env
    end
    local ok_spawn, err = pcall(function()
        vim.system(argv, sys_opts, function(res)
            vim.schedule(function()
                local ok = res and res.code == 0
                if ok then
                    cc_info("wrote %s", outpath)
                else
                    cc_error(
                        "extractor exit %d%s",
                        res and res.code or -1,
                        (res and res.stderr and res.stderr ~= "")
                                and (": " .. res.stderr:gsub("%s+$", ""))
                            or ""
                    )
                end
                if type(on_done) == "function" then
                    pcall(on_done, ok, outpath, res and res.code or nil)
                end
            end)
        end)
    end)
    if not ok_spawn then
        cc_error("spawn failed: %s", tostring(err))
        return false
    end
    return true
end

M._internal = {
    build_argv = build_argv,
    resolve_outpath = resolve_outpath,
    resolve_anchor = resolve_anchor,
    collect_builddir_vcxprojs = collect_builddir_vcxprojs,
}

return M
