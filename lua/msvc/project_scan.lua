-- msvc.project_scan: minimal `.sln` / `.vcxproj` scanner used to derive
-- the dynamic `configuration` / `platform` completion lists at setup
-- time. Pure functions on top of plain Lua patterns — no XML library,
-- no Neovim API outside `vim.uv` for the optional cwd walk.

local M = {}

--- Read a file's contents. Returns nil on any I/O error rather than
--- raising — callers (warm path) deal with partial inputs by skipping.
---@param path string
---@return string|nil content
function M.read_file(path)
    local fd = io.open(path, "rb")
    if not fd then
        return nil
    end
    local content = fd:read("*a")
    fd:close()
    return content
end

--- Parse the `GlobalSection(SolutionConfigurationPlatforms)` block of a
--- Visual Studio `.sln` file. Returns a list of `{configuration, platform}`
--- tuples. Tolerates the modern .slnx XML format (which uses
--- `<Configuration Name="Debug|x64"/>` entries) by also matching that
--- pattern as a fallback.
---@param content string
---@return string[][2]
function M.parse_sln(content)
    local out = {}
    if type(content) ~= "string" or content == "" then
        return out
    end
    local in_block = false
    for line in content:gmatch("[^\r\n]+") do
        if line:find("GlobalSection%(SolutionConfigurationPlatforms%)") then
            in_block = true
        elseif in_block and line:find("EndGlobalSection", 1, true) then
            in_block = false
        elseif in_block then
            -- Lines look like:  "    Debug|x64 = Debug|x64"
            -- Platform side may contain spaces ("Any CPU"); configuration side
            -- never does, but allow it just in case.
            local cfg, plat = line:match("^%s*([^|=]-)%s*|%s*(.-)%s*=")
            if cfg and plat and cfg ~= "" and plat ~= "" then
                out[#out + 1] = { cfg, plat }
            end
        end
    end
    -- Fallback: .slnx (XML) form.
    if #out == 0 then
        for cfg, plat in
            content:gmatch("<Configuration%s+Name=\"([^\"|]+)|([^\"]+)\"")
        do
            out[#out + 1] = { cfg, plat }
        end
    end
    return out
end

--- Parse the `<ProjectConfiguration Include="Cfg|Plat">` items in a
--- `.vcxproj` file. Returns a list of `{configuration, platform}` tuples.
--- "Any CPU" (with the embedded space) is preserved verbatim.
---@param content string
---@return string[][2]
function M.parse_vcxproj(content)
    local out = {}
    if type(content) ~= "string" or content == "" then
        return out
    end
    for cfg, plat in
        content:gmatch("<ProjectConfiguration%s+Include=\"([^\"|]+)|([^\"]+)\"")
    do
        out[#out + 1] = { cfg, plat }
    end
    return out
end

--- Collapse a list of `{cfg, plat}` tuples into the two sorted-unique
--- candidate lists exposed by `Msvc.project_targets`.
---@param tuples string[][2]
---@return { configurations: string[], platforms: string[] }
function M.dedup_sort(tuples)
    local cfg_seen, plat_seen = {}, {}
    local cfgs, plats = {}, {}
    for _, t in ipairs(tuples or {}) do
        local cfg, plat = t[1], t[2]
        if type(cfg) == "string" and cfg ~= "" and not cfg_seen[cfg] then
            cfg_seen[cfg] = true
            cfgs[#cfgs + 1] = cfg
        end
        if type(plat) == "string" and plat ~= "" and not plat_seen[plat] then
            plat_seen[plat] = true
            plats[#plats + 1] = plat
        end
    end
    table.sort(cfgs)
    table.sort(plats)
    return { configurations = cfgs, platforms = plats }
end

--- Hard-coded fallback used when no project files are found at all.
--- Mirrors the historical static list in `commands.lua` so plain
--- `:Msvc update configuration <Tab>` outside a project still completes
--- to *something* sensible.
---@return { configurations: string[], platforms: string[] }
function M.fallback_defaults()
    return {
        configurations = { "Debug", "Release" },
        platforms = { "Win32", "x64" },
    }
end

local DEFAULT_IGNORE = {
    [".git"] = true,
    [".hg"] = true,
    [".svn"] = true,
    node_modules = true,
    obj = true,
    bin = true,
    out = true,
    Debug = true,
    Release = true,
    x64 = true,
    Win32 = true,
    ARM64 = true,
}

--- Depth-limited scan of `cwd` for `.sln`/`.vcxproj` files. Used as a
--- fallback when no solution has been pinned. Capped to keep the warm
--- step bounded on large monorepos.
---@param opts { depth?: integer, cap?: integer, root?: string }|nil
---@return string[]
function M.find_targets_in_cwd(opts)
    opts = opts or {}
    local depth = opts.depth or 2
    local cap = opts.cap or 50
    local root = opts.root or vim.fn.getcwd()

    local out = {}
    local stack = { { root, 0 } }
    local uv = vim.uv or vim.loop
    while #stack > 0 and #out < cap do
        local frame = table.remove(stack)
        local dir, d = frame[1], frame[2]
        local fs = uv.fs_scandir(dir)
        if fs then
            while true do
                local name, t = uv.fs_scandir_next(fs)
                if not name then
                    break
                end
                local full = dir .. "\\" .. name
                if t == "file" or not t then
                    local lower = name:lower()
                    if
                        lower:match("%.sln$")
                        or lower:match("%.slnx$")
                        or lower:match("%.vcxproj$")
                    then
                        out[#out + 1] = full
                        if #out >= cap then
                            break
                        end
                    end
                elseif t == "directory" and d < depth then
                    if not DEFAULT_IGNORE[name] then
                        stack[#stack + 1] = { full, d + 1 }
                    end
                end
            end
        end
    end
    return out
end

return M
