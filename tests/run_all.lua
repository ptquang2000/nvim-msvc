-- Run all msvc specs in a single nvim process.
-- Usage: nvim --headless -u tests/minimal_init.lua -c "luafile tests/run_all.lua"

-- Intercept vim.cmd so plenary's "Xcq" quit-with-exit-code doesn't kill the
-- process mid-loop. Accumulate the worst exit code seen.
local orig_cmd = vim.cmd
local worst_code = 0
vim.cmd = function(arg)
    local cmd = type(arg) == "string" and arg or (arg.cmd or "")
    local code = cmd:match("^(%d*)cq$")
    if code ~= nil then
        worst_code = math.max(worst_code, tonumber(code) or 0)
        return
    end
    return orig_cmd(arg)
end

local specs = vim.fn.globpath("lua/msvc/test", "*_spec.lua", false, true)
table.sort(specs)
for _, path in ipairs(specs) do
    require("plenary.busted").run(path)
end

vim.cmd = orig_cmd
-- plenary's results table accumulates; the final format_results already printed
-- per-file. Exit with the worst code seen.
orig_cmd(worst_code .. "cq")
