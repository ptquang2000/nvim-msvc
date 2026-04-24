local Util = require("msvc.util")
local Log = require("msvc.log")
local VsWhere = require("msvc.vswhere")
local Ext = require("msvc.extensions")

local M = {}

local ENV_WHITELIST = {
    "PATH",
    "INCLUDE",
    "LIB",
    "LIBPATH",
    "VCINSTALLDIR",
    -- NOTE: VCToolsVersion / VCToolsInstallDir / VCToolsRedistDir are
    -- intentionally omitted. VsDevCmd exports the *latest* toolset
    -- version; forwarding those values forces every project onto that
    -- toolset and breaks v141/v142 (MSB8052). MSBuild resolves them
    -- per-project from <PlatformToolset>.
    "VSINSTALLDIR",
    "WindowsSdkDir",
    "WindowsSDKVersion",
    "UCRTVersion",
    "UniversalCRTSdkDir",
    "Platform",
    "DevEnvDir",
    "Framework40Version",
    "FrameworkDir",
    "FrameworkVersion",
    "DotNetSdkVersion",
    "ExtensionSdkDir",
}

local _whitelist_set = {}
for _, k in ipairs(ENV_WHITELIST) do
    _whitelist_set[k:upper()] = k
end

local _cache = {}

local VALID_ARCHES = { x64 = true, x86 = true, arm64 = true }

--- Return the names of env vars retained from the developer prompt.
--- @return string[]
function M.list_env_keys()
    local out = {}
    for i, k in ipairs(ENV_WHITELIST) do
        out[i] = k
    end
    return out
end

--- Direct cache lookup, no resolve.
--- @param install_path string
--- @param arch string
--- @return table|nil env
function M.get_cached(install_path, arch)
    if install_path == nil or arch == nil then
        return nil
    end
    local entry = _cache[install_path .. "|" .. arch]
    return entry and entry.env or nil
end

--- Invalidate cached entries. With no args, clears entire cache.
--- @param install_path string|nil
--- @param arch string|nil
function M.invalidate(install_path, arch)
    if install_path == nil and arch == nil then
        _cache = {}
        return
    end
    for key, entry in pairs(_cache) do
        local match_install = install_path == nil
            or entry.install_path == install_path
        local match_arch = arch == nil or entry.arch == arch
        if match_install and match_arch then
            _cache[key] = nil
        end
    end
end

--- Parse `set` output lines into a whitelisted env table.
--- @param lines string[]
--- @return table<string,string>
local function parse_env_lines(lines)
    local env = {}
    for _, line in ipairs(lines or {}) do
        local key, value = line:match("^([^=]+)=(.*)$")
        if key then
            local canonical = _whitelist_set[key:upper()]
            if canonical then
                env[canonical] = (value:gsub("\r$", ""))
            end
        end
    end
    return env
end

--- Write the developer-prompt invocation to a temp .cmd file and return its
--- path. Running a batch file directly sidesteps cmd.exe /s /c quoting rules
--- that break when libuv escapes inner quotes as \".
--- @param bat_path string
--- @param arch string
--- @param is_vcvars boolean
--- @param vcvars_ver string|nil Pinned toolset version (e.g. "14.29") or nil.
--- @return string|nil script_path
--- @return string|nil err
local function write_resolver_script(bat_path, arch, is_vcvars, vcvars_ver)
    local tmp = vim.fn.tempname() .. ".cmd"
    local invocation
    if is_vcvars then
        invocation = ('call "%s" %s'):format(bat_path, arch)
        if vcvars_ver and vcvars_ver ~= "" then
            invocation = invocation .. " -vcvars_ver=" .. vcvars_ver
        end
    else
        invocation = ('call "%s" -no_logo -arch=%s'):format(bat_path, arch)
        if vcvars_ver and vcvars_ver ~= "" then
            invocation = invocation .. " -vcvars_ver=" .. vcvars_ver
        end
    end
    local lines = {
        "@echo off",
        invocation,
        "if errorlevel 1 exit /b %errorlevel%",
        "set",
    }
    local ok, err = pcall(vim.fn.writefile, lines, tmp)
    if not ok then
        return nil, "failed to write resolver script: " .. tostring(err)
    end
    return tmp, nil
end

--- Resolve and cache the MSVC developer environment for a VS installation.
--- @param opts table|nil
---   - install_path  string|nil  Override; defaults to vswhere latest.
---   - arch          string|nil  "x64" (default), "x86", or "arm64".
---   - vswhere_path  string|nil  Forwarded to VsWhere.find_latest.
---   - vcvars_ver    string|nil  Pinned toolset version (e.g. "14.29").
---   - ttl_seconds   integer|nil Cache TTL (default 1800).
---   - force         boolean|nil Bypass cache.
--- @return table|nil env
--- @return string|nil err
function M.resolve(opts)
    opts = opts or {}
    local arch = opts.arch or "x64"
    if not VALID_ARCHES[arch] then
        return nil, "invalid arch: " .. tostring(arch)
    end

    local install_path = opts.install_path
    if install_path == nil then
        local inst = VsWhere.find_latest({
            vswhere_path = opts.vswhere_path,
        })
        if not inst or not inst.installationPath then
            return nil, "no Visual Studio installation found"
        end
        install_path = inst.installationPath
    end
    install_path = Util.normalize_path(install_path)

    local cache_key = install_path
        .. "|"
        .. arch
        .. "|"
        .. tostring(opts.vcvars_ver or "")
    local ttl = opts.ttl_seconds or 1800
    if not opts.force then
        local entry = _cache[cache_key]
        if entry and (os.time() - entry.ts) < ttl then
            return entry.env, nil
        end
    end

    local vsdevcmd =
        Util.normalize_path(install_path .. "\\Common7\\Tools\\VsDevCmd.bat")
    local vcvarsall = Util.normalize_path(
        install_path .. "\\VC\\Auxiliary\\Build\\vcvarsall.bat"
    )

    local bat_path, is_vcvars
    if Util.is_file(vsdevcmd) then
        bat_path, is_vcvars = vsdevcmd, false
    elseif Util.is_file(vcvarsall) then
        bat_path, is_vcvars = vcvarsall, true
    else
        return nil,
            "neither VsDevCmd.bat nor vcvarsall.bat found under "
                .. install_path
    end

    local script, script_err =
        write_resolver_script(bat_path, arch, is_vcvars, opts.vcvars_ver)
    if not script then
        return nil, script_err
    end
    Log:debug(
        "msvc.devenv: resolving env arch=%s vcvars_ver=%s via %s (script=%s)",
        arch,
        tostring(opts.vcvars_ver or ""),
        Util.basename(bat_path),
        script
    )
    local res =
        vim.system({ "cmd.exe", "/d", "/c", script }, { text = true }):wait()
    pcall(os.remove, script)
    if res.code ~= 0 then
        local stderr = (res.stderr or ""):gsub("%s+$", "")
        local detail = stderr ~= "" and (": " .. stderr) or ""
        return nil,
            "developer prompt invocation failed (exit "
                .. tostring(res.code)
                .. ")"
                .. detail
    end
    local lines = vim.split(res.stdout or "", "\r?\n", { trimempty = false })

    local env = parse_env_lines(lines)
    if next(env) == nil or not env.INCLUDE or env.INCLUDE == "" then
        return nil, "developer prompt produced no usable environment"
    end

    _cache[cache_key] = {
        env = env,
        ts = os.time(),
        install_path = install_path,
        arch = arch,
    }

    Ext.extensions:emit(Ext.event_names.ENV_RESOLVED, {
        install_path = install_path,
        arch = arch,
        env = env,
    })

    return env, nil
end

--- Locate MSBuild.exe given an env table or an installation root path.
--- @param env_or_install table|string|nil
--- @return string|nil
function M.find_msbuild(env_or_install)
    if env_or_install == nil then
        return nil
    end

    local install
    if type(env_or_install) == "table" then
        install = env_or_install.VSINSTALLDIR
            or env_or_install.VCINSTALLDIR
            or env_or_install.DevEnvDir
        if install and install ~= "" then
            install = install:gsub("[\\/]+$", "")
            -- VCINSTALLDIR/DevEnvDir can be nested; strip known suffixes.
            install = install:gsub("\\VC$", "")
            install = install:gsub("\\Common7\\IDE$", "")
        end
    else
        install = env_or_install
    end

    if not install or install == "" then
        return nil
    end
    install = Util.normalize_path(install)

    local current =
        Util.normalize_path(install .. "\\MSBuild\\Current\\Bin\\MSBuild.exe")
    if Util.is_file(current) then
        return current
    end

    local msbuild_root = install .. "\\MSBuild"
    local uv = vim.uv or vim.loop
    local handle = uv.fs_scandir(msbuild_root)
    if handle then
        local best
        while true do
            local name, t = uv.fs_scandir_next(handle)
            if not name then
                break
            end
            if t == "directory" and name ~= "Current" then
                local candidate = Util.normalize_path(
                    msbuild_root .. "\\" .. name .. "\\Bin\\MSBuild.exe"
                )
                if Util.is_file(candidate) then
                    if best == nil or name > best.version then
                        best = { version = name, path = candidate }
                    end
                end
            end
        end
        if best then
            return best.path
        end
    end

    return nil
end

return M
