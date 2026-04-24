local Util = require("msvc.util")
local Log = require("msvc.log")

local M = {}

---@class msvc.QfEntry
---@field filename string
---@field lnum integer
---@field col integer
---@field type string
---@field text string
---@field valid integer

---MSBuild / cl.exe / link.exe errorformat string.
---Suitable for `vim.opt.errorformat` or `:set efm=`.
M.errorformat = table.concat({
    [[%f(%l\,%c): %trror %m]],
    [[%f(%l\,%c): %tarning %m]],
    [[%f(%l\,%c): fatal %trror %m]],
    [[%f(%l): %trror %m]],
    [[%f(%l): %tarning %m]],
    [[%f(%l): fatal %trror %m]],
    [[%f : fatal %trror %m]],
    [[%f : %trror %m]],
    [[%f : %tarning %m]],
    [[%-G%.%#]],
}, ",")

---Parse build output lines into normalized quickfix entries.
---Uses Vim's errorformat engine via `getqflist({lines, efm})`.
---@param lines string[] Raw build output lines.
---@return msvc.QfEntry[] entries Valid, normalized quickfix entries.
function M.parse_lines(lines)
    if type(lines) ~= "table" or #lines == 0 then
        return {}
    end
    local ok, result = pcall(vim.fn.getqflist, {
        lines = lines,
        efm = M.errorformat,
    })
    if not ok or type(result) ~= "table" or type(result.items) ~= "table" then
        Log.warn("quickfix.parse_lines: getqflist failed")
        return {}
    end
    local out = {}
    for _, item in ipairs(result.items) do
        if item.valid == 1 or item.valid == true then
            local fname = ""
            if item.bufnr and item.bufnr > 0 then
                fname = vim.api.nvim_buf_get_name(item.bufnr) or ""
            end
            if fname == "" and item.filename then
                fname = item.filename
            end
            if fname ~= "" then
                fname = Util.normalize_path(fname)
            end
            out[#out + 1] = {
                filename = fname,
                lnum = item.lnum or 0,
                col = item.col or 0,
                type = item.type or "",
                text = item.text or "",
                valid = 1,
            }
        end
    end
    return out
end

---@class msvc.QfPublishOpts
---@field title? string Quickfix title (default "MSBuild").
---@field action? string setqflist action (" ", "a", "r"); default " ".
---@field open? boolean Open quickfix window if entries exist.
---@field height? integer Height for `botright copen` (default 10).
---@field jump_first? boolean Run `:cfirst` if entries exist.

---Publish a list of quickfix entries.
---@param entries msvc.QfEntry[]
---@param opts? msvc.QfPublishOpts
function M.publish(entries, opts)
    opts = opts or {}
    entries = entries or {}
    local items = {}
    for _, e in ipairs(entries) do
        items[#items + 1] = {
            filename = e.filename,
            lnum = e.lnum,
            col = e.col,
            type = e.type,
            text = e.text,
        }
    end
    vim.fn.setqflist({}, opts.action or " ", {
        title = opts.title or "MSBuild",
        items = items,
    })
    if #entries > 0 and opts.open == true then
        local height = opts.height or 10
        vim.cmd(("botright copen %d"):format(height))
    end
    if #entries > 0 and opts.jump_first == true then
        pcall(vim.cmd, "cfirst")
    end
end

---Clear the quickfix list (keeps MSBuild title).
function M.clear()
    vim.fn.setqflist({}, " ", { title = "MSBuild", items = {} })
end

---Parse build output and publish to quickfix.
---@param lines string[]
---@param opts? msvc.QfPublishOpts
---@return integer count Number of valid entries published.
function M.from_build_output(lines, opts)
    local entries = M.parse_lines(lines)
    M.publish(entries, opts)
    return #entries
end

return M
