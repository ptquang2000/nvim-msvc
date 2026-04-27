-- msvc.commands — `:Msvc <subcommand> ...` dispatcher and completion.

local Config = require("msvc.config")
local Discover = require("msvc.discover")
local VsWhere = require("msvc.vswhere")
local Util = require("msvc.util")
local Log = require("msvc.log")

local M = {}

local SUBCOMMANDS = {}

---@param msvc Msvc
local function format_status(msvc)
    local prof = msvc:active_profile()
    local lines = {}
    lines[#lines + 1] = "solution = " .. (msvc.solution or "<none>")
    lines[#lines + 1] = "project  = " .. (msvc.project or "<none>")
    if msvc.install then
        local inst = msvc.install
        lines[#lines + 1] = ("install  = %s (%s)"):format(
            inst.displayName or "?",
            inst.installationVersion or "?"
        )
        lines[#lines + 1] = "path     = " .. (inst.installationPath or "?")
    else
        lines[#lines + 1] = "install  = <unresolved>"
    end
    if msvc.config.settings.compile_commands then
        local cc = msvc.config.settings.compile_commands
        lines[#lines + 1] = "compile_commands"
        for _, k in ipairs({
            "enabled",
            "builddir",
            "outdir",
            "merge",
            "deduplicate",
        }) do
            if cc[k] ~= nil then
                lines[#lines + 1] = ("  %s = %s"):format(k, vim.inspect(cc[k]))
            end
        end
    end
    if not prof then
        lines[#lines + 1] = "profile  = <none>"
    else
        lines[#lines + 1] = "profile  = " .. (msvc.profile_name or "?")
        local keys = {}
        for k, _ in pairs(prof) do
            keys[#keys + 1] = k
        end
        table.sort(keys)
        for _, k in ipairs(keys) do
            lines[#lines + 1] = ("  %s = %s"):format(k, vim.inspect(prof[k]))
        end
    end
    return lines
end

local function print_lines(lines)
    for _, l in ipairs(lines) do
        vim.api.nvim_echo({ { l } }, false, {})
    end
end

---@param msvc Msvc
SUBCOMMANDS.status = {
    desc = "show active solution / project / profile / install",
    run = function(msvc)
        msvc:resolve_install()
        print_lines(format_status(msvc))
    end,
}

SUBCOMMANDS.build = {
    desc = "build the active target ([target] = MSBuild /t: argument)",
    run = function(msvc, args)
        msvc:build(args[1])
    end,
}

SUBCOMMANDS.rebuild = {
    desc = "rebuild the active target",
    run = function(msvc)
        msvc:rebuild()
    end,
}

SUBCOMMANDS.clean = {
    desc = "clean the active target",
    run = function(msvc)
        msvc:clean()
    end,
}

SUBCOMMANDS.cancel = {
    desc = "cancel an in-flight build",
    run = function(msvc)
        msvc:cancel()
    end,
}

SUBCOMMANDS.discover = {
    desc = "re-scan cwd for a .sln",
    run = function(msvc)
        local sln = msvc:discover_solution()
        if sln then
            Log:info(
                "msvc: solution = %s (%d projects)",
                sln,
                #msvc.solution_projects
            )
        else
            Log:warn("msvc: no .sln found in or above %s", vim.fn.getcwd())
        end
    end,
}

SUBCOMMANDS.profile = {
    desc = "switch active profile (no arg → list)",
    run = function(msvc, args)
        if #args == 0 then
            local names = Config.list_profile_names(msvc.config)
            print_lines({
                ("profiles (%d): %s"):format(#names, table.concat(names, ", ")),
            })
            print_lines({ "active = " .. (msvc.profile_name or "<none>") })
            return
        end
        if msvc:set_profile(args[1]) then
            Log:info("msvc: profile = %s", args[1])
        end
    end,
    complete = function(msvc, _arglead)
        return Config.list_profile_names(msvc.config)
    end,
}

SUBCOMMANDS.project = {
    desc = "pin a .vcxproj as the build target ('-' clears)",
    run = function(msvc, args)
        if #args == 0 then
            print_lines({ "project = " .. (msvc.project or "<none>") })
            return
        end
        if args[1] == "-" or args[1] == "none" then
            msvc:set_project(nil)
            Log:info("msvc: cleared pinned project")
            return
        end
        if msvc:set_project(args[1]) then
            Log:info("msvc: project = %s", msvc.project)
        end
    end,
    complete = function(msvc, _arglead)
        local out = {}
        for _, entry in ipairs(msvc.solution_projects or {}) do
            out[#out + 1] = entry.name
        end
        table.sort(out)
        return out
    end,
}

SUBCOMMANDS.log = {
    desc = "open the live build-log buffer",
    run = function()
        Log:show_build()
    end,
}

local function field_completions(msvc, field)
    local prof = msvc:active_profile() or {}
    if field == "configuration" or field == "platform" then
        local d = Discover.discover_targets(msvc.solution, msvc.project)
        if field == "configuration" then
            return d.configurations
        end
        return d.platforms
    elseif field == "arch" then
        return { "x86", "x64", "arm", "arm64" }
    elseif field == "vs_version" then
        local out = { "latest", "2017", "2019", "2022" }
        local ok, installs = pcall(VsWhere.list_installations, {
            vswhere_path = prof.vswhere_path,
            vs_prerelease = true,
        })
        if ok and type(installs) == "table" then
            local seen = {}
            for _, v in ipairs(out) do
                seen[v] = true
            end
            for _, inst in ipairs(installs) do
                local v = inst.installationVersion
                if v and not seen[v] then
                    seen[v] = true
                    out[#out + 1] = v
                end
            end
        end
        return out
    elseif field == "vs_prerelease" then
        return { "true", "false" }
    elseif field == "vs_products" then
        return {
            "Microsoft.VisualStudio.Product.Community",
            "Microsoft.VisualStudio.Product.Professional",
            "Microsoft.VisualStudio.Product.Enterprise",
            "Microsoft.VisualStudio.Product.BuildTools",
        }
    elseif field == "vcvars_ver" then
        if not msvc.install then
            pcall(msvc.resolve_install, msvc)
        end
        local install = msvc.install
        if not install or not install.installationPath then
            return {}
        end
        local root =
            Util.join_path(install.installationPath, "VC", "Tools", "MSVC")
        local out = {}
        if Util.is_dir(root) then
            for _, p in ipairs(vim.fn.globpath(root, "*", true, true)) do
                if Util.is_dir(p) then
                    out[#out + 1] = Util.basename(p)
                end
            end
            table.sort(out, function(a, b)
                return a > b
            end)
        end
        return out
    elseif field == "winsdk" then
        local out = {}
        local roots = {
            "C:\\Program Files (x86)\\Windows Kits\\10\\Include",
            "C:\\Program Files\\Windows Kits\\10\\Include",
        }
        for _, r in ipairs(roots) do
            if Util.is_dir(r) then
                for _, p in ipairs(vim.fn.globpath(r, "*", true, true)) do
                    if Util.is_dir(p) then
                        local n = Util.basename(p)
                        if n:match("^10%.0%.") then
                            out[#out + 1] = n
                        end
                    end
                end
            end
        end
        table.sort(out, function(a, b)
            return a > b
        end)
        return out
    elseif field == "jobs" then
        return { "1", "2", "4", "6", "8", "12", "16" }
    end
    return {}
end

local function parse_value(field, raw)
    if field == "jobs" then
        local n = tonumber(raw)
        if not n then
            error(("`jobs` expects a number, got %q"):format(raw), 0)
        end
        return n
    elseif field == "vs_prerelease" then
        if raw == "true" then
            return true
        end
        if raw == "false" then
            return false
        end
        error(("`vs_prerelease` expects true|false, got %q"):format(raw), 0)
    elseif
        field == "msbuild_args"
        or field == "vs_products"
        or field == "vs_requires"
    then
        local out = {}
        for tok in raw:gmatch("%S+") do
            out[#out + 1] = tok
        end
        return out
    end
    return raw
end

SUBCOMMANDS.update = {
    desc = "override a profile field for this session (`<field> <value>`)",
    run = function(msvc, args)
        if #args < 2 then
            Log:warn("usage: :Msvc update <field> <value>")
            return
        end
        local field = args[1]
        local raw = table.concat(args, " ", 2)
        local found = false
        for _, k in ipairs(Config.PROFILE_FIELDS) do
            if k == field then
                found = true
                break
            end
        end
        if not found then
            Log:error("msvc: unknown profile field %q", field)
            return
        end
        local ok, value = pcall(parse_value, field, raw)
        if not ok then
            Log:error("msvc: %s", tostring(value))
            return
        end
        msvc:set_override(field, value)
        Log:info("msvc: %s = %s", field, vim.inspect(value))
    end,
    complete = function(msvc, _arglead, args)
        if #args == 0 then
            return Config.PROFILE_FIELDS
        end
        return field_completions(msvc, args[1])
    end,
}

SUBCOMMANDS.help = {
    desc = "list subcommands",
    run = function()
        local names = {}
        for k, _ in pairs(SUBCOMMANDS) do
            names[#names + 1] = k
        end
        table.sort(names)
        local lines = { ":Msvc <subcommand> [args]", "" }
        for _, k in ipairs(names) do
            lines[#lines + 1] = ("  %-10s %s"):format(
                k,
                SUBCOMMANDS[k].desc or ""
            )
        end
        print_lines(lines)
    end,
}

local function complete(msvc, arglead, cmdline, _cursorpos)
    local parts = {}
    for tok in cmdline:gmatch("%S+") do
        parts[#parts + 1] = tok
    end
    -- parts[1] is "Msvc"; parts[2] is the subcommand
    local trailing_space = cmdline:sub(-1) == " "
    if
        (#parts == 1 and trailing_space) or (#parts == 2 and not trailing_space)
    then
        local out = {}
        for k, _ in pairs(SUBCOMMANDS) do
            if k:find("^" .. vim.pesc(arglead)) then
                out[#out + 1] = k
            end
        end
        table.sort(out)
        return out
    end
    local sub = parts[2]
    local cmd = sub and SUBCOMMANDS[sub]
    if not cmd or type(cmd.complete) ~= "function" then
        return {}
    end
    -- args = everything after the subcommand
    local args = {}
    for i = 3, #parts do
        args[#args + 1] = parts[i]
    end
    if not trailing_space and #args > 0 then
        args[#args] = nil -- don't include the in-progress argument
    end
    local candidates = cmd.complete(msvc, arglead, args) or {}
    local out = {}
    for _, c in ipairs(candidates) do
        if c:find("^" .. vim.pesc(arglead)) then
            out[#out + 1] = c
        end
    end
    return out
end

function M.setup(msvc)
    vim.api.nvim_create_user_command("Msvc", function(opts)
        local args = opts.fargs
        if #args == 0 then
            SUBCOMMANDS.help.run(msvc, {})
            return
        end
        local sub = args[1]
        local cmd = SUBCOMMANDS[sub]
        if not cmd then
            Log:error("msvc: unknown subcommand %q", sub)
            return
        end
        local rest = {}
        for i = 2, #args do
            rest[#rest + 1] = args[i]
        end
        local ok, err = pcall(cmd.run, msvc, rest)
        if not ok then
            Log:error("msvc: %s", tostring(err))
        end
    end, {
        nargs = "*",
        desc = "Visual Studio MSBuild driver",
        complete = function(arglead, cmdline, cursorpos)
            return complete(msvc, arglead, cmdline, cursorpos)
        end,
    })
end

M._SUBCOMMANDS = SUBCOMMANDS
M._format_status = format_status
M._complete = complete

return M
