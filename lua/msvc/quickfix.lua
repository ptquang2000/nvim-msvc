-- msvc.quickfix — parse MSBuild / cl / link output via Vim's errorformat
-- engine and publish to the quickfix list.

local Util = require("msvc.util")

local M = {}

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

function M.parse_lines(lines)
    if type(lines) ~= "table" or #lines == 0 then
        return {}
    end
    local ok, result = pcall(vim.fn.getqflist, {
        lines = lines,
        efm = M.errorformat,
    })
    if not ok or type(result) ~= "table" or type(result.items) ~= "table" then
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
        vim.cmd(("botright copen %d"):format(opts.height or 10))
    end
end

function M.from_build_output(lines, opts)
    local entries = M.parse_lines(lines)
    M.publish(entries, opts)
    return #entries
end

return M
