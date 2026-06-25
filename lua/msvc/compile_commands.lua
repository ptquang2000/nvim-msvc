-- msvc.compile_commands — drive `msbuild-extractor-sample` to produce a
-- compile_commands.json after a successful :Msvc build or solution selection.
--
-- Flow: collect the main solution + all .sln files found (recursively) under
-- cc.builddir. Spawn up to `opts.jobs` extractor processes in parallel, each
-- writing to a per-solution temp file. Once all finish, merge the temp files
-- into the final compile_commands.json via Lua JSON decode/encode and clean up.

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

local function resolve_outpath(solution, project)
    local anchor = resolve_anchor(solution, project)
    if not anchor or anchor == "" then
        return nil
    end
    return Util.join_path(anchor, "compile_commands.json")
end

--- Scan cc.builddir (relative to solution) recursively for .sln files.
local function collect_builddir_slns(builddir, solution)
    if type(builddir) ~= "string" or builddir == "" then
        return {}
    end
    local anchor = resolve_anchor(solution, nil)
    local resolved = Util.resolve_path(builddir, anchor) or builddir
    local norm = Util.normalize_path(resolved) or resolved
    if not Util.is_dir(norm) then
        return {}
    end
    return Discover.find_slns(norm)
end

--- Scan {install_path}\VC\Tools\MSVC\* for the highest version subdirectory.
--- Returns the full path to that directory, or nil if none is found.
local function find_vc_tools_install_dir(install_path)
    if not install_path or install_path == "" then
        return nil
    end
    local msvc_root = Util.join_path(install_path, "VC", "Tools", "MSVC")
    if not Util.is_dir(msvc_root) then
        return nil
    end
    local scanner = vim.uv.fs_scandir(msvc_root)
    if not scanner then
        return nil
    end
    local best_name = nil
    local best_parts = nil
    while true do
        local name, ftype = vim.uv.fs_scandir_next(scanner)
        if not name then
            break
        end
        if ftype == "directory" and not name:match("[^%d%.]") then
            local parts = {}
            for n in name:gmatch("%d+") do
                parts[#parts + 1] = tonumber(n)
            end
            if #parts >= 2 then
                if not best_name then
                    best_name = name
                    best_parts = parts
                else
                    for i = 1, math.max(#parts, #best_parts) do
                        local a = parts[i] or 0
                        local b = best_parts[i] or 0
                        if a > b then
                            best_name = name
                            best_parts = parts
                            break
                        elseif a < b then
                            break
                        end
                    end
                end
            end
        end
    end
    if not best_name then
        return nil
    end
    return Util.join_path(msvc_root, best_name)
end

local function build_argv(opts)
    local argv = { opts.extractor }
    if opts.solution and opts.solution ~= "" then
        argv[#argv + 1] = "--solution"
        argv[#argv + 1] = opts.solution
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
    if opts.vc_tools_install_dir and opts.vc_tools_install_dir ~= "" then
        argv[#argv + 1] = "--vc-tools-install-dir"
        argv[#argv + 1] = opts.vc_tools_install_dir
    end
    argv[#argv + 1] = "--merge-defaults"
    argv[#argv + 1] = "-o"
    argv[#argv + 1] = opts.outpath
    if opts.deduplicate ~= false then
        argv[#argv + 1] = "--deduplicate"
    end
    for _, a in ipairs(opts.extra_args or {}) do
        argv[#argv + 1] = a
    end
    return argv
end

--- Resolve the WDK `km\` include directory for `winsdk_version`.
--- Resolution order: registry KitsRoot10 → two standard install roots.
--- Returns the first path where `Util.is_dir` is true, or nil.
local function find_wdk_km_path(winsdk_version)
    if not winsdk_version or winsdk_version == "" then
        return nil
    end
    local roots = {}
    local reg_out = vim.fn.system({
        "reg", "query",
        "HKLM\\SOFTWARE\\Microsoft\\Windows Kits\\Installed Roots",
        "/v", "KitsRoot10",
    })
    if type(reg_out) == "string" then
        local val = reg_out:match("KitsRoot10%s+REG_SZ%s+(.-)%s*\n")
        if val and val ~= "" then
            roots[#roots + 1] = val:gsub("\\+$", "")
        end
    end
    roots[#roots + 1] = "C:\\Program Files (x86)\\Windows Kits\\10"
    roots[#roots + 1] = "C:\\Program Files\\Windows Kits\\10"
    for _, root in ipairs(roots) do
        local km = Util.join_path(root, "Include", winsdk_version, "km")
        if Util.is_dir(km) then
            return km
        end
    end
    return nil
end

local WDK_ARCH_DEFINES = {
    x64   = { "-D_WIN64", "-D_AMD64_", "-DAMD64" },
    ARM64 = { "-D_WIN64", "-D_ARM64_", "-DARM64" },
    ARM   = { "-D_ARM_" },
    Win32 = { "-D_X86_" },
}

local function wdk_arch_defines(platform)
    if not platform or platform == "" then
        return {}
    end
    return WDK_ARCH_DEFINES[platform] or {}
end

local function wdk_win32_winnt(winsdk)
    if not winsdk or winsdk == "" then
        return nil
    end
    local major = tonumber(winsdk:match("^(%d+)%."))
    local minor = tonumber(winsdk:match("^%d+%.(%d+)")) or 0
    if not major then
        return nil
    end
    if major == 10 then
        return "0x0A00"
    elseif major == 6 then
        if minor == 3 then return "0x0603"
        elseif minor == 2 then return "0x0602"
        elseif minor == 1 then return "0x0601"
        end
    end
    return nil
end

local CLANGD_REMOVE = {
    "/Zc:*",
    "/MP",
    "/analyze",
    "/analyze:*",
    "/sdl",
    "/GS",
    "/RTC1",
    "/GL",
    "/Gw",
    "/Gy",
    "/Gm-",
    "/ZH:SHA_256",
    "/external:*",
    "/Wall",
}

--- Append a flag to `add_items`, deduplicating `-D` defines by macro name
--- (the identifier before `=`). On a name collision the later value wins,
--- replacing the earlier entry in place. Non-define flags (`-I…`) are appended
--- unconditionally. `name_index` maps a macro name to its slot in `add_items`.
--- See ADR 011: the union must stay name-keyed, never full-token.
local function add_clangd_flag(add_items, name_index, flag)
    local name = flag:match("^%-D([%w_]+)")
    if name then
        local slot = name_index[name]
        if slot then
            add_items[slot] = flag
        else
            add_items[#add_items + 1] = flag
            name_index[name] = #add_items
        end
    else
        add_items[#add_items + 1] = flag
    end
end

--- Write a `.clangd` config file to `opts.outdir`.
---
--- `CompileFlags.Add` is a build-order union of every project's preprocessor
--- defines across all solutions in `opts.solutions` (subs first, main last, in
--- `.sln` declaration order), with the pinned `opts.project` layered last so it
--- always wins (ADR 011). Defines are deduplicated by macro name — one `-D` per
--- macro, later-in-build-order value wins. WDK toolchain flags (km include path,
--- arch/OS defines) are still sourced from the pinned project. `Add` is omitted
--- only when nothing at all is contributed.
function M.generate_clangd(opts)
    local outdir = opts.outdir
    if not outdir or outdir == "" then
        return false, "no outdir"
    end
    local lines = {
        "# Generated by nvim-msvc. Do not edit.",
        "CompileFlags:",
        "  CompilationDatabase: .",
        "  Remove:",
    }
    for _, flag in ipairs(CLANGD_REMOVE) do
        lines[#lines + 1] = "    - " .. flag
    end
    if opts.configuration and opts.platform then
        local add_items = {}
        local name_index = {}

        -- WDK toolchain flags come from the pinned project only (toolchain, not
        -- a define union): km include path + arch/OS defines for kernel mode.
        if opts.project and opts.project ~= "" then
            local toolchain = Discover.discover_vcxproj_toolchain(opts.project)
            if toolchain.vcvars_ver and toolchain.vcvars_ver:lower():find("kernelmode", 1, true) then
                local km = find_wdk_km_path(toolchain.winsdk)
                if km then
                    add_clangd_flag(add_items, name_index, "-I" .. km)
                end
                for _, d in ipairs(wdk_arch_defines(opts.platform)) do
                    add_clangd_flag(add_items, name_index, d)
                end
                local winnt = wdk_win32_winnt(toolchain.winsdk)
                if winnt then
                    add_clangd_flag(add_items, name_index, "-D_WIN32_WINNT=" .. winnt)
                    add_clangd_flag(add_items, name_index, "-DWINVER=" .. winnt)
                end
            end
        end

        -- Build-order union of defines across every project in every solution.
        -- opts.solutions is already ordered subs-first, main-last; within each
        -- solution projects keep .sln declaration order (never sort it — that
        -- would silently change override semantics, see ADR 011).
        for _, sln in ipairs(opts.solutions or {}) do
            for _, proj in ipairs(Discover.parse_solution_projects(sln)) do
                local defs = Discover.parse_vcxproj_defines(
                    proj.path, opts.configuration, opts.platform
                )
                for _, d in ipairs(defs) do
                    add_clangd_flag(add_items, name_index, d)
                end
            end
        end

        -- Pinned project's defines applied last of all — always wins.
        if opts.project and opts.project ~= "" then
            local defines =
                Discover.parse_vcxproj_defines(opts.project, opts.configuration, opts.platform)
            for _, d in ipairs(defines) do
                add_clangd_flag(add_items, name_index, d)
            end
        end

        if #add_items > 0 then
            lines[#lines + 1] = "  Add:"
            for _, item in ipairs(add_items) do
                lines[#lines + 1] = "    - " .. item
            end
        end
    end
    local clangd_path = Util.join_path(outdir, ".clangd")
    local f = io.open(clangd_path, "w")
    if not f then
        return false, "cannot open " .. clangd_path .. " for writing"
    end
    f:write(table.concat(lines, "\n") .. "\n")
    f:close()
    cc_info("wrote %s", clangd_path)
    return true
end

--- Read all temp files, merge their compile_commands arrays into outpath.
--- Deduplicates by `file` field when deduplicate is true, keeping the **last**
--- occurrence (ADR 011). Callers pass temp_paths in `[subs…, main]` order, so
--- the main solution wins ties and among sub-solutions the later-scanned wins.
--- Cleans up temp files regardless of outcome.
local function merge_temp_files(temp_paths, outpath, deduplicate)
    local entries = {}
    local index_of = {}  -- file key (lower) → slot in `entries`
    for _, tmp in ipairs(temp_paths) do
        local content = Util.read_file(tmp)
        if content and content ~= "" then
            local ok, decoded = pcall(vim.json.decode, content)
            if ok and type(decoded) == "table" then
                for _, entry in ipairs(decoded) do
                    if type(entry) == "table" and type(entry.file) == "string" then
                        local key = entry.file:lower()
                        local slot = deduplicate and index_of[key]
                        if slot then
                            entries[slot] = entry  -- keep-last: overwrite in place
                        else
                            entries[#entries + 1] = entry
                            if deduplicate then
                                index_of[key] = #entries
                            end
                        end
                    end
                end
            end
        end
        if vim.uv and vim.uv.fs_unlink then
            pcall(vim.uv.fs_unlink, tmp)
        end
    end
    local f = io.open(outpath, "w")
    if not f then
        return false, "cannot open " .. outpath .. " for writing"
    end
    f:write(vim.json.encode(entries))
    f:close()
    return true
end

--- Generate compile_commands.json. Spawns up to opts.jobs extractor processes
--- in parallel (default: all solutions at once). Each writes to a temp file;
--- on completion the temp files are merged into the final output.
function M.generate(opts)
    opts = opts or {}
    local cc = opts.cc or {}
    if not M.is_enabled(cc) then
        return false
    end
    local solution = opts.solution
    if not solution or solution == "" then
        cc_warn("no solution to extract from")
        return false
    end

    local outpath = resolve_outpath(solution, opts.project)
    if not outpath then
        cc_error("could not resolve output path for solution %q", tostring(solution))
        return false
    end

    local sub_slns = collect_builddir_slns(cc.builddir, solution)
    local all_slns = { solution }
    local seen_slns = { [(Util.normalize_path(solution) or solution):lower()] = true }
    for _, s in ipairs(sub_slns) do
        local norm = Util.normalize_path(s) or s
        local key = norm:lower()
        if not seen_slns[key] then
            seen_slns[key] = true
            all_slns[#all_slns + 1] = norm
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

    local vc_tools_install_dir = opts.vc_tools_install_dir
        or (opts.vs_path and opts.vs_path ~= "" and find_vc_tools_install_dir(opts.vs_path))

    local n = #all_slns
    local pool_size = (opts.jobs and opts.jobs > 0) and opts.jobs or n
    cc_info(
        "generating %s (%d solution(s), pool=%d)",
        outpath,
        n,
        math.min(pool_size, n)
    )

    local outdir = Util.dirname(outpath)
    local temp_paths = {}
    for i = 1, n do
        temp_paths[i] =
            Util.join_path(outdir, "compile_commands." .. i .. ".tmp")
    end

    local on_done = opts.on_done
    local completed = 0
    local all_ok = true
    local active = 0
    local next_idx = 1

    -- Build-order solution list (ADR 011): sub-solutions first in scan order,
    -- main solution last. all_slns[1] is the main solution; [2..] are subs.
    local build_order_slns = {}
    for i = 2, n do
        build_order_slns[#build_order_slns + 1] = all_slns[i]
    end
    build_order_slns[#build_order_slns + 1] = all_slns[1]

    -- Temp files in the same [subs…, main] order so keep-last dedup lets the
    -- main solution win ties and the later-scanned sub-solution win among subs.
    local merge_order_temps = {}
    for i = 2, n do
        merge_order_temps[#merge_order_temps + 1] = temp_paths[i]
    end
    merge_order_temps[#merge_order_temps + 1] = temp_paths[1]

    local function finish(success)
        if success then
            local ok, err =
                merge_temp_files(merge_order_temps, outpath, cc.deduplicate ~= false)
            if ok then
                cc_info("wrote %s", outpath)
                M.generate_clangd({
                    outdir = Util.dirname(outpath),
                    project = opts.project,
                    configuration = opts.configuration,
                    platform = opts.platform,
                    solutions = build_order_slns,
                })
            else
                cc_error("merge failed: %s", tostring(err))
                success = false
            end
        else
            for _, tmp in ipairs(temp_paths) do
                if vim.uv and vim.uv.fs_unlink then
                    pcall(vim.uv.fs_unlink, tmp)
                end
            end
        end
        if type(on_done) == "function" then
            pcall(on_done, success, outpath, nil)
        end
    end

    local try_start  -- forward declaration for recursive reference
    try_start = function()
        while active < pool_size and next_idx <= n do
            local i = next_idx
            next_idx = next_idx + 1
            active = active + 1
            local sln = all_slns[i]
            local tmp = temp_paths[i]
            local argv = build_argv({
                extractor = exe,
                solution = sln,
                configuration = opts.configuration,
                platform = opts.platform,
                outpath = tmp,
                deduplicate = cc.deduplicate,
                extra_args = cc.extra_args,
                vs_path = opts.vs_path,
                vc_tools_install_dir = vc_tools_install_dir,
            })
            cc_debug("argv[%d/%d] = %s", i, n, vim.inspect(argv))
            cc_info("[%d/%d] starting: %s", i, n, Util.basename(sln))
            local ok_spawn, err = pcall(function()
                vim.system(argv, { text = true }, function(res)
                    vim.schedule(function()
                        active = active - 1
                        completed = completed + 1
                        local ok = res and res.code == 0
                        if ok then
                            cc_info("[%d/%d] done: %s", i, n, Util.basename(sln))
                        else
                            all_ok = false
                            cc_error(
                                "[%d/%d] extractor exit %d for %s%s",
                                i,
                                n,
                                res and res.code or -1,
                                Util.basename(sln),
                                (res and res.stderr and res.stderr ~= "")
                                        and (": " .. res.stderr:gsub(
                                            "%s+$",
                                            ""
                                        ))
                                    or ""
                            )
                        end
                        if completed == n then
                            finish(all_ok)
                        else
                            try_start()
                        end
                    end)
                end)
            end)
            if not ok_spawn then
                cc_error(
                    "spawn failed for %s: %s",
                    Util.basename(sln),
                    tostring(err)
                )
                -- defer counter update so we're outside the while loop
                vim.schedule(function()
                    active = active - 1
                    completed = completed + 1
                    all_ok = false
                    if completed == n then
                        finish(false)
                    else
                        try_start()
                    end
                end)
            end
        end
    end

    if vim.uv and vim.uv.fs_unlink then
        pcall(vim.uv.fs_unlink, outpath)
    end

    try_start()
    return true
end

M._internal = {
    build_argv = build_argv,
    find_vc_tools_install_dir = find_vc_tools_install_dir,
    find_wdk_km_path = find_wdk_km_path,
    wdk_arch_defines = wdk_arch_defines,
    wdk_win32_winnt = wdk_win32_winnt,
    resolve_outpath = resolve_outpath,
    resolve_anchor = resolve_anchor,
    collect_builddir_slns = collect_builddir_slns,
    merge_temp_files = merge_temp_files,
    generate_clangd = M.generate_clangd,
}

return M
