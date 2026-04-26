local Util = require("msvc.util")
local Log = require("msvc.log")
local Config = require("msvc.config")

-- Note: Config is required for type cohesion (callers may pass settings from
-- a config), but per design this module does not call Config.merge_config.
local _ = Config

local M = {}

local DEFAULT_VSWHERE =
    "C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\vswhere.exe"

-- Retained for backward-compatibility with external references; no longer
-- used by the default args list (callers drive `-requires` via
-- `opts.vs_requires`).
local VC_TOOLS_REQ = "Microsoft.VisualStudio.Component.VC.Tools.x86.x64"
local _ = VC_TOOLS_REQ

--- Build the `vswhere` argv (excluding the executable and the trailing
--- `-format json -utf8 -nologo` flags) from a profile-shaped opts table.
---
--- Recognised keys:
---   * `vs_products`  string[]  — emitted as `-products A B ...`.
---     Defaults to `{"*"}` when nil/empty.
---   * `vs_prerelease` boolean  — emits `-prerelease` when truthy.
---   * `vs_version`   string    — emitted as `-version <value>` when set
---     and not `"latest"` / `"any"`. Passed verbatim so callers can use
---     vswhere's range syntax, e.g. `"[17.0,18.0)"`.
---   * `vs_requires`  string[]  — emitted as one `-requires <id>` pair
---     per element. When nil/empty, no `-requires` flag is emitted.
---
--- `-all` is always included (matches existing behavior).
---
---@param opts table|nil
---@return string[]
local function build_args(opts)
    opts = opts or {}
    local args = {}

    args[#args + 1] = "-products"
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

    local v = opts.vs_version
    if
        type(v) == "string"
        and v ~= ""
        and v ~= "latest"
        and v ~= "any"
    then
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

--- Locate `vswhere.exe`.
---
--- Search order:
---   1. `opts.vswhere_path` (or `opts.settings.vswhere_path`) if it points
---      to an existing file.
---   2. Standard installer location under `${ProgramFiles(x86)}`.
---   3. `vim.fn.exepath("vswhere")` (PATH lookup).
---
--- @param opts table|nil  May contain `vswhere_path` or `settings.vswhere_path`.
--- @return string|nil  Absolute path to vswhere.exe, or nil if not found.
function M.find_vswhere(opts)
    opts = opts or {}

    local explicit = opts.vswhere_path
    if not explicit and type(opts.settings) == "table" then
        explicit = opts.settings.vswhere_path
    end
    if type(explicit) == "string" and explicit ~= "" then
        if Util.is_file(explicit) then
            Log:debug("vswhere: using configured path %s", explicit)
            return explicit
        end
        Log:warn("vswhere: configured path does not exist: %s", explicit)
    end

    local pf86 = vim.env["ProgramFiles(x86)"]
    local standard = (
        pf86
        and (pf86 .. "\\Microsoft Visual Studio\\Installer\\vswhere.exe")
    ) or DEFAULT_VSWHERE
    if Util.is_file(standard) then
        Log:debug("vswhere: found standard install at %s", standard)
        return standard
    end

    local on_path = vim.fn.exepath("vswhere")
    if type(on_path) == "string" and on_path ~= "" then
        Log:debug("vswhere: found on PATH at %s", on_path)
        return on_path
    end

    Log:debug("vswhere: not found")
    return nil
end

--- Run `vswhere.exe` with the given arguments and parse its JSON output.
---
--- The flags `-format json -utf8 -nologo` are appended automatically.
---
--- @param args string[]            Extra CLI args to pass to vswhere.
--- @param vswhere_path string|nil  Optional explicit path; resolved otherwise.
--- @return table|nil result        Parsed JSON array, or nil on failure.
--- @return string|nil err          Error message when result is nil.
function M.run_vswhere(args, vswhere_path)
    args = args or {}
    local exe = vswhere_path or M.find_vswhere()
    if not exe then
        return nil, "vswhere.exe not found"
    end

    local cmd = { exe }
    for _, a in ipairs(args) do
        cmd[#cmd + 1] = a
    end
    cmd[#cmd + 1] = "-format"
    cmd[#cmd + 1] = "json"
    cmd[#cmd + 1] = "-utf8"
    cmd[#cmd + 1] = "-nologo"

    local stdout, code
    if vim.system then
        local res = vim.system(cmd, { text = true }):wait()
        stdout = res.stdout or ""
        code = res.code or 0
        if code ~= 0 then
            local msg = ("vswhere exit %d: %s"):format(
                code,
                (res.stderr or ""):gsub("%s+$", "")
            )
            Log:warn("vswhere: %s", msg)
            return nil, msg
        end
    else
        local lines = vim.fn.systemlist(cmd)
        code = vim.v.shell_error
        stdout = table.concat(lines, "\n")
        if code ~= 0 then
            local msg = ("vswhere exit %d: %s"):format(code, stdout)
            Log:warn("vswhere: %s", msg)
            return nil, msg
        end
    end

    if stdout == nil or stdout == "" then
        return {}, nil
    end

    local ok, decoded = pcall(vim.json.decode, stdout)
    if not ok then
        local msg = "vswhere: failed to decode JSON: " .. tostring(decoded)
        Log:warn(msg)
        return nil, msg
    end
    if type(decoded) ~= "table" then
        return {}, nil
    end
    return decoded, nil
end

--- List Visual Studio installations matching the profile-shaped `opts`.
---
--- Args fed to `vswhere` are derived from `opts.vs_products`,
--- `opts.vs_prerelease`, `opts.vs_version`, and `opts.vs_requires`. See
--- `build_args` for the exact mapping. With no opts the equivalent
--- invocation is `vswhere -products * -all`.
---
--- @param opts table|nil  May contain `vswhere_path` or `settings.vswhere_path`,
---                        plus `vs_products`, `vs_prerelease`, `vs_version`,
---                        `vs_requires`.
--- @return table[]        Array of installation entries (possibly empty).
function M.list_installations(opts)
    opts = opts or {}
    local exe = M.find_vswhere(opts)
    if not exe then
        Log:warn("vswhere: cannot list installations, vswhere.exe missing")
        return {}
    end

    local args = build_args(opts)
    local result, err = M.run_vswhere(args, exe)
    if not result then
        Log:warn("vswhere: list_installations failed: %s", err or "?")
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

--- Return the highest-version VS installation, preferring stable releases.
---
--- Sort key is `installationVersion` (descending). Pre-release entries are
--- only returned when no stable installation exists.
---
--- @param opts table|nil  Forwarded to `M.list_installations`.
--- @return table|nil      Installation entry, or nil when none found.
--- Choose the highest-version installation from a list. Pre-release entries
--- are only considered when no stable installation exists.
---@param installs table[]
---@return table|nil
function M.pick_latest(installs)
    if not installs or #installs == 0 then
        return nil
    end
    local stable, prerelease = {}, {}
    for _, inst in ipairs(installs) do
        if inst.isPrerelease then
            prerelease[#prerelease + 1] = inst
        else
            stable[#stable + 1] = inst
        end
    end
    local pool = (#stable > 0) and stable or prerelease
    table.sort(pool, function(a, b)
        return compare_versions(
            a.installationVersion or "",
            b.installationVersion or ""
        ) > 0
    end)
    return pool[1]
end

function M.find_latest(opts)
    local installs = M.list_installations(opts)
    return M.pick_latest(installs)
end

--- Asynchronous variant of `list_installations`. Spawns vswhere via
--- `vim.system` without blocking, then invokes `callback(installs, err)`
--- on the main loop (via `vim.schedule_wrap`). On failure, `installs`
--- is an empty list and `err` describes the problem.
---@param opts table|nil       Forwarded to `M.find_vswhere`.
---@param callback fun(installs: table[], err: string|nil)
function M.list_installations_async(opts, callback)
    opts = opts or {}
    if type(callback) ~= "function" then
        return
    end
    if not vim.system then
        callback(M.list_installations(opts), nil)
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
                local stderr = res and res.stderr or ""
                callback(
                    {},
                    ("vswhere exit %d: %s"):format(
                        res and res.code or -1,
                        (stderr or ""):gsub("%s+$", "")
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

--- Asynchronous variant of `find_latest`. Spawns vswhere via `vim.system`
--- without blocking, then invokes `callback(install, err)` on the main
--- loop (via `vim.schedule_wrap`). When vswhere or `vim.system` is
--- unavailable, the callback is invoked synchronously with an error.
---@param opts table|nil       Forwarded to `M.find_vswhere`.
---@param callback fun(install: table|nil, err: string|nil)
function M.find_latest_async(opts, callback)
    if type(callback) ~= "function" then
        return
    end
    M.list_installations_async(opts, function(installs, err)
        if err and (not installs or #installs == 0) then
            callback(nil, err)
            return
        end
        callback(M.pick_latest(installs), nil)
    end)
end

local function norm_for_compare(p)
    if type(p) ~= "string" then
        return ""
    end
    local s = p:gsub("/", "\\"):gsub("\\+$", "")
    if Util.is_windows() then
        s = s:lower()
    end
    return s
end

--- Find the installation matching `install_path`.
---
--- Comparison is case-insensitive on Windows and tolerant of trailing
--- separators / forward-vs-back slashes.
---
--- @param install_path string  Absolute path to a VS installation root.
--- @return table|nil           Matching installation entry, or nil.
function M.find_by_path(install_path)
    if type(install_path) ~= "string" or install_path == "" then
        return nil
    end
    local target = norm_for_compare(install_path)
    local installs = M.list_installations()
    for _, inst in ipairs(installs) do
        if norm_for_compare(inst.installationPath) == target then
            return inst
        end
    end
    return nil
end

return M
