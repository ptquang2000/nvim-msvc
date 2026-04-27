-- msvc.util — pure helpers (path, table, shell quoting). No side effects.

local M = {}

local uv = vim.uv or vim.loop

function M.is_windows()
    return package.config:sub(1, 1) == "\\"
end

local SEP = M.is_windows() and "\\" or "/"

--- Normalize a path: convert `/` → `\` on Windows, collapse duplicate
--- separators, strip trailing separator (except for drive roots).
function M.normalize_path(p)
    if p == nil then
        return nil
    end
    local s = tostring(p)
    if M.is_windows() then
        s = s:gsub("/", "\\")
        local prefix = ""
        if s:sub(1, 2) == "\\\\" then
            prefix, s = "\\\\", s:sub(3)
        end
        s = s:gsub("\\+", "\\")
        s = prefix .. s
        if #s > 1 and s:sub(-1) == "\\" and not s:match("^%a:\\$") then
            s = s:sub(1, -2)
        end
    else
        s = s:gsub("//+", "/")
        if #s > 1 and s:sub(-1) == "/" then
            s = s:sub(1, -2)
        end
    end
    return s
end

function M.is_absolute(p)
    if p == nil or p == "" then
        return false
    end
    local s = tostring(p)
    if s:sub(1, 2) == "\\\\" or s:sub(1, 2) == "//" then
        return true
    end
    if s:match("^%a:[\\/]?") then
        return true
    end
    return s:sub(1, 1) == "/"
end

function M.join_path(...)
    local out
    for _, part in ipairs({ ... }) do
        if part ~= nil and part ~= "" then
            local s = tostring(part)
            if out == nil then
                out = s
            else
                if M.is_windows() then
                    s = s:gsub("^[\\/]+", "")
                else
                    s = s:gsub("^/+", "")
                end
                local last = out:sub(-1)
                if last == SEP or (M.is_windows() and last == "/") then
                    out = out .. s
                else
                    out = out .. SEP .. s
                end
            end
        end
    end
    return M.normalize_path(out or "")
end

--- Resolve `p` against `anchor`. Absolute paths are returned as-is.
function M.resolve_path(p, anchor)
    if p == nil or p == "" then
        return nil
    end
    if M.is_absolute(p) then
        return M.normalize_path(p)
    end
    if anchor == nil or anchor == "" then
        return M.normalize_path(p)
    end
    return M.join_path(anchor, p)
end

function M.is_file(p)
    if p == nil or p == "" then
        return false
    end
    local st = uv.fs_stat(p)
    return st ~= nil and st.type == "file"
end

function M.is_dir(p)
    if p == nil or p == "" then
        return false
    end
    local st = uv.fs_stat(p)
    return st ~= nil and st.type == "directory"
end

function M.read_file(p)
    if p == nil or p == "" then
        return nil, "empty path"
    end
    local fd, oerr = uv.fs_open(p, "r", 438)
    if not fd then
        return nil, oerr
    end
    local st, serr = uv.fs_fstat(fd)
    if not st then
        uv.fs_close(fd)
        return nil, serr
    end
    local data, rerr = uv.fs_read(fd, st.size, 0)
    uv.fs_close(fd)
    if not data then
        return nil, rerr
    end
    return data, nil
end

function M.basename(p)
    if p == nil or p == "" then
        return ""
    end
    local s = tostring(p):gsub("[\\/]+$", "")
    return s:match("[^\\/]+$") or s
end

function M.dirname(p)
    if p == nil or p == "" then
        return ""
    end
    local s = tostring(p):gsub("[\\/]+$", "")
    return s:match("^(.*)[\\/][^\\/]+$") or ""
end

--- Sort + dedup an array of strings, preserving first-seen order.
function M.dedupe(list)
    local seen, out = {}, {}
    for _, v in ipairs(list or {}) do
        if type(v) == "string" and v ~= "" and not seen[v] then
            seen[v] = true
            out[#out + 1] = v
        end
    end
    return out
end

return M
