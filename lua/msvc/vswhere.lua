-- msvc.vswhere — JSON-output wrapper around `vswhere.exe`.

local Util = require("msvc.util")
local Log = require("msvc.log")

local M = {}

local DEFAULT_VSWHERE =
    "C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\vswhere.exe"

--- Translate a user-friendly `vs_version` token into a vswhere `-version`
--- argument. Accepts:
---   * "latest" / nil    → omit (latest stable)
---   * marketing year    → "2017"|"2019"|"2022"
---   * single component  → "17"  → "[17.0,18.0)"
---   * pinned component  → "17.10" → "[17.10,17.11)"
---   * full 4-part version → "[X,X]" exact range
---   * already-formatted "[a,b]" → returned verbatim
---@param v any
---@return string|nil
local function translate_version(v)
    if v == nil or v == "latest" or v == "" then
        return nil
    end
    if type(v) ~= "string" and type(v) ~= "number" then
        return nil
    end
    local s = tostring(v)
    if s:match("^%s*[%[%(].*[%]%)]%s*$") then
        return s
    end
    local YEAR_RANGES = {
        ["2017"] = "[15.0,16.0)",
        ["2019"] = "[16.0,17.0)",
        ["2022"] = "[17.0,18.0)",
    }
    if YEAR_RANGES[s] then
        return YEAR_RANGES[s]
    end
    local parts = {}
    for n in s:gmatch("(%d+)") do
        parts[#parts + 1] = tonumber(n) or 0
    end
    if #parts == 0 then
        return nil
    end
    if #parts == 1 then
        local maj = parts[1]
        return ("[%d.0,%d.0)"):format(maj, maj + 1)
    end
    if #parts == 2 then
        local maj, min = parts[1], parts[2]
        return ("[%d.%d,%d.%d)"):format(maj, min, maj, min + 1)
    end
    return ("[%s,%s]"):format(s, s)
end
M._translate_version = translate_version

local function build_args(opts)
    opts = opts or {}
    local args = { "-products" }
    local products = opts.vs_products
    if type(products) == "table" and #products > 0 then
        for _, p in ipairs(products) do
            args[#args + 1] = p
        end
    else
        args[#args + 1] = "*"
    end
    args[#args + 1] = "-all"
    if opts.vs_prerelease then
        args[#args + 1] = "-prerelease"
    end
    local v = translate_version(opts.vs_version)
    if v ~= nil then
        args[#args + 1] = "-version"
        args[#args + 1] = v
    end
    if type(opts.vs_requires) == "table" then
        for _, req in ipairs(opts.vs_requires) do
            if type(req) == "string" and req ~= "" then
                args[#args + 1] = "-requires"
                args[#args + 1] = req
            end
        end
    end
    return args
end
M._build_args = build_args

function M.find_vswhere(opts)
    opts = opts or {}
    local explicit = opts.vswhere_path
    if type(explicit) == "string" and explicit ~= "" then
        if Util.is_file(explicit) then
            return explicit
        end
        Log:warn("vswhere: configured path does not exist: %s", explicit)
    end
    local pf86 = vim.env["ProgramFiles(x86)"]
    local standard = (
        pf86 and (pf86 .. "\\Microsoft Visual Studio\\Installer\\vswhere.exe")
    ) or DEFAULT_VSWHERE
    if Util.is_file(standard) then
        return standard
    end
    local on_path = vim.fn.exepath("vswhere")
    if type(on_path) == "string" and on_path ~= "" then
        return on_path
    end
    return nil
end

local function run(cmd)
    local res = vim.system(cmd, { text = true }):wait()
    local code = res.code or 0
    if code ~= 0 then
        local msg = ("vswhere exit %d: %s"):format(
            code,
            ((res.stderr or "")):gsub("%s+$", "")
        )
        return nil, msg
    end
    local stdout = res.stdout or ""
    if stdout == "" then
        return {}, nil
    end
    local ok, decoded = pcall(vim.json.decode, stdout)
    if not ok or type(decoded) ~= "table" then
        return nil, "vswhere: failed to decode JSON"
    end
    return decoded, nil
end

function M.list_installations(opts)
    opts = opts or {}
    local exe = M.find_vswhere(opts)
    if not exe then
        Log:warn("vswhere: vswhere.exe not found")
        return {}
    end
    local args = { exe }
    for _, a in ipairs(build_args(opts)) do
        args[#args + 1] = a
    end
    args[#args + 1] = "-format"
    args[#args + 1] = "json"
    args[#args + 1] = "-utf8"
    args[#args + 1] = "-nologo"
    local result, err = run(args)
    if not result then
        Log:warn("vswhere: %s", tostring(err))
        return {}
    end
    return result
end

local function split_version(v)
    local parts = {}
    if type(v) ~= "string" then
        return parts
    end
    for n in v:gmatch("(%d+)") do
        parts[#parts + 1] = tonumber(n) or 0
    end
    return parts
end

local function compare_versions(a, b)
    local pa, pb = split_version(a), split_version(b)
    local n = math.max(#pa, #pb)
    for i = 1, n do
        local ai, bi = pa[i] or 0, pb[i] or 0
        if ai ~= bi then
            return ai < bi and -1 or 1
        end
    end
    return 0
end

--- Pick the highest-version installation, preferring stable over prerelease.
function M.pick_latest(installs)
    if not installs or #installs == 0 then
        return nil
    end
    local stable, pre = {}, {}
    for _, inst in ipairs(installs) do
        if inst.isPrerelease then
            pre[#pre + 1] = inst
        else
            stable[#stable + 1] = inst
        end
    end
    local pool = (#stable > 0) and stable or pre
    table.sort(pool, function(a, b)
        return compare_versions(
            a.installationVersion or "",
            b.installationVersion or ""
        ) > 0
    end)
    return pool[1]
end

function M.find_latest(opts)
    return M.pick_latest(M.list_installations(opts))
end

--- Async variant of list_installations.
function M.list_installations_async(opts, callback)
    opts = opts or {}
    if type(callback) ~= "function" then
        return
    end
    local exe = M.find_vswhere(opts)
    if not exe then
        callback({}, "vswhere.exe not found")
        return
    end
    local cmd = { exe }
    for _, a in ipairs(build_args(opts)) do
        cmd[#cmd + 1] = a
    end
    cmd[#cmd + 1] = "-format"
    cmd[#cmd + 1] = "json"
    cmd[#cmd + 1] = "-utf8"
    cmd[#cmd + 1] = "-nologo"
    vim.system(
        cmd,
        { text = true },
        vim.schedule_wrap(function(res)
            if not res or (res.code or 0) ~= 0 then
                callback(
                    {},
                    ("vswhere exit %d: %s"):format(
                        res and res.code or -1,
                        ((res and res.stderr) or ""):gsub("%s+$", "")
                    )
                )
                return
            end
            local stdout = res.stdout or ""
            if stdout == "" then
                callback({}, nil)
                return
            end
            local ok, decoded = pcall(vim.json.decode, stdout)
            if not ok or type(decoded) ~= "table" then
                callback({}, "vswhere: failed to decode JSON")
                return
            end
            callback(decoded, nil)
        end)
    )
end

return M
