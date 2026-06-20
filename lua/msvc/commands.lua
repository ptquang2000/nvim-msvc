-- msvc.commands — `:Msvc <subcommand>` dispatcher.
-- Subcommands: add, cancel, log. No-arg opens the buffer with gating dispatch.

local Log = require("msvc.log")
local Util = require("msvc.util")
local Discover = require("msvc.discover")

local M = {}

local SUBCOMMANDS = {}

local function add_and_activate(msvc, norm)
    local lower = norm:lower()
    local found = false
    for _, c in ipairs(msvc.solutions) do
        if c:lower() == lower then
            found = true
            break
        end
    end
    if not found then
        msvc.solutions[#msvc.solutions + 1] = norm
        table.sort(msvc.solutions)
    end
    if msvc:set_solution(norm) then
        Log:info(
            "msvc: solution = %s (%d projects)",
            msvc.solution,
            #msvc.solution_projects
        )
    end
end

SUBCOMMANDS.add = {
    desc = "add a .sln to registered solutions and select it",
    run = function(msvc, rest)
        local explicit_arg = rest and rest[1] ~= nil and rest[1] ~= ""

        if explicit_arg then
            local path = rest[1]
            if not path:match("%.sln$") then
                Log:error("msvc add: %q is not a .sln file", path)
                return
            end
            local norm = Util.normalize_path(path)
            if not norm or not Util.is_file(norm) then
                Log:error("msvc add: file not found: %s", path)
                return
            end
            add_and_activate(msvc, norm)
            return
        end

        -- No explicit arg: check current buffer
        local bufname = vim.api.nvim_buf_get_name(0)
        if bufname and bufname ~= "" and bufname:match("%.sln$") then
            local norm = Util.normalize_path(bufname)
            if not norm or not Util.is_file(norm) then
                Log:error("msvc add: file not found: %s", bufname)
                return
            end
            add_and_activate(msvc, norm)
            return
        end

        -- Discovery mode
        local cwd = vim.fn.getcwd()
        local found_slns = Discover.find_sln_files(cwd)
        local ok, err = pcall(require("msvc.ui").open, msvc, "add", found_slns)
        if not ok then
            Log:error("msvc: %s", tostring(err))
        end
    end,
}

SUBCOMMANDS.cancel = {
    desc = "cancel an in-flight build",
    run = function(msvc)
        msvc:cancel()
    end,
}

SUBCOMMANDS.log = {
    desc = "open the live build-log buffer",
    run = function()
        Log:show_build()
    end,
}

local function complete(msvc, arglead, cmdline, _cursorpos)
    local parts = {}
    for tok in cmdline:gmatch("%S+") do
        parts[#parts + 1] = tok
    end
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
    -- File completion for `add <path>`
    if
        (#parts == 2 and trailing_space and parts[2] == "add")
        or (#parts == 3 and not trailing_space and parts[2] == "add")
    then
        return vim.fn.getcompletion(arglead, "file")
    end
    return {}
end

function M.setup(msvc)
    vim.api.nvim_create_user_command("Msvc", function(opts)
        local args = opts.fargs
        if #args == 0 then
            local ui = require("msvc.ui")
            local solutions = msvc.solutions or {}
            if #solutions == 0 then
                local ok, err = pcall(SUBCOMMANDS.add.run, msvc, {})
                if not ok then
                    Log:error("msvc: %s", tostring(err))
                end
            elseif #solutions == 1 then
                msvc:set_solution(solutions[1])
                local ok, err = pcall(ui.open, msvc, "normal")
                if not ok then
                    Log:error("msvc: %s", tostring(err))
                end
            else
                local ok, err = pcall(ui.open, msvc, "add", {})
                if not ok then
                    Log:error("msvc: %s", tostring(err))
                end
            end
            return
        end
        local sub = args[1]
        local cmd = SUBCOMMANDS[sub]
        if not cmd then
            Log:error("msvc: unknown subcommand %q (available: add, cancel, log)", sub)
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
M._complete = complete

return M
