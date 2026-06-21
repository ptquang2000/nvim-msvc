-- msvc.ui — the msvc:// interactive build buffer.

local Log = require("msvc.log")
local Discover = require("msvc.discover")
local Util = require("msvc.util")

local M = {}

local BUFNAME = "msvc://"

local ENT = {
    BLANK = "blank",
    SECTION = "section",
    SETTINGS_FIELD = "settings_field",
    SETTINGS_OPTION = "settings_option",
    SOLUTION_HEADER = "solution_header",  -- Solution: <path>
    TARGET_HEADER = "target_header",      -- Target: <value>
    HELP_HEADER = "help_header",          -- Help: h?
    SEPARATOR = "separator",
    SOLUTION = "solution",
    PROJECT = "project",
    STAGED_HEADER = "staged_header",
    UNSTAGED_HEADER = "unstaged_header",
    SOLUTION_UNSTAGED = "solution_unstaged",
}

local HL_NS = vim.api.nvim_create_namespace("MsvcUI")

-- Module-level state — one msvc:// buffer at a time.
local _buf = nil
local _msvc = nil
local _line_map = {}           -- 1-based line → entity table
local _expanded_fields = {}    -- settings fields expanded (field name → true)
local _expanded_solutions = {} -- solutions with projects visible in add mode (path:lower() → true)
local _target = "build"        -- "build" | "clean" | "rebuild" | "compile_file"
local _source_file = nil    -- captured at open() for single-file compile
local _mode = "normal"      -- "normal" | "add"
local _discovered = {}      -- discovered-but-not-staged solution paths (add mode)
local _add_selected = nil   -- last staged solution in the current add session

local function reset()
    _buf = nil
    _msvc = nil
    _line_map = {}
    _expanded_fields = {}
    _expanded_solutions = {}
    _target = "build"
    _source_file = nil
    _mode = "normal"
    _discovered = {}
    _add_selected = nil
end

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
    local entries = {}

    local function add(text, entity)
        entries[#entries + 1] = { text = text, entity = entity }
    end

    if _mode == "add" then
        add("Solution: " .. (_add_selected or ""), { type = ENT.SOLUTION_HEADER })
        add("Help: h?", { type = ENT.HELP_HEADER })
        add("", { type = ENT.BLANK })
        add(string.rep("─", 40), { type = ENT.SEPARATOR })
        add("", { type = ENT.BLANK })

        add("  Staged", { type = ENT.STAGED_HEADER })
        local staged = msvc.solutions or {}
        if #staged == 0 then
            add("  <none staged>", { type = ENT.BLANK })
        else
            for _, sln_path in ipairs(staged) do
                local is_active = _add_selected
                    and _add_selected:lower() == sln_path:lower()
                local sln_lower = sln_path:lower()
                local is_expanded = _expanded_solutions[sln_lower]
                local active_marker = is_active and "* " or "  "
                add(
                    active_marker .. Util.basename(sln_path),
                    { type = ENT.SOLUTION, path = sln_path }
                )
                if is_expanded then
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

        if #_discovered > 0 then
            add("  Unstaged", { type = ENT.UNSTAGED_HEADER })
            for _, sln_path in ipairs(_discovered) do
                add(
                    "  " .. Util.basename(sln_path),
                    { type = ENT.SOLUTION_UNSTAGED, path = sln_path }
                )
            end
        end
    else
        local Config = require("msvc.config")
        local s = msvc.settings or {}

        add("Solution: " .. (msvc.solution or "<none>"), { type = ENT.SOLUTION_HEADER })
        add("Target: " .. _target, { type = ENT.TARGET_HEADER })
        add("Help: h?", { type = ENT.HELP_HEADER })
        add("", { type = ENT.BLANK })

        for _, field in ipairs(Config.SETTINGS_FIELDS) do
            local val = s[field]
            local val_str = (val ~= nil) and tostring(val) or "-"
            local is_expanded = _expanded_fields[field]
            add(
                ("  %-15s %s"):format(field, val_str),
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

        add(string.rep("─", 40), { type = ENT.SEPARATOR })
        add("", { type = ENT.BLANK })

        if not msvc.solution then
            add(
                "  <no solution — use add mode to register one>",
                { type = ENT.BLANK }
            )
        else
            local projects = Discover.parse_solution_projects(msvc.solution)
            if #projects == 0 then
                add("  <no projects found>", { type = ENT.BLANK })
            else
                for _, proj in ipairs(projects) do
                    local is_pinned = msvc.project
                        and msvc.project:lower() == proj.path:lower()
                    local proj_marker = is_pinned and "* " or "  "
                    add(
                        proj_marker .. proj.name,
                        {
                            type = ENT.PROJECT,
                            solution = msvc.solution,
                            name = proj.name,
                            path = proj.path,
                        }
                    )
                end
            end
        end

    end

    return entries
end

local function setup_highlights()
    local groups = {
        { "MsvcHeaderLabel",     "Title" },
        { "MsvcHeaderValue",     "Directory" },
        { "MsvcField",           "Identifier" },
        { "MsvcValue",           "Constant" },
        { "MsvcOption",          "Comment" },
        { "MsvcOptionSelected",  "Statement" },
        { "MsvcProject",         "Normal" },
        { "MsvcProjectSelected", "Special" },
        { "MsvcSeparator",       "Comment" },
        { "MsvcStagedHeader",    "Title" },
        { "MsvcUnstagedHeader",  "Comment" },
    }
    for _, g in ipairs(groups) do
        vim.api.nvim_set_hl(0, g[1], { link = g[2], default = true })
    end
end

local function apply_highlights(buf, entries)
    vim.api.nvim_buf_clear_namespace(buf, HL_NS, 0, -1)
    for i, e in ipairs(entries) do
        local ent = e.entity
        local line = i - 1  -- 0-based line index
        local t = ent.type
        if t == ENT.SOLUTION_HEADER or t == ENT.TARGET_HEADER or t == ENT.HELP_HEADER then
            -- "Label: value" — highlight label (including colon) and value separately.
            -- find returns 1-based position of ":"; 0-based exclusive col_end = that position.
            local colon = e.text:find(": ", 1, true)
            if colon then
                vim.api.nvim_buf_add_highlight(buf, HL_NS, "MsvcHeaderLabel", line, 0, colon)
                vim.api.nvim_buf_add_highlight(buf, HL_NS, "MsvcHeaderValue", line, colon + 1, -1)
            end
        elseif t == ENT.SETTINGS_FIELD then
            -- Format: "  "(2) + field(15 padded) + " "(1) + value
            -- Field name: cols 2–16; value: col 18 onward.
            vim.api.nvim_buf_add_highlight(buf, HL_NS, "MsvcField", line, 2, 17)
            vim.api.nvim_buf_add_highlight(buf, HL_NS, "MsvcValue", line, 18, -1)
        elseif t == ENT.SETTINGS_OPTION then
            local is_selected = e.text:find("> ", 1, true) ~= nil
            local hl = is_selected and "MsvcOptionSelected" or "MsvcOption"
            vim.api.nvim_buf_add_highlight(buf, HL_NS, hl, line, 0, -1)
        elseif t == ENT.PROJECT then
            if e.text:match("^%*") then
                vim.api.nvim_buf_add_highlight(buf, HL_NS, "MsvcProjectSelected", line, 0, 1)
                vim.api.nvim_buf_add_highlight(buf, HL_NS, "MsvcProject", line, 2, -1)
            else
                vim.api.nvim_buf_add_highlight(buf, HL_NS, "MsvcProject", line, 0, -1)
            end
        elseif t == ENT.SEPARATOR then
            vim.api.nvim_buf_add_highlight(buf, HL_NS, "MsvcSeparator", line, 0, -1)
        elseif t == ENT.STAGED_HEADER then
            vim.api.nvim_buf_add_highlight(buf, HL_NS, "MsvcStagedHeader", line, 0, -1)
        elseif t == ENT.UNSTAGED_HEADER then
            vim.api.nvim_buf_add_highlight(buf, HL_NS, "MsvcUnstagedHeader", line, 0, -1)
        end
    end
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
    apply_highlights(buf, entries)
end

local function entity_at_cursor()
    if not _buf or not vim.api.nvim_buf_is_valid(_buf) then
        return nil
    end
    local row = vim.api.nvim_win_get_cursor(0)[1]
    return _line_map[row]
end

local function setup_autocmds(msvc, buf)
    local group =
        vim.api.nvim_create_augroup("MsvcBuffer_" .. buf, { clear = true })
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        group = group,
        buffer = buf,
        callback = function()
            if _mode == "add" then
                if _add_selected == nil then
                    Log:warn("msvc: no solution staged — stage one before writing")
                    return
                end
                msvc:set_solution(_add_selected)
                _mode = "normal"
                render(msvc, buf)
                return
            end
            if _target == "generate" then
                local install = msvc:resolve_install()
                msvc:_run_compile_commands(msvc.settings, install and install.installationPath)
                if vim.api.nvim_buf_is_valid(buf) then
                    vim.api.nvim_buf_delete(buf, { force = true })
                end
                Log:show_build()
                return
            end
            local ok
            if _target == "build" then
                ok = msvc:build()
            elseif _target == "clean" then
                ok = msvc:build("Clean")
            elseif _target == "rebuild" then
                ok = msvc:build("Rebuild")
            elseif _target == "compile_file" then
                ok = msvc:build_file(_source_file)
            end
            if ok ~= false then
                Log:reset_build(("-- %s --"):format(_target))
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
        callback = reset,
    })
end

local function setup_keymaps(msvc, buf)
    local map_opts = { buffer = buf, nowait = true, silent = true }

    local function map(key, fn)
        vim.keymap.set("n", key, fn, map_opts)
    end

    map("b", function()
        if _mode == "add" then return end
        _target = "build"
        render(msvc, buf)
    end)
    map("c", function()
        if _mode == "add" then return end
        _target = "clean"
        render(msvc, buf)
    end)
    map("r", function()
        if _mode == "add" then return end
        _target = "rebuild"
        render(msvc, buf)
    end)
    map("f", function()
        if _mode == "add" then return end
        if not msvc.project then
            Log:warn(
                "msvc: pin a project first before using compile_file"
            )
            return
        end
        if not _source_file then
            Log:warn(
                "msvc: no source file captured (open msvc:// from a source buffer)"
            )
            return
        end
        _target = "compile_file"
        render(msvc, buf)
    end)
    map("=", function()
        local ent = entity_at_cursor()
        if not ent then return end
        if ent.type == ENT.SETTINGS_FIELD then
            if _expanded_fields[ent.field] then
                _expanded_fields[ent.field] = nil
            else
                _expanded_fields[ent.field] = true
            end
            render(msvc, buf)
        elseif ent.type == ENT.SETTINGS_OPTION then
            _expanded_fields[ent.field] = nil
            render(msvc, buf)
        elseif ent.type == ENT.SOLUTION then
            local k = ent.path:lower()
            if _expanded_solutions[k] then
                _expanded_solutions[k] = nil
            else
                _expanded_solutions[k] = true
            end
            render(msvc, buf)
        elseif ent.type == ENT.PROJECT and _mode == "add" and ent.solution then
            _expanded_solutions[ent.solution:lower()] = nil
            render(msvc, buf)
        end
    end)
    map("<CR>", function()
        local ent = entity_at_cursor()
        if not ent then return end
        if _mode ~= "add" then return end
        if ent.type ~= ENT.SOLUTION and ent.type ~= ENT.SOLUTION_UNSTAGED then return end

        local norm = ent.path
        local lower = norm:lower()

        if ent.type == ENT.SOLUTION_UNSTAGED then
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
        end

        _add_selected = norm
        msvc:set_solution(norm)
        _mode = "normal"
        render(msvc, buf)
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
            _expanded_fields[ent.field] = nil
            render(msvc, buf)
        elseif ent.type == ENT.PROJECT then
            if ent.path ~= msvc.project then
                msvc:set_project(ent.path)
            else
                msvc:set_project("")
            end
            render(msvc, buf)
        elseif ent.type == ENT.SOLUTION then
            local norm = ent.path
            local lower = norm:lower()
            local new_slns = {}
            for _, p in ipairs(msvc.solutions or {}) do
                if p:lower() ~= lower then
                    new_slns[#new_slns + 1] = p
                end
            end
            msvc.solutions = new_slns
            if msvc.solution and msvc.solution:lower() == lower then
                msvc.solution = nil
                msvc.project = nil
                msvc.solution_projects = {}
            end
            if _mode == "add" then
                _expanded_solutions[lower] = nil
                if _add_selected and _add_selected:lower() == lower then
                    _add_selected = nil
                end
                _discovered[#_discovered + 1] = norm
                table.sort(_discovered)
                msvc:_discard_solution_context(norm)
            end
            render(msvc, buf)
        elseif ent.type == ENT.SOLUTION_UNSTAGED then
            local norm = ent.path
            local lower = norm:lower()
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
            _add_selected = norm
            render(msvc, buf)
        end
    end)
    map("g", function()
        if _mode == "add" then return end
        _target = "generate"
        render(msvc, buf)
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
    setup_highlights()

    -- Capture the calling buffer's path for single-file compile.
    -- Must happen before we switch windows.
    local calling_name = vim.api.nvim_buf_get_name(0)
    _source_file = (calling_name ~= "" and calling_name) or nil

    -- Always update mode state, even when reusing an existing buffer.
    _mode = mode
    if mode == "add" then
        _add_selected = msvc.solution
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
        _expanded_fields = {}
        _expanded_solutions = {}
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
M._get_expanded_fields = function()
    return _expanded_fields
end
M._set_expanded_fields = function(t)
    _expanded_fields = t
end
M._set_expanded_field = function(f)
    _expanded_fields = (f ~= nil) and { [f] = true } or {}
end
M._get_expanded_solutions = function()
    return _expanded_solutions
end
M._set_expanded_solutions = function(t)
    _expanded_solutions = t
end
M._get_target = function()
    return _target
end
M._set_target = function(t)
    _target = t
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
M._get_add_selected = function()
    return _add_selected
end
M._set_add_selected = function(s)
    _add_selected = s
end
M._setup_keymaps = setup_keymaps
M._setup_autocmds = setup_autocmds
M._render = render
M._reset = reset

return M
