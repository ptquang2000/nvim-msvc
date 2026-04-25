local Util = require("msvc.util")
local Log = require("msvc.log")

local uv = vim.uv or vim.loop

local M = {}

local DEFAULT_IGNORE_DIRS = {
    ".git",
    "node_modules",
    "obj",
    "bin",
    "x64",
    "Debug",
    "Release",
    ".vs",
}

--- True when `dir` is a filesystem root (drive root on Windows, "/" elsewhere).
--- @param dir string
--- @return boolean
local function is_root(dir)
    if dir == nil or dir == "" then
        return true
    end
    if Util.is_windows() then
        return dir:match("^%a:[\\/]?$") ~= nil or dir == "\\" or dir == "\\\\"
    end
    return dir == "/"
end

--- Parent directory, returning nil when already at the root.
--- @param dir string
--- @return string|nil
local function parent_of(dir)
    local p = Util.dirname(dir)
    if p == nil or p == "" or p == dir then
        return nil
    end
    return p
end

--- Build a lookup set from an array of strings.
--- @param list table|nil
--- @return table<string, boolean>
local function to_set(list)
    local set = {}
    for _, v in ipairs(list or {}) do
        set[v] = true
    end
    return set
end

--- Scan `dir` (one level) collecting names whose lowercased extension matches
--- `ext` (without dot). Returns absolute, normalized paths.
--- @param dir string
--- @param ext string
--- @return string[]
local function scan_dir_for_ext(dir, ext)
    local out = {}
    local h = uv.fs_scandir(dir)
    if not h then
        return out
    end
    local needle = "." .. ext:lower()
    while true do
        local name, t = uv.fs_scandir_next(h)
        if not name then
            break
        end
        if t ~= "directory" then
            local lname = name:lower()
            if lname:sub(-#needle) == needle then
                out[#out + 1] = Util.normalize_path(Util.join_path(dir, name))
            end
        end
    end
    table.sort(out)
    return out
end

--- Walk upward from `start_dir` (inclusive) toward the filesystem root.
--- For each level, calls `visit(dir)`; stops when `visit` returns a non-nil
--- value, on root, or after `max_depth` iterations.
--- @param start_dir string
--- @param max_depth integer
--- @param visit fun(dir:string):any
--- @return any
local function walk_upward(start_dir, max_depth, visit)
    local dir = Util.normalize_path(start_dir)
    local depth = 0
    while dir and depth < max_depth do
        local r = visit(dir)
        if r ~= nil then
            return r
        end
        if is_root(dir) then
            return nil
        end
        local parent = parent_of(dir)
        if parent == nil or parent == dir then
            return nil
        end
        dir = parent
        depth = depth + 1
    end
    return nil
end

--- Find the nearest `*.sln` walking upward from `start_dir`.
--- @param start_dir string|nil
--- @param opts table|nil
---     @field max_depth integer|nil   default 16
---     @field cache table|nil         caller-owned {[dir]=string|false}
--- @return string|nil
function M.find_solution(start_dir, opts)
    opts = opts or {}
    local max_depth = opts.max_depth or 16
    local cache = opts.cache
    local origin = Util.normalize_path(start_dir or vim.fn.getcwd())
    if origin == nil then
        return nil
    end
    if cache and cache[origin] ~= nil then
        local hit = cache[origin]
        if hit == false then
            return nil
        end
        return hit
    end

    local found = walk_upward(origin, max_depth, function(dir)
        if cache and cache[dir] ~= nil then
            local v = cache[dir]
            if v == false then
                return nil
            end
            return v
        end
        local hits = scan_dir_for_ext(dir, "sln")
        if #hits > 0 then
            if cache then
                cache[dir] = hits[1]
            end
            Log:debug("discover.find_solution: " .. hits[1])
            return hits[1]
        end
        if cache then
            cache[dir] = false
        end
        return nil
    end)

    if cache then
        cache[origin] = found or false
    end
    return found
end

--- Find every `*.sln` along the ancestry of `start_dir`, deduped (nearest
--- first). Useful when a workspace has multiple solutions.
--- @param start_dir string|nil
--- @param opts table|nil
---     @field max_depth integer|nil  default 16
--- @return string[]
function M.find_solutions(start_dir, opts)
    opts = opts or {}
    local max_depth = opts.max_depth or 16
    local origin = Util.normalize_path(start_dir or vim.fn.getcwd())
    local out, seen = {}, {}
    if origin == nil then
        return out
    end
    walk_upward(origin, max_depth, function(dir)
        for _, p in ipairs(scan_dir_for_ext(dir, "sln")) do
            local n = Util.normalize_path(p)
            if n and not seen[n] then
                seen[n] = true
                out[#out + 1] = n
            end
        end
        return nil
    end)
    return out
end

--- Canonical CMake VS-generator meta-target basenames (without `.vcxproj`).
--- Compared case-insensitively against the file basename. These are emitted
--- by CMake alongside real targets and have no compile commands worth
--- extracting; the implicit builddir scan filters them out.
M.CMAKE_META_TARGETS = {
    "ALL_BUILD",
    "ZERO_CHECK",
    "INSTALL",
    "PACKAGE",
    "RUN_TESTS",
    "RESTORE",
    "Continuous",
    "Experimental",
    "Nightly",
    "NightlyMemoryCheck",
}

--- Build a lowercase lookup set of meta-target basenames.
--- @return table<string, boolean>
local function meta_target_set()
    local set = {}
    for _, n in ipairs(M.CMAKE_META_TARGETS) do
        set[n:lower()] = true
    end
    return set
end

--- True when `name` is a CMake-generated meta-target `.vcxproj` filename.
--- Case-insensitive basename match against `M.CMAKE_META_TARGETS`.
--- @param name string  basename (with or without extension) or full path
--- @return boolean
local function is_cmake_meta_target(name)
    if type(name) ~= "string" or name == "" then
        return false
    end
    local base = vim.fn.fnamemodify(name, ":t:r"):lower()
    return meta_target_set()[base] == true
end

--- Recursively (BFS) find `*.vcxproj` files beneath `root_dir`. Skips
--- ignored directories and stops once `max_files` projects are collected.
--- By default, CMake VS-generator meta-targets (ALL_BUILD, ZERO_CHECK,
--- INSTALL, PACKAGE, RUN_TESTS, RESTORE, Continuous, Experimental, Nightly,
--- NightlyMemoryCheck) are filtered out so the extractor never sees them.
--- @param root_dir string
--- @param opts table|nil
---     @field max_files integer|nil          default 5000
---     @field ignore_dirs string[]|nil       default DEFAULT_IGNORE_DIRS
---     @field filter_meta_targets boolean|nil default true
--- @return string[]
function M.find_vcxprojs(root_dir, opts)
    opts = opts or {}
    local max_files = opts.max_files or 5000
    local ignore = to_set(opts.ignore_dirs or DEFAULT_IGNORE_DIRS)
    local filter_meta = opts.filter_meta_targets ~= false
    local out = {}
    local root = Util.normalize_path(root_dir)
    if root == nil or not Util.is_dir(root) then
        return out
    end
    local queue = { root }
    local head = 1
    while head <= #queue and #out < max_files do
        local dir = queue[head]
        head = head + 1
        local h = uv.fs_scandir(dir)
        if h then
            while true do
                local name, t = uv.fs_scandir_next(h)
                if not name then
                    break
                end
                local full = Util.normalize_path(Util.join_path(dir, name))
                if t == "directory" then
                    if not ignore[name] then
                        queue[#queue + 1] = full
                    end
                elseif t == "file" or t == "link" then
                    if
                        name:lower():sub(-8) == ".vcxproj"
                        and not (filter_meta and is_cmake_meta_target(name))
                    then
                        out[#out + 1] = full
                        if #out >= max_files then
                            break
                        end
                    end
                end
            end
        end
    end
    table.sort(out)
    Log:debug("discover.find_vcxprojs: " .. tostring(#out) .. " under " .. root)
    return out
end

--- Resolve a path argument: number = bufnr, string = path, nil = current buf.
--- @param buf_or_path integer|string|nil
--- @return string|nil
local function resolve_path(buf_or_path)
    if type(buf_or_path) == "string" and buf_or_path ~= "" then
        return Util.normalize_path(buf_or_path)
    end
    local bufnr = 0
    if type(buf_or_path) == "number" then
        bufnr = buf_or_path
    end
    local ok, name = pcall(vim.api.nvim_buf_get_name, bufnr)
    if not ok or name == nil or name == "" then
        return nil
    end
    return Util.normalize_path(name)
end

--- Find the nearest `*.vcxproj` walking upward from `from_dir`.
--- @param from_dir string
--- @param max_depth integer
--- @return string|nil
local function nearest_vcxproj(from_dir, max_depth)
    return walk_upward(from_dir, max_depth, function(dir)
        local hits = scan_dir_for_ext(dir, "vcxproj")
        if #hits > 0 then
            return hits[1]
        end
        return nil
    end)
end

--- Pick the best buildable artifact for `buf_or_path`. Prefers a `.sln`
--- found anywhere up the tree; falls back to the nearest `.vcxproj` in the
--- buffer's directory ancestry. Best-effort matching against ClCompile
--- entries is performed when multiple .vcxproj live next to each other.
--- @param buf_or_path integer|string|nil
--- @return string|nil path
--- @return string kind  "sln" | "vcxproj" | "none"
function M.find_buildable(buf_or_path)
    local path = resolve_path(buf_or_path)
    local start_dir
    if path and Util.is_file(path) then
        start_dir = Util.dirname(path)
    elseif path and Util.is_dir(path) then
        start_dir = path
    else
        start_dir = Util.normalize_path(vim.fn.getcwd())
    end
    if start_dir == nil or start_dir == "" then
        return nil, "none"
    end

    local sln = M.find_solution(start_dir)
    if sln then
        return sln, "sln"
    end

    local vcxproj = nearest_vcxproj(start_dir, 16)
    if vcxproj == nil then
        return nil, "none"
    end

    -- best-effort: when several .vcxproj sit at the same level, pick the
    -- one whose ClCompile list references the source file.
    if path and Util.is_file(path) then
        local dir = Util.dirname(vcxproj)
        local siblings = scan_dir_for_ext(dir, "vcxproj")
        if #siblings > 1 then
            local target = Util.basename(path):lower()
            for _, candidate in ipairs(siblings) do
                local data = Util.read_file(candidate)
                if data then
                    for inc in data:gmatch("<ClCompile%s+Include=\"([^\"]+)\"") do
                        if Util.basename(inc):lower() == target then
                            return Util.normalize_path(candidate), "vcxproj"
                        end
                    end
                end
            end
        end
    end

    return vcxproj, "vcxproj"
end

--- Parse `Project("{...}") = "Name", "rel\path.vcxproj", "{...}"` entries
--- from a Visual Studio solution file. Solution folders (project type GUID
--- 2150E333-...) and non-vcxproj entries are skipped. Returned entries are
--- absolute, normalized paths.
--- @param sln_path string
--- @return { name: string, path: string, guid: string }[]
function M.parse_solution_projects(sln_path)
    local out = {}
    if sln_path == nil or sln_path == "" or not Util.is_file(sln_path) then
        return out
    end
    local data, err = Util.read_file(sln_path)
    if not data then
        Log:debug(
            "discover.parse_solution_projects: read failed: " .. tostring(err)
        )
        return out
    end
    local sln_dir = Util.dirname(sln_path)
    local seen = {}
    local pat =
        "Project%(\"({[^}]+})\"%)%s*=%s*\"([^\"]+)\"%s*,%s*\"([^\"]+)\"%s*,%s*\"({[^}]+})\""
    for _type_guid, name, rel, proj_guid in data:gmatch(pat) do
        local lower_rel = rel:lower()
        if lower_rel:sub(-8) == ".vcxproj" then
            local abs = Util.normalize_path(Util.join_path(sln_dir, rel)) or rel
            if not seen[abs] then
                seen[abs] = true
                out[#out + 1] = { name = name, path = abs, guid = proj_guid }
            end
        end
    end
    table.sort(out, function(a, b)
        return a.name:lower() < b.name:lower()
    end)
    return out
end

--- Tolerant: returns {} when the file is missing or unreadable.
--- @param vcxproj_path string
--- @return string[]
function M.parse_vcxproj_configs(vcxproj_path)
    local out = {}
    if vcxproj_path == nil or vcxproj_path == "" then
        return out
    end
    if not Util.is_file(vcxproj_path) then
        return out
    end
    local data, err = Util.read_file(vcxproj_path)
    if not data then
        Log:debug(
            "discover.parse_vcxproj_configs: read failed: " .. tostring(err)
        )
        return out
    end
    local seen = {}
    for inc in data:gmatch("<ProjectConfiguration%s[^>]-Include=\"([^\"]+)\"") do
        if not seen[inc] then
            seen[inc] = true
            out[#out + 1] = inc
        end
    end
    return out
end

--- Returns true if `cwd` (or any ancestor up to depth 5) contains a
--- `CMakeLists.txt`, any `*.sln`, or any `*.vcxproj`. Used to gate the
--- scan-on-init so we don't walk arbitrary directories.
--- @param cwd string|nil
--- @return boolean
function M.should_scan(cwd)
    local origin = Util.normalize_path(cwd or vim.fn.getcwd())
    if origin == nil then
        return false
    end
    local hit = walk_upward(origin, 5, function(dir)
        if Util.is_file(Util.join_path(dir, "CMakeLists.txt")) then
            return true
        end
        if #scan_dir_for_ext(dir, "sln") > 0 then
            return true
        end
        if #scan_dir_for_ext(dir, "vcxproj") > 0 then
            return true
        end
        return nil
    end)
    return hit == true
end

--- Combine ancestor `*.sln` discovery with a recursive `*.vcxproj` scan
--- under `root_dir`. Solutions are listed first, vcxprojs after, with
--- duplicates collapsed by normalized path.
--- @param root_dir string|nil
--- @param opts table|nil
---     @field max_depth integer|nil       passed to find_solutions (default 16)
---     @field max_vcxprojs integer|nil    passed to find_vcxprojs  (default 500)
--- @return string[]
function M.find_all_buildables(root_dir, opts)
    opts = opts or {}
    local root = Util.normalize_path(root_dir or vim.fn.getcwd())
    local out, seen = {}, {}
    if root == nil then
        return out
    end
    local slns = M.find_solutions(root, { max_depth = opts.max_depth or 16 })
    for _, p in ipairs(slns) do
        local n = Util.normalize_path(p)
        if n and not seen[n] then
            seen[n] = true
            out[#out + 1] = n
        end
    end
    local projs =
        M.find_vcxprojs(root, { max_files = opts.max_vcxprojs or 500 })
    for _, p in ipairs(projs) do
        local n = Util.normalize_path(p)
        if n and not seen[n] then
            seen[n] = true
            out[#out + 1] = n
        end
    end
    return out
end

return M
