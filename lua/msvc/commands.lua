local M = {}
local msvc = require("msvc")
local Log = require("msvc.log")
local Config = require("msvc.config")

---@alias MsvcSubcommand { impl: fun(args: string[], opts: table), complete: (fun(arglead: string, cmdline: string, pos: integer): string[])|nil, desc: string|nil }

---@type table<string, MsvcSubcommand>
local subcommands = {}

local function startswith_filter(candidates, arglead)
    return vim.tbl_filter(function(s)
        return vim.startswith(s, arglead)
    end, candidates)
end

-- Property → expected value type. A profile carries the full field set
-- (MSBuild parameters and dev-env parameters together); `:Msvc update
-- <prop> <val>` writes overrides to the active profile.
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
    vs_version = "string",
    vs_prerelease = "boolean",
    vs_products = "table",
    vs_requires = "table",
    vswhere_path = "string",
    vcvars_ver = "string",
    winsdk = "string",
    vcvars_spectre_libs = "string",
    arch = "string",
    host_arch = "string",
}

-- Properties that live on the global runtime state rather than on any
-- profile entry. Updates to these don't require a profile to be selected.
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
    vcvars_spectre_libs = { "spectre", "spectre_load", "spectre_load_cf" },
}

-- Resolve the active VS install path for dynamic completion. Falls back
-- to the first entry vswhere returned so completion still works before
-- a profile has been selected.
local function active_install_path()
    local p = msvc.state and msvc.state.install_path
    if type(p) == "string" and p ~= "" then
        return p
    end
    local installs = msvc.vs_installations or {}
    for _, inst in ipairs(installs) do
        if type(inst.installationPath) == "string" then
            return inst.installationPath
        end
    end
    return nil
end

local function list_dir_entries(dir)
    local out = {}
    local ok, scanner = pcall(vim.loop.fs_scandir, dir)
    if not ok or not scanner then
        return out
    end
    while true do
        local name, t = vim.loop.fs_scandir_next(scanner)
        if not name then
            break
        end
        if t == "directory" or t == "link" then
            out[#out + 1] = name
        end
    end
    return out
end

-- Enumerate installed MSVC toolsets under <install>\VC\Tools\MSVC\<ver>.
-- Returns the long form (e.g. "14.39.33519") plus the short major.minor
-- form ("14.39") that vcvarsall accepts.
local function list_vcvars_ver()
    local install = active_install_path()
    if not install then
        return {}
    end
    local seen = {}
    local results = {}
    local function add(v)
        if v and v ~= "" and not seen[v] then
            seen[v] = true
            results[#results + 1] = v
        end
    end
    for _, name in ipairs(list_dir_entries(install .. "\\VC\\Tools\\MSVC")) do
        add(name)
        local short = name:match("^(%d+%.%d+)")
        add(short)
    end
    table.sort(results)
    return results
end

-- Enumerate installed Windows SDKs via the registry. The Installed Roots
-- key lists every Windows 10/11 SDK as a subkey (e.g. 10.0.22621.0) and
-- exposes the install root as the `KitsRoot10` value. We fall back to
-- scanning the install root's Include directory if the registry walk
-- comes up empty (e.g. SDK installed to a non-default location whose
-- registry write was skipped).
local WINSDK_REG_KEYS = {
    "HKLM\\SOFTWARE\\Microsoft\\Windows Kits\\Installed Roots",
    "HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows Kits\\Installed Roots",
}

local function reg_query(key)
    local res = vim.system({ "reg.exe", "query", key, "/s" }, { text = true })
        :wait()
    if res.code ~= 0 then
        return nil
    end
    return res.stdout or ""
end

local function list_winsdk()
    local seen = {}
    local results = {}
    local roots = {}
    local function add_version(v)
        if v and v ~= "" and not seen[v] then
            seen[v] = true
            results[#results + 1] = v
        end
    end
    local function add_root(p)
        if not p or p == "" then
            return
        end
        p = p:gsub("[\\/]+$", "")
        roots[p] = true
    end
    for _, key in ipairs(WINSDK_REG_KEYS) do
        local out = reg_query(key)
        if out then
            for line in out:gmatch("[^\r\n]+") do
                -- Subkey lines: "...\Installed Roots\10.0.22621.0"
                local ver = line:match("Installed Roots\\(%d[%w%.]*)$")
                if ver then
                    add_version(ver)
                end
                -- Value lines: "    KitsRoot10    REG_SZ    C:\...\Windows Kits\10\"
                local root = line:match("KitsRoot%w*%s+REG_%w+%s+(.+)$")
                if root then
                    add_root((root:gsub("%s+$", "")))
                end
            end
        end
    end
    -- Filesystem fallback: registry may be missing entries when an SDK
    -- was installed without admin rights or stripped down by a CI image.
    if vim.tbl_isempty(roots) then
        local pf86 = os.getenv("ProgramFiles(x86)")
        local pf = os.getenv("ProgramFiles")
        if pf86 then
            roots[pf86 .. "\\Windows Kits\\10"] = true
        end
        if pf then
            roots[pf .. "\\Windows Kits\\10"] = true
        end
    end
    for root in pairs(roots) do
        for _, name in ipairs(list_dir_entries(root .. "\\Include")) do
            if name:match("^%d") then
                add_version(name)
            end
        end
    end
    table.sort(results)
    return results
end

local PROP_VALUE_PROVIDERS = {
    vcvars_ver = list_vcvars_ver,
    winsdk = list_winsdk,
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
    desc = "Echo solution / project / install snapshot plus the active profile fields",
    impl = function()
        msvc:status()
    end,
}

subcommands.log = {
    desc = "Open the build log (live tail while building, last build output otherwise)",
    impl = function()
        msvc.log:show_build()
    end,
}

subcommands.profile = {
    desc = "Set (or show) active named profile from config.profiles",
    impl = function(args)
        if args[1] then
            msvc:set_profile(args[1])
        else
            local name = msvc.state:profile_name()
            if name then
                msvc:log_profile(name)
            else
                Log:info("profile = <none>")
            end
        end
    end,
    complete = function(arglead)
        return startswith_filter(
            Config.list_profile_names(msvc.config or {}),
            arglead
        )
    end,
}

subcommands.update = {
    desc = "Override a property on the active profile",
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
            local provider = prop and PROP_VALUE_PROVIDERS[prop]
            if provider then
                local ok, dyn = pcall(provider)
                if ok and type(dyn) == "table" then
                    return startswith_filter(dyn, arglead)
                end
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

-- Guard for build/compile. These require only an active profile;
-- the merged profile view (engine defaults ⨉ root profile ⨉ named
-- profile) supplies all dev-env parameters needed by `Msvc:resolve`.
local function require_profile()
    if not msvc.state:profile_name() then
        Log:error("no profile selected — use `:Msvc profile <name>`")
        return false
    end
    return true
end

-- Ported from msbuilder.lua :MSCompile. The singleton does not yet
-- implement this method; surface it as a known subcommand so the
-- dispatcher exposes the full surface area and logs a clear warning
-- instead of dying with `unknown subcommand`. It becomes live as soon
-- as `Msvc:compile_current_file` lands.
subcommands.compile = {
    desc = "Compile the current buffer's source file (not yet wired)",
    impl = function()
        if not require_profile() then
            return
        end
        if type(msvc.compile_current_file) == "function" then
            msvc:compile_current_file()
        else
            Log:warn("compile: not yet implemented on the singleton")
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
