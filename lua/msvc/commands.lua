-- msvc.commands — `:Msvc <subcommand>` dispatcher.
-- Only `cancel` and `log` survive as subcommands; no-arg opens the buffer.

local Log = require("msvc.log")

local M = {}

local SUBCOMMANDS = {}

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
    return {}
end

function M.setup(msvc)
    vim.api.nvim_create_user_command("Msvc", function(opts)
        local args = opts.fargs
        if #args == 0 then
            local ok, err = pcall(require("msvc.ui").open, msvc)
            if not ok then
                Log:error("msvc: %s", tostring(err))
            end
            return
        end
        local sub = args[1]
        local cmd = SUBCOMMANDS[sub]
        if not cmd then
            Log:error("msvc: unknown subcommand %q (available: cancel, log)", sub)
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
