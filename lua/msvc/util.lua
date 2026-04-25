-- msvc.util: pure helpers (path, table, string, shell-quoting) shared across
--            the plugin. No Neovim runtime side effects at require time.

local M = {}

local uv = vim.uv or vim.loop

--- @return boolean
function M.is_windows()
    return package.config:sub(1, 1) == "\\"
end

local SEP = M.is_windows() and "\\" or "/"

--- Normalize a path: convert forward slashes to backslashes on Windows,
--- collapse duplicate separators, and strip a trailing separator (unless
--- the path is a drive root like "C:\").
--- @param p string|nil
--- @return string|nil
function M.normalize_path(p)
    if p == nil then
        return nil
    end
    local s = tostring(p)
    if M.is_windows() then
        s = s:gsub("/", "\\")
        -- collapse duplicate backslashes (preserve leading "\\" for UNC paths)
        local prefix = ""
        if s:sub(1, 2) == "\\\\" then
            prefix = "\\\\"
            s = s:sub(3)
        end
        s = s:gsub("\\+", "\\")
        s = prefix .. s
        -- strip trailing slash unless it is a drive root ("C:\")
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

--- True when the given path is absolute. Recognized forms:
---   * Windows drive-letter: "C:\foo", "c:/foo" (also bare "C:" / "C:\")
---   * Windows UNC:          "\\server\share\..." (or with forward slashes)
---   * POSIX absolute:       "/foo"
--- Empty / nil paths are not absolute.
--- @param p string|nil
--- @return boolean
function M.is_absolute(p)
    if p == nil or p == "" then
        return false
    end
    local s = tostring(p)
    -- UNC: leading "\\" or "//"
    if s:sub(1, 2) == "\\\\" or s:sub(1, 2) == "//" then
        return true
    end
    -- Windows drive letter: "C:" optionally followed by separator
    if s:match("^%a:[\\/]?") then
        return true
    end
    -- POSIX absolute
    if s:sub(1, 1) == "/" then
        return true
    end
    return false
end

--- Resolve `p` against `anchor`. Absolute paths are returned normalized
--- as-is; relative paths are joined onto `anchor`. Returns nil only when
--- both `p` and `anchor` are empty.
--- @param p string|nil
--- @param anchor string|nil
--- @return string|nil
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

--- Join two or more path components using the OS separator.
--- @vararg string
--- @return string
function M.join_path(...)
    local parts = { ... }
    local out
    for _, part in ipairs(parts) do
        if part ~= nil and part ~= "" then
            if out == nil then
                out = tostring(part)
            else
                local stripped = tostring(part)
                if M.is_windows() then
                    stripped = stripped:gsub("^[\\/]+", "")
                else
                    stripped = stripped:gsub("^/+", "")
                end
                if
                    out:sub(-1) == SEP
                    or (M.is_windows() and out:sub(-1) == "/")
                then
                    out = out .. stripped
                else
                    out = out .. SEP .. stripped
                end
            end
        end
    end
    return M.normalize_path(out or "")
end

--- @param p string|nil
--- @return boolean
function M.path_exists(p)
    if p == nil or p == "" then
        return false
    end
    return uv.fs_stat(p) ~= nil
end

--- @param p string|nil
--- @return boolean
function M.is_file(p)
    if p == nil or p == "" then
        return false
    end
    local st = uv.fs_stat(p)
    return st ~= nil and st.type == "file"
end

--- @param p string|nil
--- @return boolean
function M.is_dir(p)
    if p == nil or p == "" then
        return false
    end
    local st = uv.fs_stat(p)
    return st ~= nil and st.type == "directory"
end

--- Read an entire file into a string.
--- @param p string
--- @return string|nil contents
--- @return string|nil err
function M.read_file(p)
    if p == nil or p == "" then
        return nil, "empty path"
    end
    local fd, oerr = uv.fs_open(p, "r", 438) -- 0o666
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

--- Quote an argument for cmd.exe / CreateProcess on Windows. Wraps in double
--- quotes when the string is empty or contains whitespace / shell metacharacters
--- / quotes; embedded double quotes are escaped per CommandLineToArgvW rules.
--- @param arg string|number|nil
--- @return string
function M.shell_escape(arg)
    if arg == nil then
        return [[""]]
    end
    local s = tostring(arg)
    if s == "" then
        return [[""]]
    end
    -- safe as-is if it has no whitespace, quotes, or shell-meaningful chars
    if not s:find("[%s\"&|<>%^]") then
        return s
    end
    -- Per CommandLineToArgvW: 2N backslashes + " -> N backslashes + literal "
    local escaped = s:gsub("(\\*)\"", function(bs)
        return string.rep("\\", #bs * 2) .. "\\\""
    end)
    -- double trailing backslashes so the closing quote isn't escaped
    escaped = escaped:gsub("(\\+)$", function(bs)
        return string.rep("\\", #bs * 2)
    end)
    return "\"" .. escaped .. "\""
end

local function is_array(t)
    if type(t) ~= "table" then
        return false
    end
    if next(t) == nil then
        return false
    end
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    for i = 1, n do
        if t[i] == nil then
            return false
        end
    end
    return true
end

--- Deep-merge two tables. `overrides` wins when keys collide. Arrays
--- (sequences with integer keys 1..n) are *replaced* wholesale, not merged.
--- nil values in `overrides` keep the default.
--- @param defaults table|nil
--- @param overrides table|nil
--- @return table
function M.tbl_deep_merge(defaults, overrides)
    defaults = defaults or {}
    overrides = overrides or {}
    if is_array(defaults) or is_array(overrides) then
        -- Replace arrays wholesale; prefer overrides if it has anything.
        if next(overrides) ~= nil then
            local copy = {}
            for i, v in ipairs(overrides) do
                copy[i] = v
            end
            return copy
        end
        local copy = {}
        for i, v in ipairs(defaults) do
            copy[i] = v
        end
        return copy
    end
    local out = {}
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            out[k] = M.tbl_deep_merge(v, {})
        else
            out[k] = v
        end
    end
    for k, v in pairs(overrides) do
        if type(v) == "table" and type(out[k]) == "table" then
            out[k] = M.tbl_deep_merge(out[k], v)
        else
            out[k] = v
        end
    end
    return out
end

--- Remove duplicate entries from a list while preserving first-seen order.
--- @param list table
--- @return table
function M.dedupe(list)
    local out, seen = {}, {}
    for _, v in ipairs(list or {}) do
        if not seen[v] then
            seen[v] = true
            out[#out + 1] = v
        end
    end
    return out
end

--- Final path component (no separator).
--- @param p string|nil
--- @return string
function M.basename(p)
    if p == nil or p == "" then
        return ""
    end
    local s = tostring(p):gsub("[\\/]+$", "")
    return s:match("[^\\/]+$") or s
end

--- Directory part (no trailing separator). Returns "" when p has no separator.
--- @param p string|nil
--- @return string
function M.dirname(p)
    if p == nil or p == "" then
        return ""
    end
    local s = tostring(p):gsub("[\\/]+$", "")
    local dir = s:match("^(.*)[\\/][^\\/]+$")
    return dir or ""
end

--- File extension (lower-cased), without the leading dot. "" when none.
--- @param p string|nil
--- @return string
function M.extension(p)
    if p == nil or p == "" then
        return ""
    end
    local base = M.basename(p)
    local ext = base:match("%.([^.]+)$")
    return ext and ext:lower() or ""
end

local _uniq_counter = 0

--- Return a process-unique monotonic id (string).
--- @return string
function M.uniq_id()
    _uniq_counter = _uniq_counter + 1
    return tostring(_uniq_counter)
end

--- @param list table
--- @param value any
--- @return boolean
function M.tbl_contains(list, value)
    if type(list) ~= "table" then
        return false
    end
    for _, v in ipairs(list) do
        if v == value then
            return true
        end
    end
    return false
end

--- @param s string|nil
--- @param prefix string
--- @return boolean
function M.starts_with(s, prefix)
    if s == nil or prefix == nil then
        return false
    end
    return string.sub(s, 1, #prefix) == prefix
end

--- @param s string|nil
--- @param suffix string
--- @return boolean
function M.ends_with(s, suffix)
    if s == nil or suffix == nil then
        return false
    end
    if suffix == "" then
        return true
    end
    return string.sub(s, -#suffix) == suffix
end

return M
