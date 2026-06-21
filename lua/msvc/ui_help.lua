-- msvc.ui_help — keybinding reference buffer (msvc-help://)

local M = {}

local BUFNAME = "msvc-help://"

local HELP_LINES = {
    "msvc-help://",
    "",
    "# Keybindings (msvc:// buffer only)",
    "",
    "  Stage action",
    "    b     build  (solution or project under cursor)",
    "    c     clean",
    "    r     rebuild",
    "    f     single-file compile  (project must be pinned; file = buffer at open time)",
    "    g     generate compile_commands.json",
    "",
    "  Confirm / cancel",
    "    :w    fire the staged action → close buffer → open log",
    "    -     on Pending line — clear staged action",
    "    q     close this buffer",
    "",
    "  Settings",
    "    =     expand / collapse field option list",
    "    -     on option line — select that value",
    "",
    "  Other",
    "    l     open build log",
    "    x     cancel in-flight build",
    "    h?    open this help buffer",
    "",
    "  Global commands (available anywhere)",
    "    :Msvc cancel   cancel in-flight build",
    "    :Msvc log      open build log",
}

function M.open()
    local buf = nil
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(b) == BUFNAME then
            buf = b
            break
        end
    end
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(buf, BUFNAME)
        vim.bo[buf].buftype = "nofile"
        vim.bo[buf].bufhidden = "wipe"
        vim.bo[buf].swapfile = false
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, HELP_LINES)
        vim.bo[buf].modifiable = false
        vim.bo[buf].filetype = "msvc-help"
        vim.keymap.set("n", "q", function()
            if vim.api.nvim_buf_is_valid(buf) then
                vim.api.nvim_buf_delete(buf, { force = true })
            end
        end, { buffer = buf, nowait = true, silent = true })
    end

    local target_win = nil
    for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(w) == buf then
            target_win = w
            break
        end
    end
    if not target_win then
        vim.cmd("split")
        target_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(target_win, buf)
    end
    vim.api.nvim_set_current_win(target_win)
end

return M
