-- msvc.devenv — invoke `vcvarsall.bat` inside `cmd.exe` and capture the
-- resulting environment as a table. Cached per (install, arch, vcvars_ver,
-- winsdk) tuple. The dev-prompt env is *forwarded* to MSBuild and the
-- compile_commands extractor (no `vcvars` is sourced before launching
-- MSBuild itself, so VS picks per-project toolsets correctly).

local Util = require("msvc.util")
local Log = require("msvc.log")

local M = {}

-- Whitelist: keys we copy from the dev prompt's environment. The
-- whitelist is defensive — vcvarsall sets a couple hundred variables;
-- MSBuild + the extractor only need a small subset (compiler INCLUDE /
-- LIB paths, VS root markers, PATH, and SDK variables).
local KEEP_KEYS = {
    "PATH",
    "INCLUDE",
    "LIB",
    "LIBPATH",
    "VSINSTALLDIR",
    "VCINSTALLDIR",
    "DevEnvDir",
    "VCToolsInstallDir",
    "VCToolsRedistDir",
    "WindowsSdkDir",
    "WindowsSdkBinPath",
    "WindowsSdkVerBinPath",
    "WindowsSDKLibVersion",
    "WindowsSDKVersion",
    "WindowsLibPath",
    "WindowsSDK_ExecutablePath_x64",
    "WindowsSDK_ExecutablePath_x86",
    "ExtensionSdkDir",
    "Framework40Version",
    "FrameworkDir",
    "FrameworkDir32",
    "FrameworkDir64",
    "FrameworkVersion",
    "FrameworkVersion32",
    "FrameworkVersion64",
    "NETFXSDKDir",
    "UCRTVersion",
    "UniversalCRTSdkDir",
    "Platform",
    "Configuration",
    "VCIDEInstallDir",
    "VS170COMNTOOLS",
    "VS160COMNTOOLS",
    "VS150COMNTOOLS",
    "VSCMD_ARG_HOST_ARCH",
    "VSCMD_ARG_TGT_ARCH",
    "VSCMD_ARG_app_plat",
    "VSCMD_ARG_winsdk",
    "ALLUSERSPROFILE",
    "APPDATA",
    "LOCALAPPDATA",
    "PROGRAMDATA",
    "ProgramFiles",
    "ProgramFiles(x86)",
    "ProgramW6432",
    "TEMP",
    "TMP",
    "USERPROFILE",
    "SystemRoot",
    "SystemDrive",
    "ComSpec",
    "PATHEXT",
    "COMPUTERNAME",
    "USERDOMAIN",
    "USERNAME",
}
local KEEP_SET = {}
for _, k in ipairs(KEEP_KEYS) do
    KEEP_SET[k:upper()] = k
end

local cache = {}

local function cache_key(install, arch, vcvars_ver, winsdk)
    return table.concat(
        { install or "", arch or "", vcvars_ver or "", winsdk or "" },
        "|"
    )
end

--- Find the path to `vcvarsall.bat` under a VS installation.
function M.find_vcvarsall(install)
    if not install or install == "" then
        return nil
    end
    local p =
        Util.join_path(install, "VC", "Auxiliary", "Build", "vcvarsall.bat")
    if Util.is_file(p) then
        return p
    end
    return nil
end

--- Find MSBuild.exe under a VS installation. Scans VS 17/16/15.
function M.find_msbuild(install)
    if not install or install == "" then
        return nil
    end
    local subdirs = { "MSBuild\\Current\\Bin", "MSBuild\\15.0\\Bin" }
    for _, sd in ipairs(subdirs) do
        local exe = Util.join_path(install, sd, "MSBuild.exe")
        if Util.is_file(exe) then
            return Util.normalize_path(exe)
        end
        local exe_amd64 = Util.join_path(install, sd, "amd64", "MSBuild.exe")
        if Util.is_file(exe_amd64) then
            return Util.normalize_path(exe_amd64)
        end
    end
    return nil
end

local SENTINEL = "===MSVC_DEVENV_BEGIN==="

-- Build the command string for cmd.exe. We use io.popen below, which
-- launches `cmd.exe /c "<this string>"` via MSVCRT — bypassing libuv's
-- argv-escape, so the inner quotes around the vcvarsall path survive
-- cmd.exe's standard /c quote-stripping rule.
local function build_command(vcvarsall, arch, vcvars_ver, winsdk)
    local args = { arch }
    if winsdk and winsdk ~= "" then
        args[#args + 1] = winsdk
    end
    if vcvars_ver and vcvars_ver ~= "" then
        args[#args + 1] = "-vcvars_ver=" .. vcvars_ver
    end
    return ("call \"%s\" %s 2>&1 && echo %s && set"):format(
        vcvarsall,
        table.concat(args, " "),
        SENTINEL
    )
end

local function parse_env(stdout)
    local env = {}
    local saw_sentinel = false
    for line in stdout:gmatch("[^\r\n]+") do
        if not saw_sentinel then
            if line:find(SENTINEL, 1, true) then
                saw_sentinel = true
            end
        else
            local k, v = line:match("^([^=]+)=(.*)$")
            if k and v then
                local kept = KEEP_SET[k:upper()]
                if kept then
                    env[kept] = v
                end
            end
        end
    end
    return env
end

--- Resolve the dev-prompt env for a (install, arch, vcvars_ver, winsdk)
--- tuple. Cached. Returns the env table or nil + error string.
function M.resolve(opts)
    opts = opts or {}
    local install = opts.install
    local arch = opts.arch or "x64"
    local vcvars_ver = opts.vcvars_ver
    local winsdk = opts.winsdk
    if not install or install == "" then
        return nil, "no VS install path"
    end

    local key = cache_key(install, arch, vcvars_ver, winsdk)
    if cache[key] then
        return cache[key], nil
    end

    local vcvarsall = M.find_vcvarsall(install)
    if not vcvarsall then
        return nil, "vcvarsall.bat not found under " .. install
    end

    local cmdstr = build_command(vcvarsall, arch, vcvars_ver, winsdk)
    Log:debug("devenv: cmd /c %s", cmdstr)
    -- io.popen → MSVCRT `_popen` → CreateProcess with the literal
    -- `cmd.exe /c "<cmdstr>"` cmdline. No libuv argv-escaping in
    -- between, so cmd.exe's `/c` quote-stripping leaves our inner
    -- `"<vcvarsall>"` quoting intact even when the path has spaces.
    local pipe, perr = io.popen(cmdstr, "r")
    if not pipe then
        return nil, "devenv: io.popen failed: " .. tostring(perr)
    end
    local stdout = pipe:read("*a") or ""
    local ok, _, code = pipe:close()
    if not ok then
        local tail = stdout:gsub("%s+$", "")
        if #tail > 400 then
            tail = "..." .. tail:sub(-400)
        end
        return nil,
            ("vcvarsall failed (exit %s): %s"):format(
                tostring(code or "?"),
                tail
            )
    end
    local env = parse_env(stdout)
    if not next(env) then
        return nil, "devenv: no environment captured (vcvarsall output empty)"
    end
    cache[key] = env
    return env, nil
end

function M.clear_cache()
    cache = {}
end

return M
