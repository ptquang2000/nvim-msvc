-- :checkhealth msvc
local Util = require("msvc.util")
local VsWhere = require("msvc.vswhere")
local DevEnv = require("msvc.devenv")
local Config = require("msvc.config")
local CompileCommands = require("msvc.compile_commands")

local H = vim.health or require("health")
local M = {}

local function start(s)
    (H.start or H.report_start)(s)
end
local function ok(m)
    (H.ok or H.report_ok)(m)
end
local function info(m)
    (H.info or H.report_info)(m)
end
local function warn(m, a)
    (H.warn or H.report_warn)(m, a)
end
local function err(m, a)
    (H.error or H.report_error)(m, a)
end

local function check_environment()
    start("nvim-msvc: environment")
    if Util.is_windows() then
        ok("running on Windows")
    else
        err("nvim-msvc only supports Windows")
    end
    if vim.fn.has("nvim-0.10") == 1 then
        ok("Neovim 0.10+ OK")
    else
        err("Neovim 0.10+ required (uses vim.system)")
    end
end

local function check_config(msvc)
    start("nvim-msvc: configuration")
    local cfg_ok, cfg_err = pcall(Config.validate, msvc.config)
    if cfg_ok then
        ok("configuration validates")
    else
        err("configuration validation failed: " .. tostring(cfg_err))
    end
end

local function check_toolchain(msvc)
    start("nvim-msvc: Visual Studio toolchain")
    if not Util.is_windows() then
        return
    end
    local cfg = (msvc.config or {}).settings or {}
    local exe = VsWhere.find_vswhere({ vswhere_path = cfg.vswhere_path })
    if exe then
        ok("vswhere.exe: " .. exe)
    else
        warn("vswhere.exe not found")
    end
    local install = msvc:resolve_install({ refresh = true })
    if install and install.installationPath then
        ok(
            ("Visual Studio install: %s (%s)"):format(
                install.installationPath,
                install.installationVersion or "?"
            )
        )
        local msbuild = DevEnv.find_msbuild(install.installationPath)
        if msbuild then
            ok("MSBuild.exe: " .. msbuild)
        else
            err("MSBuild.exe not found under " .. install.installationPath)
        end
    else
        warn("no Visual Studio installation resolved", {
            "Open the msvc:// buffer and set vs_version, or run :Msvc.",
        })
    end
end

local function check_state(msvc)
    start("nvim-msvc: state")
    local s = msvc.settings or {}
    if msvc.solution and Util.is_file(msvc.solution) then
        ok("solution: " .. msvc.solution)
        info(("solution projects: %d"):format(#(msvc.solution_projects or {})))
    elseif msvc.solution then
        err("solution path no longer exists: " .. msvc.solution)
    else
        warn("no .sln selected", { "Open a .sln buffer or use :Msvc to open the build buffer." })
    end
    if msvc.project then
        if Util.is_file(msvc.project) then
            ok("pinned project: " .. msvc.project)
        else
            err("pinned project missing: " .. msvc.project)
        end
    else
        info("no pinned project — builds target the .sln")
    end
    if s.configuration and s.platform then
        ok(
            ("build settings: %s|%s (arch=%s, vs=%s)"):format(
                s.configuration,
                s.platform,
                s.arch or "x64",
                s.vs_version or "latest"
            )
        )
    else
        warn("configuration/platform not set", {
            "Open :Msvc and set them with = then -.",
        })
    end
end

local function check_compile_commands(msvc)
    start("nvim-msvc: compile_commands.json")
    local cc = (msvc.config.settings or {}).compile_commands
    if not CompileCommands.is_enabled(cc) then
        info("disabled (settings.compile_commands.enabled = false)")
        return
    end
    CompileCommands.reset_cache()
    local exe = CompileCommands.find_extractor()
    if exe then
        ok(("extractor: %s (%s)"):format(CompileCommands.EXTRACTOR_BIN, exe))
    else
        warn(("`%s` not found on PATH"):format(CompileCommands.EXTRACTOR_BIN), {
            "Install from https://github.com/microsoft/msbuild-extractor-sample",
        })
    end
end

function M.check()
    local ok_, msvc = pcall(require, "msvc")
    if not ok_ or type(msvc) ~= "table" then
        start("nvim-msvc")
        err("failed to load `msvc` singleton")
        return
    end
    check_environment()
    check_config(msvc)
    check_toolchain(msvc)
    check_state(msvc)
    check_compile_commands(msvc)
end

return M
