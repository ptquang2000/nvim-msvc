-- msvc.health: `:checkhealth msvc` implementation. Reports the user's
-- platform, Neovim version, vswhere / MSBuild discovery, current state
-- (active solution / project / profile / install_path), and the
-- compile_commands.json extractor configuration.

local Util = require("msvc.util")
local VsWhere = require("msvc.vswhere")
local DevEnv = require("msvc.devenv")
local Config = require("msvc.config")
local CompileCommands = require("msvc.compile_commands")

-- vim.health is the modern API (Neovim 0.10+); fall back to the legacy
-- `health` module name on older releases so the report still renders.
local H = vim.health or require("health")

local M = {}

local function start(section)
    if H.start then
        H.start(section)
    elseif H.report_start then
        H.report_start(section)
    end
end

local function ok(msg)
    if H.ok then
        H.ok(msg)
    else
        H.report_ok(msg)
    end
end

local function warn(msg, advice)
    if H.warn then
        H.warn(msg, advice)
    else
        H.report_warn(msg, advice)
    end
end

local function err(msg, advice)
    if H.error then
        H.error(msg, advice)
    elseif H.report_error then
        H.report_error(msg, advice)
    end
end

local function info(msg)
    if H.info then
        H.info(msg)
    elseif H.report_info then
        H.report_info(msg)
    end
end

-- Section: runtime environment -------------------------------------------

local function check_environment()
    start("nvim-msvc: environment")

    if Util.is_windows() then
        ok("running on Windows")
    else
        err(
            "nvim-msvc only supports Windows",
            { "Install/run Neovim on Windows to use this plugin." }
        )
    end

    if vim.fn.has("nvim-0.10") == 1 then
        ok(
            ("Neovim version OK (%s)"):format(
                tostring(vim.version and vim.version() or "")
            )
        )
    else
        err(
            "Neovim 0.10+ required (uses vim.system)",
            { "Upgrade Neovim to 0.10 or newer." }
        )
    end
end

-- Section: configuration -------------------------------------------------

local function check_config(msvc)
    start("nvim-msvc: configuration")

    local cfg_ok, cfg_err = pcall(Config.validate, msvc.config)
    if cfg_ok then
        ok("configuration validates")
    else
        err("configuration validation failed: " .. tostring(cfg_err))
    end

    local profiles = Config.list_profile_names(msvc.config or {})
    if #profiles == 0 then
        warn("no named profiles defined", {
            "Add at least one entry under `profiles` in setup() — e.g. `debug_x64 = { configuration = 'Debug', platform = 'x64' }`.",
        })
    else
        info(
            ("%d profile(s): %s"):format(
                #profiles,
                table.concat(profiles, ", ")
            )
        )
    end

    local active = msvc.state and msvc.state:profile_name()
    if active then
        ok(("active profile: %s"):format(active))
    else
        warn(
            "no active profile",
            { "Pick one with `:Msvc profile <name>` before building." }
        )
    end
end

-- Section: VS / MSBuild discovery ----------------------------------------

-- Resolve the Visual Studio install path the same way the build pipeline
-- does: state cache → vswhere latest. `install_path` is no longer a
-- user-facing config knob — `vs_version` + vswhere drives discovery.
local function resolve_install(msvc, profile, vswhere)
    local install = msvc.state and msvc.state.install_path
    if (not install or install == "") and vswhere then
        local inst = VsWhere.find_latest({
            vswhere_path = vswhere,
            vs_version = profile.vs_version,
            vs_prerelease = profile.vs_prerelease,
            vs_products = profile.vs_products,
            vs_requires = profile.vs_requires,
        })
        if inst and inst.installationPath then
            install = inst.installationPath
        end
    end
    return install
end

local function check_toolchain(msvc)
    start("nvim-msvc: Visual Studio toolchain")

    if not Util.is_windows() then
        return
    end

    local profile = Config.get_profile(
        msvc.config,
        msvc.state and msvc.state:profile_name()
    )
    local vswhere =
        VsWhere.find_vswhere({ vswhere_path = profile.vswhere_path })
    if vswhere then
        ok("vswhere.exe: " .. vswhere)
    else
        warn("vswhere.exe not found", {
            "Install Visual Studio 2017 Update 2+ (ships vswhere.exe), or set `vswhere_path` on your default profile to an explicit path.",
            "Default fallback: %ProgramFiles(x86)%\\Microsoft Visual Studio\\Installer\\vswhere.exe",
        })
    end

    local install = resolve_install(msvc, profile, vswhere)
    if install and install ~= "" then
        ok("Visual Studio install: " .. install)
        local msbuild = DevEnv.find_msbuild(install)
        if msbuild then
            ok("MSBuild.exe: " .. msbuild)
        else
            err("MSBuild.exe not found under " .. install, {
                "Confirm the *Desktop development with C++* workload is installed for that VS install.",
            })
        end
    else
        warn("no Visual Studio installation resolved yet", {
            "Install Visual Studio 2019/2022 with the *Desktop development with C++* workload.",
            "If multiple installs are present, set `vs_version` on your profile (e.g. `vs_version = '17'`) to disambiguate.",
            "If `vswhere.exe` lives in a non-standard location, set `vswhere_path` on your profile.",
        })
    end
end

-- Section: current state -------------------------------------------------

local function check_state(msvc)
    start("nvim-msvc: state")

    local s = msvc.state and msvc.state:get_snapshot() or {}
    if s.solution and s.solution ~= "" then
        if Util.is_file(s.solution) then
            ok("solution: " .. s.solution)
        else
            err(
                "solution path no longer exists: " .. s.solution,
                { "Run `:Msvc discover` to re-scan the current working tree." }
            )
        end
        local nprojects = #(msvc.solution_projects or {})
        info(("solution projects parsed: %d"):format(nprojects))
    else
        warn("no .sln pinned", {
            "`:cd` into a directory below a .sln, then run `:Msvc discover`.",
        })
    end

    if s.project and s.project ~= "" then
        if Util.is_file(s.project) then
            ok("pinned project: " .. s.project)
        else
            err("pinned project path missing: " .. s.project)
        end
    else
        info("no pinned project — `:Msvc build` targets the full solution")
    end
end

-- Section: compile_commands.json -----------------------------------------

-- Probe whether the extractor (`msbuild-extractor-sample`) will be able
-- to bootstrap MSBuild on this machine. Its `RegisterMSBuild` needs:
--   1) MSBuild.dll under <VS>\MSBuild\Current\Bin\{amd64,,x86}, OR
--   2) a .NET SDK (so MSBuildLocator's discovery fallback works).
-- With neither, the extractor crashes with hostfxr "No .NET SDKs were
-- found." Detecting both up front gives the user actionable advice
-- instead of a CLR stack trace at build time.
local function check_extractor_prereqs(install)
    if not install or install == "" then
        warn(
            "extractor MSBuild bootstrap not verified — no Visual Studio install resolved",
            {
                "Set `vs_version` on your profile, or ensure `vswhere.exe` returns a result.",
            }
        )
        return
    end

    local bin_dirs = {
        install .. "\\MSBuild\\Current\\Bin\\amd64",
        install .. "\\MSBuild\\Current\\Bin",
        install .. "\\MSBuild\\Current\\Bin\\x86",
        install .. "\\MSBuild\\Current\\Bin\\arm64",
    }
    local found
    for _, dir in ipairs(bin_dirs) do
        local exe = Util.normalize_path(dir .. "\\MSBuild.exe")
        local dll = Util.normalize_path(dir .. "\\Microsoft.Build.dll")
        if Util.is_file(exe) and Util.is_file(dll) then
            found = exe
            break
        end
    end
    if found then
        ok("extractor MSBuild (VS-bundled): " .. found)
        return
    end

    -- Fallback: a .NET 10+ SDK lets MSBuildLocator discover MSBuild on its own.
    local sdks = {}
    local older_sdks = {}
    local sys_ok, res = pcall(function()
        return vim.system({ "dotnet", "--list-sdks" }, { text = true }):wait()
    end)
    if sys_ok and type(res) == "table" and res.code == 0 and res.stdout then
        for line in tostring(res.stdout):gmatch("[^\r\n]+") do
            local v = line:match("^(%d+%.%d+%.%d+%S*)%s")
            if v then
                local major = tonumber(v:match("^(%d+)"))
                if major and major >= 10 then
                    table.insert(sdks, v)
                else
                    table.insert(older_sdks, v)
                end
            end
        end
    end

    if #sdks > 0 then
        ok(
            ("extractor will use .NET SDK discovery (%d .NET 10+ SDK(s): %s)"):format(
                #sdks,
                table.concat(sdks, ", ")
            )
        )
        return
    end

    local hints = {
        "msbuild-extractor-sample's RegisterMSBuild needs either a VS-bundled MSBuild (MSBuild.exe + Microsoft.Build.dll) under <VS>\\MSBuild\\Current\\Bin\\{amd64,,x86,arm64} or a .NET 10 SDK or later.",
        "Fix option 1 (recommended): install .NET 10 SDK or later from https://aka.ms/dotnet/download — then `dotnet --list-sdks` will show a 10.x.x (or newer) entry.",
        "Fix option 2: in Visual Studio Installer, Modify your VS 2022 install and ensure the *MSBuild* component (under C++ build tools / individual components) is checked, so MSBuild.exe and Microsoft.Build.dll land on disk.",
        "Until then, builds still work, but compile_commands.json generation will fail with `Unhandled exception ... hostfxr_resolve_sdk2 ... No .NET SDKs were found.`",
    }
    if #older_sdks > 0 then
        table.insert(
            hints,
            1,
            ("Detected .NET SDK(s) but none are version 10 or later: %s — these are not supported by the extractor."):format(
                table.concat(older_sdks, ", ")
            )
        )
    end

    local msg
    if #older_sdks > 0 then
        msg = "extractor will crash: no usable VS-bundled MSBuild under "
            .. install
            .. "\\MSBuild\\Current\\Bin\\{amd64,,x86,arm64} (need MSBuild.exe + Microsoft.Build.dll) and no .NET 10 SDK or later installed (older SDKs detected but unsupported)"
    else
        msg = "extractor will crash: no usable VS-bundled MSBuild under "
            .. install
            .. "\\MSBuild\\Current\\Bin\\{amd64,,x86,arm64} (need MSBuild.exe + Microsoft.Build.dll) and no .NET 10 SDK or later installed"
    end

    err(msg, hints)
end

local function check_compile_commands(msvc)
    start("nvim-msvc: compile_commands.json")

    local cc = msvc.config
        and msvc.config.settings
        and msvc.config.settings.compile_commands
    if not CompileCommands.is_enabled(cc) then
        info(
            "disabled — set `settings.compile_commands.enabled = true` to auto-generate compile_commands.json after :Msvc build"
        )
        return
    end

    -- Re-probe PATH so :checkhealth always reflects the current state
    -- rather than a stale cached miss from a previous setup() call.
    CompileCommands.reset_cache()
    local exe = CompileCommands.find_extractor()
    if exe then
        ok(("extractor: %s (%s)"):format(CompileCommands.EXTRACTOR_BIN, exe))
    else
        warn(("`%s` not found on PATH"):format(CompileCommands.EXTRACTOR_BIN), {
            "Install the tool from https://github.com/microsoft/msbuild-extractor-sample",
            "and ensure its executable is on PATH (the binary name must be `"
                .. CompileCommands.EXTRACTOR_BIN
                .. "`).",
            "compile_commands.json generation will be skipped until then; the build itself is unaffected.",
        })
    end

    if cc.outdir and cc.outdir ~= "" then
        if Util.is_dir(cc.outdir) then
            ok("outdir: " .. cc.outdir)
        else
            warn(
                "outdir does not exist (will be created on first build): "
                    .. cc.outdir
            )
        end
    else
        info("outdir: <unset> — defaults to the active .sln's directory")
    end

    if cc.builddir and cc.builddir ~= "" then
        if Util.is_dir(cc.builddir) then
            local Discover = require("msvc.discover")
            local n = #Discover.find_vcxprojs(cc.builddir, { max_files = 5000 })
            ok(("builddir: %s (%d *.vcxproj found)"):format(cc.builddir, n))
        else
            err("builddir does not exist: " .. cc.builddir, {
                "Set it to a directory containing out-of-source *.vcxproj files, or unset it.",
            })
        end
    else
        info("builddir: <unset> — only the active solution is extracted")
    end

    if Util.is_windows() then
        local profile = Config.get_profile(
            msvc.config,
            msvc.state and msvc.state:profile_name()
        )
        local vswhere =
            VsWhere.find_vswhere({ vswhere_path = profile.vswhere_path })
        check_extractor_prereqs(resolve_install(msvc, profile, vswhere))
    end
end

--- `:checkhealth msvc` entry point. Neovim auto-discovers this file.
function M.check()
    local ok_, msvc = pcall(require, "msvc")
    if not ok_ or type(msvc) ~= "table" then
        start("nvim-msvc")
        err(
            "failed to load `msvc` singleton",
            { "Make sure `require('msvc').setup({})` ran successfully." }
        )
        return
    end

    check_environment()
    check_config(msvc)
    check_toolchain(msvc)
    check_state(msvc)
    check_compile_commands(msvc)
end

return M
