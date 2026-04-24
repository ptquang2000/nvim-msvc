local M = {}
local msvc = require("msvc")
local Log = require("msvc.log")

---@alias MsvcSubcommand { impl: fun(args: string[], opts: table), complete: (fun(arglead: string, cmdline: string, pos: integer): string[])|nil, desc: string|nil }

---@type table<string, MsvcSubcommand>
local subcommands = {}

local function startswith_filter(candidates, arglead)
    return vim.tbl_filter(function(s)
        return vim.startswith(s, arglead)
    end, candidates)
end

-- Property → expected value type. The two tables are disjoint by design:
-- profile entries hold MSBuild parameters, resolve entries hold dev-env
-- parameters. `:Msvc update <prop> <val>` routes to the active profile or
-- the active resolve based on which set the property belongs to.
local PROFILE_PROPS = {
    configuration = "string",
    platform = "string",
    target = "string",
    verbosity = "string",
    max_cpu_count = "number",
    no_logo = "boolean",
    extra_args = "table",
    msbuild_args = "table",
    jobs = "number",
}

local RESOLVE_PROPS = {
    vs_version = "string",
    vs_prerelease = "boolean",
    vs_products = "table",
    vs_requires = "table",
    vswhere_path = "string",
    vcvars_ver = "string",
    arch = "string",
    host_arch = "string",
}

-- Properties that live on the global runtime state rather than on any
-- profile or resolve entry. Updates to these don't require a profile or
-- resolve to be selected.
local STATE_PROPS = {
    install_path = "string",
}

-- Known value enumerations; used to drive 2nd-arg completion. Properties
-- not listed here fall through to no completion (free-form input).
local PROP_VALUES = {
    configuration = { "Debug", "Release", "RelWithDebInfo", "MinSizeRel" },
    platform = { "x64", "x86", "Win32", "ARM64", "arm64" },
    target = { "Build", "Rebuild", "Clean" },
    arch = { "x64", "x86", "arm64" },
    host_arch = { "x64", "x86", "arm64" },
    verbosity = { "quiet", "minimal", "normal", "detailed", "diagnostic" },
    no_logo = { "true", "false" },
    vs_prerelease = { "true", "false" },
    vs_version = { "latest", "16", "17" },
}

local function coerce_value(prop, expected_type, raw)
    if expected_type == "number" then
        local n = tonumber(raw)
        if not n then
            return nil, ("%s expects a number, got %q"):format(prop, raw)
        end
        return n
    elseif expected_type == "boolean" then
        local lo = tostring(raw):lower()
        if lo == "true" or lo == "1" or lo == "yes" or lo == "on" then
            return true
        end
        if lo == "false" or lo == "0" or lo == "no" or lo == "off" then
            return false
        end
        return nil, ("%s expects a boolean, got %q"):format(prop, raw)
    elseif expected_type == "table" then
        local t = {}
        for chunk in tostring(raw):gmatch("[^,]+") do
            local trimmed = (chunk:gsub("^%s+", ""):gsub("%s+$", ""))
            if trimmed ~= "" then
                t[#t + 1] = trimmed
            end
        end
        return t
    end
    return tostring(raw)
end

subcommands.build = {
    desc = "Build the active solution (or active project if one is selected)",
    impl = function(args)
        msvc:build({ target = args[1] })
    end,
    complete = function(arglead)
        return startswith_filter({ "Build", "Rebuild", "Clean" }, arglead)
    end,
}

subcommands.rebuild = {
    desc = "Run MSBuild with target=Rebuild",
    impl = function()
        msvc:build({ target = "Rebuild" })
    end,
}

subcommands.clean = {
    desc = "Run MSBuild with target=Clean",
    impl = function()
        msvc:build({ target = "Clean" })
    end,
}

subcommands.cancel = {
    desc = "Cancel the in-flight MSBuild invocation",
    impl = function()
        msvc:cancel_build()
    end,
}

subcommands.status = {
    desc = "Echo solution / project / profile / resolve / install snapshot",
    impl = function()
        msvc:status()
    end,
}

subcommands.log = {
    desc = "Open the in-memory plugin log buffer",
    impl = function()
        msvc:show_log()
    end,
}

subcommands.build_log = {
    desc = "Open the captured MSBuild output buffer",
    impl = function()
        msvc:show_build_log()
    end,
}

subcommands.profile = {
    desc = "Set (or show) active named profile from config",
    impl = function(args)
        if args[1] then
            msvc:set_profile(args[1])
        else
            Log:info(
                "profile=%s",
                tostring(msvc.state.profile or "<none>")
            )
        end
    end,
    complete = function(arglead)
        local names = {}
        for k, v in pairs(msvc.config or {}) do
            if
                type(v) == "table"
                and k ~= "settings"
                and k ~= "default"
                and k ~= "resolves"
            then
                names[#names + 1] = k
            end
        end
        table.sort(names)
        return startswith_filter(names, arglead)
    end,
}

subcommands.resolve = {
    desc = "Set (or show) active named resolve from config.resolves",
    impl = function(args)
        if args[1] then
            msvc:set_resolve(args[1])
        else
            Log:info(
                "resolve=%s",
                tostring(msvc.state.resolve or "<none>")
            )
        end
    end,
    complete = function(arglead)
        local names = {}
        local resolves = (msvc.config or {}).resolves or {}
        for k, v in pairs(resolves) do
            if type(v) == "table" then
                names[#names + 1] = k
            end
        end
        table.sort(names)
        return startswith_filter(names, arglead)
    end,
}

subcommands.update = {
    desc = "Override a property on the active profile or resolve",
    impl = function(args)
        local prop = args[1]
        if not prop or prop == "" then
            Log:error("usage: :Msvc update <property> <value>")
            return
        end
        local kind, expected
        if PROFILE_PROPS[prop] then
            kind = "profile"
            expected = PROFILE_PROPS[prop]
        elseif RESOLVE_PROPS[prop] then
            kind = "resolve"
            expected = RESOLVE_PROPS[prop]
        elseif STATE_PROPS[prop] then
            kind = "state"
            expected = STATE_PROPS[prop]
        else
            Log:error("update: unknown property %q", prop)
            return
        end
        -- Join args[2..] so users can pass space-separated MSBuild flags
        -- (or anything else) without quoting.
        local raw
        if #args >= 2 then
            raw = table.concat(args, " ", 2)
        end
        if raw == nil or raw == "" then
            Log:error("usage: :Msvc update %s <value>", prop)
            return
        end
        local value, err = coerce_value(prop, expected, raw)
        if err then
            Log:error("update: %s", err)
            return
        end
        if kind == "profile" then
            local name = msvc.state:profile_name()
            if not name then
                Log:error(
                    "update: no profile selected — use `:Msvc profile <name>` first"
                )
                return
            end
            msvc.profile_overrides = msvc.profile_overrides or {}
            msvc.profile_overrides[name] = msvc.profile_overrides[name] or {}
            msvc.profile_overrides[name][prop] = value
            Log:info(
                "profile[%s].%s = %s (override)",
                name,
                prop,
                vim.inspect(value, { newline = "", indent = "" })
            )
        elseif kind == "resolve" then
            local name = msvc.state:resolve_name()
            if not name then
                Log:error(
                    "update: no resolve selected — use `:Msvc resolve <name>` first"
                )
                return
            end
            msvc.resolve_overrides = msvc.resolve_overrides or {}
            msvc.resolve_overrides[name] = msvc.resolve_overrides[name] or {}
            msvc.resolve_overrides[name][prop] = value
            Log:info(
                "resolves[%s].%s = %s (override)",
                name,
                prop,
                vim.inspect(value, { newline = "", indent = "" })
            )
        else
            msvc.state:set(prop, value)
            Log:info(
                "state.%s = %s",
                prop,
                vim.inspect(value, { newline = "", indent = "" })
            )
        end
    end,
    complete = function(arglead, cmdline, _pos)
        local words = vim.split(cmdline, "%s+", { trimempty = true })
        -- Compute which positional arg is currently being typed.
        --   word[1]=Msvc, word[2]=update, word[3]=property, word[4..]=value
        local arg_index
        if arglead == "" then
            arg_index = #words - 1
        else
            arg_index = #words - 2
        end
        if arg_index <= 1 then
            local names = {}
            for k in pairs(PROFILE_PROPS) do
                names[#names + 1] = k
            end
            for k in pairs(RESOLVE_PROPS) do
                names[#names + 1] = k
            end
            for k in pairs(STATE_PROPS) do
                names[#names + 1] = k
            end
            table.sort(names)
            return startswith_filter(names, arglead)
        elseif arg_index == 2 then
            local prop = words[3]
            if prop == "install_path" then
                local installs = (msvc.vs_installations or {})
                local paths = {}
                for _, inst in ipairs(installs) do
                    if type(inst.installationPath) == "string" then
                        paths[#paths + 1] = inst.installationPath
                    end
                end
                table.sort(paths)
                return startswith_filter(paths, arglead)
            end
            local vals = prop and PROP_VALUES[prop]
            if vals then
                return startswith_filter(vals, arglead)
            end
        end
        return {}
    end,
}

subcommands.project = {
    desc = "Pin the active project (subset of the loaded solution); empty/<solution> clears to build the full .sln",
    impl = function(args)
        local name = args[1]
        if not name or name == "" or name == "<solution>" then
            msvc:set_project(nil)
            Log:info("project cleared — build will target the full solution")
            return
        end
        msvc:set_project(name)
    end,
    complete = function(arglead)
        local names = { "<solution>" }
        for _, p in ipairs(msvc.solution_projects or {}) do
            names[#names + 1] = p.name
        end
        return startswith_filter(names, arglead)
    end,
}

subcommands.discover = {
    desc = "Re-scan cwd for the parent .sln and refresh the project list",
    impl = function()
        local s = msvc:auto_discover()
        Log:info(
            "solution=%s (%d projects)",
            tostring(s or "<none>"),
            #(msvc.solution_projects or {})
        )
    end,
}

subcommands.health = {
    desc = "Run :checkhealth msvc",
    impl = function()
        vim.cmd("checkhealth msvc")
    end,
}

-- Guards for build/compile/generate. Each command requires a different
-- subset of the (profile, resolve) selection — log a clear error and
-- return false when the prerequisite is missing.
local function require_profile()
    if not msvc.state:profile_name() then
        Log:error("no profile selected — use `:Msvc profile <name>`")
        return false
    end
    return true
end

local function require_resolve()
    if not msvc.state:resolve_name() then
        Log:error("no resolve selected — use `:Msvc resolve <name>`")
        return false
    end
    return true
end

-- Ported from msbuilder.lua :MSCompile / :MSGenerate. The singleton does
-- not yet implement these methods; surface them as known subcommands so
-- the dispatcher exposes the full surface area and logs a clear warning
-- instead of dying with `unknown subcommand`. They become live as soon
-- as `Msvc:compile_current_file` / `Msvc:generate_compile_commands` land.
subcommands.compile = {
    desc = "Compile the current buffer's source file (not yet wired)",
    impl = function()
        if not require_resolve() then
            return
        end
        if type(msvc.compile_current_file) == "function" then
            msvc:compile_current_file()
        else
            Log:warn("compile: not yet implemented on the singleton")
        end
    end,
}

subcommands.generate = {
    desc = "Generate compile_commands.json (not yet wired)",
    impl = function()
        if not require_resolve() then
            return
        end
        if type(msvc.generate_compile_commands) == "function" then
            msvc:generate_compile_commands()
        else
            Log:warn("generate: not yet implemented on the singleton")
        end
    end,
}

subcommands.help = {
    desc = "List every :Msvc subcommand",
    impl = function()
        local names = {}
        for k in pairs(subcommands) do
            names[#names + 1] = k
        end
        table.sort(names)
        Log:info("Subcommands: %s", table.concat(names, ", "))
    end,
}

---@param opts table  -- :command callback opts (fargs, bang, ...)
function M.dispatch(opts)
    local fargs = opts.fargs or {}
    local sub = fargs[1]
    if not sub then
        return subcommands.help.impl({}, opts)
    end
    local cmd = subcommands[sub]
    if not cmd then
        Log:error("unknown subcommand: %s", sub)
        return
    end
    local rest = {}
    for i = 2, #fargs do
        rest[#rest + 1] = fargs[i]
    end
    cmd.impl(rest, opts)
end

---@param arglead string
---@param cmdline string
---@param pos integer
---@return string[]
function M.complete(arglead, cmdline, pos)
    local words = vim.split(cmdline, "%s+", { trimempty = true })
    -- words[1] is "Msvc" (possibly with leading bang / range stripped by
    -- nvim already). When the user has not yet finished typing the
    -- subcommand we are still on word 2 → return subcommand names.
    local typing_subcommand = #words <= 1 or (#words == 2 and arglead ~= "")
    if typing_subcommand then
        local names = {}
        for k in pairs(subcommands) do
            if vim.startswith(k, arglead) then
                names[#names + 1] = k
            end
        end
        table.sort(names)
        return names
    end
    local sub = words[2]
    local cmd = subcommands[sub]
    if cmd and cmd.complete then
        return cmd.complete(arglead, cmdline, pos)
    end
    return {}
end

function M.register()
    vim.api.nvim_create_user_command("Msvc", function(opts)
        M.dispatch(opts)
    end, {
        nargs = "*",
        bang = true,
        desc = "MSVC build commands (use :Msvc help)",
        complete = function(a, c, p)
            return M.complete(a, c, p)
        end,
    })
end

-- Back-compat alias for the §1.5 plan wording.
M.setup = M.register

-- Test seam: lets specs poke individual subcommands without re-registering.
M.test = { subcommands = subcommands }

return M
