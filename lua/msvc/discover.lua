-- msvc.discover — locate solutions / vcxprojs and parse their target lists.

local Util = require("msvc.util")
local Log = require("msvc.log")

local M = {}

local CMAKE_META_TARGETS = {
    ALL_BUILD = true,
    ZERO_CHECK = true,
    INSTALL = true,
    PACKAGE = true,
    RUN_TESTS = true,
    RESTORE = true,
    Continuous = true,
    Experimental = true,
    Nightly = true,
    NightlyMemoryCheck = true,
}

M.CMAKE_META_TARGETS = CMAKE_META_TARGETS

local FALLBACK_CONFIGS = { "Debug", "Release" }
local FALLBACK_PLATFORMS = { "x64", "Win32" }

--- Walk up from `start_dir` to the filesystem root, returning the first
--- directory that contains exactly one `.sln` file. Returns nil when none
--- found. Multiple `.sln` files in a single directory are treated as
--- ambiguous (returns nil) — callers should fail loudly.
local function find_solution(start_dir)
    local dir = Util.normalize_path(start_dir or vim.fn.getcwd())
    local last
    while dir and dir ~= "" and dir ~= last do
        local matches = vim.fn.glob(Util.join_path(dir, "*.sln"), true, true)
        if #matches == 1 then
            return Util.normalize_path(matches[1])
        elseif #matches > 1 then
            return nil, ("multiple .sln files in %s"):format(dir)
        end
        last = dir
        dir = Util.dirname(dir)
    end
    return nil
end

function M.find_solution(start_dir)
    return find_solution(start_dir)
end

--- Scan a directory tree for `.vcxproj` files. Bounded by `max_files`.
function M.find_vcxprojs(root, opts)
    opts = opts or {}
    local max = opts.max_files or 5000
    local norm = Util.normalize_path(root)
    if not norm or not Util.is_dir(norm) then
        return {}
    end
    local matches = vim.fn.globpath(norm, "**/*.vcxproj", true, true)
    if type(matches) ~= "table" then
        return {}
    end
    local out = {}
    for _, p in ipairs(matches) do
        out[#out + 1] = Util.normalize_path(p)
        if #out >= max then
            break
        end
    end
    return out
end

--- Parse `.sln` body and yield `{ name = ..., path = absolute }` for every
--- `Project(...) = "Name", "RelativePath", "{guid}"` line whose path ends
--- in `.vcxproj`.
function M.parse_solution_projects(sln_path)
    if not sln_path or not Util.is_file(sln_path) then
        return {}
    end
    local body, err = Util.read_file(sln_path)
    if not body then
        Log:warn("discover: failed to read %s: %s", sln_path, tostring(err))
        return {}
    end
    local dir = Util.dirname(sln_path)
    local out = {}
    local seen = {}
    for name, rel in
        body:gmatch("%s*Project%([^)]+%)%s*=%s*\"([^\"]+)\"%s*,%s*\"([^\"]+)\"")
    do
        if rel:lower():match("%.vcxproj$") then
            local abs = Util.resolve_path(rel, dir) or rel
            if not seen[abs] then
                seen[abs] = true
                out[#out + 1] = { name = name, path = abs }
            end
        end
    end
    return out
end

local function dedupe_sort(list)
    local out = Util.dedupe(list)
    table.sort(out)
    return out
end

--- Parse `<Configuration>` / `<Platform>` from a `.vcxproj`.
local function parse_vcxproj(project_path)
    local body = Util.read_file(project_path)
    if not body then
        return nil, nil
    end
    local cfgs, plats = {}, {}
    for cfg in body:gmatch("<Configuration[^>]*>([^<]+)</Configuration>") do
        cfg = cfg:match("^%s*(.-)%s*$")
        if cfg and cfg ~= "" then
            cfgs[#cfgs + 1] = cfg
        end
    end
    for plat in body:gmatch("<Platform[^>]*>([^<]+)</Platform>") do
        plat = plat:match("^%s*(.-)%s*$")
        if plat and plat ~= "" then
            plats[#plats + 1] = plat
        end
    end
    return cfgs, plats
end

--- Parse `.sln` for its `GlobalSection(SolutionConfigurationPlatforms)`.
local function parse_sln(sln_path)
    local body = Util.read_file(sln_path)
    if not body then
        return nil, nil
    end
    local cfgs, plats = {}, {}
    local section = body:match(
        "GlobalSection%(SolutionConfigurationPlatforms%).-EndGlobalSection"
    )
    if section then
        for cfg, plat in section:gmatch("([^=%s|]+)|([^=%s]+)%s*=") do
            cfg, plat = cfg:gsub("%s+", ""), plat:gsub("%s+", "")
            if cfg ~= "" and not CMAKE_META_TARGETS[cfg] then
                cfgs[#cfgs + 1] = cfg
            end
            if plat ~= "" then
                plats[#plats + 1] = plat
            end
        end
    end
    return cfgs, plats
end

--- Discover available configurations / platforms for the current solution +
--- (optional) project. Falls back to common defaults when nothing parses.
---@param solution string|nil
---@param project string|nil
---@return { configurations: string[], platforms: string[] }
function M.discover_targets(solution, project)
    local cfgs, plats = {}, {}
    if project and Util.is_file(project) then
        local pc, pp = parse_vcxproj(project)
        for _, c in ipairs(pc or {}) do
            cfgs[#cfgs + 1] = c
        end
        for _, p in ipairs(pp or {}) do
            plats[#plats + 1] = p
        end
    end
    if solution and Util.is_file(solution) then
        local sc, sp = parse_sln(solution)
        for _, c in ipairs(sc or {}) do
            cfgs[#cfgs + 1] = c
        end
        for _, p in ipairs(sp or {}) do
            plats[#plats + 1] = p
        end
    end
    cfgs = dedupe_sort(cfgs)
    plats = dedupe_sort(plats)
    if #cfgs == 0 then
        cfgs = { unpack(FALLBACK_CONFIGS) }
    end
    if #plats == 0 then
        plats = { unpack(FALLBACK_PLATFORMS) }
    end
    return { configurations = cfgs, platforms = plats }
end

return M
