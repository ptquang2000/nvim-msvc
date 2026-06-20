-- msvc.ui — the msvc:// interactive build buffer.

local Log = require("msvc.log")
local Discover = require("msvc.discover")
local Util = require("msvc.util")

local M = {}

local BUFNAME = "msvc://"

local ENT = {
    HEADER = "header",
    BLANK = "blank",
    SECTION = "section",
    SETTINGS_FIELD = "settings_field",
    SETTINGS_OPTION = "settings_option",
    PENDING = "pending",
    SOLUTION = "solution",
    PROJECT = "project",
    STAGED_HEADER = "staged_header",
    UNSTAGED_HEADER = "unstaged_header",
    SOLUTION_UNSTAGED = "solution_unstaged",
}

-- Module-level state — one msvc:// buffer at a time.
local _buf = nil
local _msvc = nil
local _line_map = {}        -- 1-based line → entity table
local _expanded_field = nil -- settings field name currently expanded, or nil
local _pending = nil        -- { action, solution, project, project_name, file }
local _source_file = nil    -- captured at open() for single-file compile
local _mode = "normal"      -- "normal" | "add"
local _discovered = {}      -- discovered-but-not-staged solution paths (add mode)

local function get_setting_options(msvc, field)
    if field == "configuration" or field == "platform" then
        local d = Discover.discover_targets(msvc.solution, msvc.project)
        return field == "configuration" and d.configurations or d.platforms
    elseif field == "arch" then
        return { "x86", "x64", "arm", "arm64" }
    elseif field == "vs_version" then
        return { "latest", "2017", "2019", "2022" }
    elseif field == "jobs" then
        return { "1", "2", "4", "6", "8", "12", "16" }
    end
    return {}
end

--- Build the render entries from current singleton + ui state.
--- Returns list of { text: string, entity: table }.
local function build_entries(msvc)
    local Config = require("msvc.config")
    local s = msvc.settings or {}
    local entries = {}

    local function add(text, entity)
        entries[#entries + 1] = { text = text, entity = entity }
    end

    add("msvc://", { type = ENT.HEADER })
    add("", { type = ENT.BLANK })

    add("# Settings", { type = ENT.SECTION, name = "settings" })
    for _, field in ipairs(Config.SETTINGS_FIELDS) do
        local val = s[field]
        local val_str = (val ~= nil) and tostring(val) or "-"
        local is_expanded = _expanded_field == field
        local marker = is_expanded and "v " or "  "
        add(
            marker .. ("  %-15s %s"):format(field, val_str),
            { type = ENT.SETTINGS_FIELD, field = field, value = val }
        )
        if is_expanded then
            local opts = get_setting_options(msvc, field)
            for _, opt in ipairs(opts) do
                local sel = (tostring(opt) == val_str) and "> " or "  "
                add(
                    "    " .. sel .. tostring(opt),
                    { type = ENT.SETTINGS_OPTION, field = field, value = opt }
                )
            end
        end
    end
    add("", { type = ENT.BLANK })

    add("# Pending", { type = ENT.SECTION, name = "pending" })
    if _pending then
        local p = _pending
        local label
        if p.action == "compile_file" then
            label = "compile  " .. (p.file and Util.basename(p.file) or "<file>")
        else
            local sln_base = Util.basename(p.solution or "")
            if p.project_name then
                label = p.action .. "  " .. sln_base .. " | " .. p.project_name
            else
                label = p.action .. "  " .. sln_base
            end
        end
        add("  " .. label, { type = ENT.PENDING })
    else
        add("  <none>", { type = ENT.PENDING })
    end
    add("", { type = ENT.BLANK })

    add("# Solutions", { type = ENT.SECTION, name = "solutions" })

    if _mode == "add" then
        add("  Staged", { type = ENT.STAGED_HEADER })
        local staged = msvc.solutions or {}
        if #staged == 0 then
            add("  <none staged>", { type = ENT.BLANK })
        else
            for _, sln_path in ipairs(staged) do
                local is_active = msvc.solution
                    and msvc.solution:lower() == sln_path:lower()
                local sln_marker = is_active and "* " or "  "
                add(
                    sln_marker .. Util.basename(sln_path),
                    { type = ENT.SOLUTION, path = sln_path }
                )
                local projects = Discover.parse_solution_projects(sln_path)
                for _, proj in ipairs(projects) do
                    local is_pinned = msvc.project
                        and msvc.project:lower() == proj.path:lower()
                    local proj_marker = is_pinned and "  > " or "    "
                    add(
                        proj_marker .. proj.name,
                        {
                            type = ENT.PROJECT,
                            solution = sln_path,
                            name = proj.name,
                            path = proj.path,
                        }
                    )
                end
            end
        end
        add("", { type = ENT.BLANK })
        add("  Unstaged", { type = ENT.UNSTAGED_HEADER })
        if #_discovered == 0 then
            add("  <none found>", { type = ENT.BLANK })
        else
            for _, sln_path in ipairs(_discovered) do
                add(
                    "  " .. Util.basename(sln_path),
                    { type = ENT.SOLUTION_UNSTAGED, path = sln_path }
                )
            end
        end
    else
        if #(msvc.solutions or {}) == 0 then
            add("  <no solutions — open a .sln buffer>", { type = ENT.BLANK })
        else
            for _, sln_path in ipairs(msvc.solutions or {}) do
                local is_active = msvc.solution
                    and msvc.solution:lower() == sln_path:lower()
                local sln_marker = is_active and "* " or "  "
                add(
                    sln_marker .. Util.basename(sln_path),
                    { type = ENT.SOLUTION, path = sln_path }
                )
                local projects = Discover.parse_solution_projects(sln_path)
                for _, proj in ipairs(projects) do
                    local is_pinned = msvc.project
                        and msvc.project:lower() == proj.path:lower()
                    local proj_marker = is_pinned and "  > " or "    "
                    add(
                        proj_marker .. proj.name,
                        {
                            type = ENT.PROJECT,
                            solution = sln_path,
                            name = proj.name,
                            path = proj.path,
                        }
                    )
                end
            end
        end
    end

    add("", { type = ENT.BLANK })
    add("  h? — keybinding reference", { type = ENT.BLANK })

    return entries
end

local function render(msvc, buf)
    local entries = build_entries(msvc)
    local lines = {}
    _line_map = {}
    for i, e in ipairs(entries) do
        lines[i] = e.text
        _line_map[i] = e.entity
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
end

local function entity_at_cursor()
    if not _buf or not vim.api.nvim_buf_is_valid(_buf) then
        return nil
    end
    local row = vim.api.nvim_win_get_cursor(0)[1]
    return _line_map[row]
end

local function stage(action, ent)
    if ent.type == ENT.PROJECT then
        _pending = {
            action = action,
            solution = ent.solution,
            project = ent.path,
            project_name = ent.name,
        }
        return true
    elseif ent.type == ENT.SOLUTION then
        _pending = {
            action = action,
            solution = ent.path,
            project = nil,
            project_name = nil,
        }
        return true
    end
    return false
end

local function fire_pending(msvc)
    if not _pending then
        Log:warn("msvc: nothing staged (press b/c/r/f on a project first)")
        return false
    end
    local p = _pending
    -- Switch context if needed
    if p.solution ~= msvc.solution then
        if not msvc:set_solution(p.solution) then
            return false
        end
    end
    if p.project ~= msvc.project then
        if not msvc:set_project(p.project or "") then
            return false
        end
    end
    -- Dispatch
    local ok
    if p.action == "build" then
        ok = msvc:build()
    elseif p.action == "clean" then
        ok = msvc:build("Clean")
    elseif p.action == "rebuild" then
        ok = msvc:build("Rebuild")
    elseif p.action == "compile_file" then
        ok = msvc:build_file(p.file)
    end
    return ok ~= false
end

local function setup_autocmds(msvc, buf)
    local group =
        vim.api.nvim_create_augroup("MsvcBuffer_" .. buf, { clear = true })
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        group = group,
        buffer = buf,
        callback = function()
            if fire_pending(msvc) then
                _pending = nil
                if vim.api.nvim_buf_is_valid(buf) then
                    vim.api.nvim_buf_delete(buf, { force = true })
                end
                Log:show_build()
            end
        end,
    })
    vim.api.nvim_create_autocmd("BufUnload", {
        group = group,
        buffer = buf,
        callback = function()
            _buf = nil
            _msvc = nil
            _line_map = {}
            _pending = nil
            _expanded_field = nil
            _source_file = nil
            _mode = "normal"
            _discovered = {}
        end,
    })
end

local function setup_keymaps(msvc, buf)
    local map_opts = { buffer = buf, nowait = true, silent = true }

    local function map(key, fn)
        vim.keymap.set("n", key, fn, map_opts)
    end

    map("b", function()
        local ent = entity_at_cursor()
        if ent and stage("build", ent) then
            render(msvc, buf)
        end
    end)
    map("c", function()
        local ent = entity_at_cursor()
        if ent and stage("clean", ent) then
            render(msvc, buf)
        end
    end)
    map("r", function()
        local ent = entity_at_cursor()
        if ent and stage("rebuild", ent) then
            render(msvc, buf)
        end
    end)
    map("f", function()
        if not msvc.project then
            Log:warn(
                "msvc: pin a project first before staging single-file compile"
            )
            return
        end
        if not _source_file then
            Log:warn(
                "msvc: no source file captured (open msvc:// from a source buffer)"
            )
            return
        end
        _pending = {
            action = "compile_file",
            solution = msvc.solution,
            project = msvc.project,
            project_name = nil,
            file = _source_file,
        }
        render(msvc, buf)
    end)
    map("=", function()
        local ent = entity_at_cursor()
        if not ent or ent.type ~= ENT.SETTINGS_FIELD then
            return
        end
        _expanded_field = (_expanded_field == ent.field) and nil or ent.field
        render(msvc, buf)
    end)
    map("<CR>", function()
        local ent = entity_at_cursor()
        if not ent then
            return
        end
        if ent.type == ENT.SOLUTION then
            msvc:set_solution(ent.path)
            render(msvc, buf)
        elseif ent.type == ENT.SOLUTION_UNSTAGED then
            local norm = ent.path
            local lower = norm:lower()
            -- Stage it
            local already = false
            for _, c in ipairs(msvc.solutions) do
                if c:lower() == lower then
                    already = true
                    break
                end
            end
            if not already then
                msvc.solutions[#msvc.solutions + 1] = norm
                table.sort(msvc.solutions)
            end
            -- Remove from _discovered
            local new_disc = {}
            for _, p in ipairs(_discovered) do
                if p:lower() ~= lower then
                    new_disc[#new_disc + 1] = p
                end
            end
            _discovered = new_disc
            msvc:set_solution(norm)
            render(msvc, buf)
        elseif ent.type == ENT.PROJECT then
            msvc:set_project(ent.path)
            render(msvc, buf)
        end
        -- SECTION, BLANK, HEADER, SETTINGS_FIELD, STAGED_HEADER, UNSTAGED_HEADER,
        -- SETTINGS_OPTION, PENDING: no-op
    end)
    map("-", function()
        local ent = entity_at_cursor()
        if not ent then
            return
        end
        if ent.type == ENT.SETTINGS_OPTION then
            local val = ent.value
            if ent.field == "jobs" then
                val = tonumber(val)
            end
            msvc.settings[ent.field] = val
            if ent.field == "vs_version" then
                msvc.install = nil
            end
            _expanded_field = nil
            render(msvc, buf)
        elseif ent.type == ENT.PENDING then
            _pending = nil
            render(msvc, buf)
        elseif ent.type == ENT.SOLUTION then
            local norm = ent.path
            local lower = norm:lower()
            -- Remove from staged solutions
            local new_slns = {}
            for _, p in ipairs(msvc.solutions or {}) do
                if p:lower() ~= lower then
                    new_slns[#new_slns + 1] = p
                end
            end
            msvc.solutions = new_slns
            -- Clear active if it was this one
            if msvc.solution and msvc.solution:lower() == lower then
                msvc.solution = nil
                msvc.project = nil
                msvc.solution_projects = {}
            end
            -- In add mode, move back to _discovered
            if _mode == "add" then
                _discovered[#_discovered + 1] = norm
                table.sort(_discovered)
            end
            render(msvc, buf)
        elseif ent.type == ENT.SOLUTION_UNSTAGED then
            local norm = ent.path
            local lower = norm:lower()
            -- Stage it (add to solutions), remove from _discovered
            local already = false
            for _, c in ipairs(msvc.solutions) do
                if c:lower() == lower then
                    already = true
                    break
                end
            end
            if not already then
                msvc.solutions[#msvc.solutions + 1] = norm
                table.sort(msvc.solutions)
            end
            local new_disc = {}
            for _, p in ipairs(_discovered) do
                if p:lower() ~= lower then
                    new_disc[#new_disc + 1] = p
                end
            end
            _discovered = new_disc
            render(msvc, buf)
        end
    end)
    map("l", function()
        Log:show_build()
    end)
    map("x", function()
        msvc:cancel()
    end)
    map("h?", function()
        local ok, err = pcall(require("msvc.ui_help").open)
        if not ok then
            Log:error("msvc: %s", tostring(err))
        end
    end)
    map("q", function()
        if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    end)
end

function M.open(msvc, mode, discovered)
    mode = mode or "normal"

    -- Capture the calling buffer's path for single-file compile.
    -- Must happen before we switch windows.
    local calling_name = vim.api.nvim_buf_get_name(0)
    _source_file = (calling_name ~= "" and calling_name) or nil

    -- Always update mode state, even when reusing an existing buffer.
    _mode = mode
    if mode == "add" then
        local staged_lower = {}
        for _, p in ipairs(msvc.solutions or {}) do
            staged_lower[p:lower()] = true
        end
        _discovered = {}
        for _, p in ipairs(discovered or {}) do
            local np = Util.normalize_path(p) or p
            if np and not staged_lower[np:lower()] then
                _discovered[#_discovered + 1] = np
            end
        end
        table.sort(_discovered)
    else
        _discovered = {}
    end

    -- Reuse or create the msvc:// buffer.
    local buf = _buf
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(buf, BUFNAME)
        vim.bo[buf].buftype = "acwrite"
        vim.bo[buf].bufhidden = "wipe"
        vim.bo[buf].swapfile = false
        vim.bo[buf].filetype = "msvc"
        setup_autocmds(msvc, buf)
        setup_keymaps(msvc, buf)
        _buf = buf
        _msvc = msvc
        _pending = nil
        _expanded_field = nil
    end

    -- Find or create a window for this buffer.
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

    render(msvc, buf)
end

-- Expose internals for unit testing.
M._build_entries = build_entries
M._ENT = ENT
M._get_expanded_field = function()
    return _expanded_field
end
M._set_expanded_field = function(f)
    _expanded_field = f
end
M._get_pending = function()
    return _pending
end
M._set_pending = function(p)
    _pending = p
end
M._get_mode = function()
    return _mode
end
M._set_mode = function(m)
    _mode = m
end
M._get_discovered = function()
    return _discovered
end
M._set_discovered = function(d)
    _discovered = d
end
M._get_buf = function()
    return _buf
end
M._set_buf = function(b)
    _buf = b
end
M._get_line_map = function()
    return _line_map
end
M._set_line_map = function(lm)
    _line_map = lm
end
M._setup_keymaps = setup_keymaps
M._render = render
M._reset = function()
    _buf = nil
    _msvc = nil
    _line_map = {}
    _expanded_field = nil
    _pending = nil
    _source_file = nil
    _mode = "normal"
    _discovered = {}
end

return M
