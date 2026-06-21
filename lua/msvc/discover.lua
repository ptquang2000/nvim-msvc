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

--- Scan a directory tree for `.sln` files. Bounded by `max_files`.
function M.find_slns(root, opts)
    opts = opts or {}
    local max = opts.max_files or 100
    local norm = Util.normalize_path(root)
    if not norm or not Util.is_dir(norm) then
        return {}
    end
    local matches = vim.fn.globpath(norm, "**/*.sln", true, true)
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
        for line in section:gmatch("[^\n]+") do
            local cfg, plat = line:match("^%s*([^|]+)|([^=]+)%s*=")
            if cfg and plat then
                cfg = cfg:match("^%s*(.-)%s*$")
                plat = plat:match("^%s*(.-)%s*$")
                if cfg ~= "" and not CMAKE_META_TARGETS[cfg] then
                    cfgs[#cfgs + 1] = cfg
                end
                if plat ~= "" then
                    plats[#plats + 1] = plat
                end
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

--- Parse `<WindowsTargetPlatformVersion>` and `<PlatformToolset>` from a
--- `.vcxproj`. Returns `{ winsdk, vcvars_ver }` (either may be nil).
--- Called by `ui.lua` for display and by `init.lua:build()` to resolve
--- the hidden toolchain fields before spawning MSBuild.
function M.discover_vcxproj_toolchain(vcxproj_path)
    if not vcxproj_path or not Util.is_file(vcxproj_path) then
        return {}
    end
    local body = Util.read_file(vcxproj_path)
    if not body then
        return {}
    end
    local winsdk =
        body:match("<WindowsTargetPlatformVersion[^>]*>([^<]+)</WindowsTargetPlatformVersion>")
    local toolset =
        body:match("<PlatformToolset[^>]*>([^<]+)</PlatformToolset>")
    if winsdk then
        winsdk = winsdk:match("^%s*(.-)%s*$")
    end
    if toolset then
        toolset = toolset:match("^%s*(.-)%s*$")
    end
    return { winsdk = winsdk, vcvars_ver = toolset }
end

--- Parse `<PreprocessorDefinitions>` from the `<ItemDefinitionGroup>` block
--- that matches `configuration|platform`. Falls back to unconditional groups.
--- Returns a `string[]` of `-D<define>` entries; `{}` if nothing found.
---@param vcxproj_path string
---@param configuration string
---@param platform string
---@return string[]
function M.parse_vcxproj_defines(vcxproj_path, configuration, platform)
    if not vcxproj_path or not Util.is_file(vcxproj_path) then
        return {}
    end
    local body = Util.read_file(vcxproj_path)
    if not body then
        return {}
    end

    local cfg_plat = configuration .. "|" .. platform
    local defines_raw = nil
    local fallback_defines = nil

    local pos = 1
    while true do
        local tag_s = body:find("<ItemDefinitionGroup", pos, true)
        if not tag_s then
            break
        end
        local tag_e = body:find(">", tag_s, true)
        if not tag_e then
            break
        end
        local opening_tag = body:sub(tag_s, tag_e)
        local close_s = body:find("</ItemDefinitionGroup>", tag_e, true)
        if not close_s then
            break
        end
        local block = body:sub(tag_e + 1, close_s - 1)

        if opening_tag:find(cfg_plat, 1, true) then
            local defs = block:match(
                "<PreprocessorDefinitions[^>]*>([^<]*)</PreprocessorDefinitions>"
            )
            if defs then
                defines_raw = defs
                break
            end
        elseif not opening_tag:find("Condition", 1, true) and not fallback_defines then
            local defs = block:match(
                "<PreprocessorDefinitions[^>]*>([^<]*)</PreprocessorDefinitions>"
            )
            if defs then
                fallback_defines = defs
            end
        end

        pos = close_s + 1
    end

    local raw = defines_raw or fallback_defines
    if not raw then
        return {}
    end

    local out = {}
    for token in (raw .. ";"):gmatch("([^;]*);") do
        token = token:match("^%s*(.-)%s*$")
        if token ~= "" and token ~= "%(PreprocessorDefinitions)" then
            out[#out + 1] = "-D" .. token
        end
    end
    return out
end

--- Find .sln files recursively in `cwd`, ignoring .gitignore.
--- Uses `rg` when available, PowerShell as fallback.
---@param cwd string
---@return string[]  sorted, normalized absolute paths
function M.find_sln_files(cwd)
    local norm = Util.normalize_path(cwd)
    if not norm or not Util.is_dir(norm) then
        return {}
    end
    local raw
    if vim.fn.executable("rg") == 1 then
        raw = vim.fn.system({ "rg", "--no-ignore", "--files", "--glob", "*.sln", norm })
    else
        local escaped = norm:gsub("'", "''")
        raw = vim.fn.system(
            "powershell -NoProfile -Command \""
                .. "Get-ChildItem -Path '"
                .. escaped
                .. "' -Recurse -Filter '*.sln' | Select-Object -ExpandProperty FullName\""
        )
    end
    if not raw or raw == "" then
        return {}
    end
    local out = {}
    local seen = {}
    for line in (raw .. "\n"):gmatch("([^\r\n]+)") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" then
            local p = Util.normalize_path(line)
            if p and not seen[p:lower()] then
                seen[p:lower()] = true
                out[#out + 1] = p
            end
        end
    end
    table.sort(out)
    return out
end

return M
