-- Tests for msvc.ui: line→entity map construction and pending-action state.

local helpers = require("msvc.test.utils")

describe("msvc.ui", function()
    local UI, Config

    before_each(function()
        helpers.reset()
        UI = require("msvc.ui")
        Config = require("msvc.config")
        UI._reset()
        -- Remove any stale msvc:// buffer left over by cross-module tests.
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            local ok, name = pcall(vim.api.nvim_buf_get_name, b)
            if ok and name:find("msvc://", 1, true) then
                pcall(vim.api.nvim_buf_delete, b, { force = true })
            end
        end
    end)

    local function fake_msvc(opts)
        opts = opts or {}
        return {
            settings = vim.tbl_extend(
                "force",
                vim.deepcopy(Config.DEFAULT_SETTINGS),
                opts.settings or {}
            ),
            solution = opts.solution or nil,
            project = opts.project or nil,
            solutions = opts.solutions or {},
            solution_projects = opts.solution_projects or {},
            set_solution = opts.set_solution or function(self, path)
                self.solution = path
                return true
            end,
            set_project = opts.set_project or function(self, path)
                self.project = path
                return true
            end,
        }
    end

    -- ─── build_entries structural tests ────────────────────────────────────

    it("contains one SETTINGS_FIELD entry per SETTINGS_FIELDS element", function()
        local msvc = fake_msvc()
        local entries = UI._build_entries(msvc)
        local found = {}
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.SETTINGS_FIELD then
                found[e.entity.field] = true
            end
        end
        for _, f in ipairs(Config.SETTINGS_FIELDS) do
            assert.is_true(found[f], "missing settings field entry: " .. f)
        end
    end)

    it("SETTINGS_FIELD entity carries current value from msvc.settings", function()
        local msvc = fake_msvc({ settings = { configuration = "Release", platform = "x64" } })
        local entries = UI._build_entries(msvc)
        local cfg_ent, plat_ent
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.SETTINGS_FIELD then
                if e.entity.field == "configuration" then cfg_ent = e.entity end
                if e.entity.field == "platform" then plat_ent = e.entity end
            end
        end
        assert.are.equal("Release", cfg_ent.value)
        assert.are.equal("x64", plat_ent.value)
    end)

    it("nil value renders as '-' in settings line text", function()
        local msvc = fake_msvc()
        local entries = UI._build_entries(msvc)
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.SETTINGS_FIELD and e.entity.field == "configuration" then
                assert.is_truthy(e.text:find("-"))
                break
            end
        end
    end)

    it("has exactly one PENDING entity", function()
        local msvc = fake_msvc()
        local entries = UI._build_entries(msvc)
        local count = 0
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.PENDING then
                count = count + 1
            end
        end
        assert.are.equal(1, count)
    end)

    it("pending entity text shows <none> when no action is staged", function()
        local msvc = fake_msvc()
        local entries = UI._build_entries(msvc)
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.PENDING then
                assert.is_truthy(e.text:find("<none>"))
                return
            end
        end
        error("no PENDING entity found")
    end)

    it("pending entity text includes action name and project when staged", function()
        local msvc = fake_msvc()
        UI._set_pending({
            action = "build",
            solution = "/a/foo.sln",
            project = "/a/P.vcxproj",
            project_name = "ProjX",
        })
        local entries = UI._build_entries(msvc)
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.PENDING then
                assert.is_truthy(e.text:find("build"))
                assert.is_truthy(e.text:find("ProjX"))
                return
            end
        end
        error("no PENDING entity found")
    end)

    it("pending entity text for solution-only action (no project)", function()
        local msvc = fake_msvc()
        UI._set_pending({
            action = "clean",
            solution = "/a/bar.sln",
            project = nil,
            project_name = nil,
        })
        local entries = UI._build_entries(msvc)
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.PENDING then
                assert.is_truthy(e.text:find("clean"))
                assert.is_truthy(e.text:find("bar%.sln"))
                return
            end
        end
    end)

    -- ─── expanded field option tests ────────────────────────────────────────

    it("no SETTINGS_OPTION entries when no field is expanded", function()
        local msvc = fake_msvc()
        local entries = UI._build_entries(msvc)
        for _, e in ipairs(entries) do
            assert.are_not.equal(UI._ENT.SETTINGS_OPTION, e.entity.type)
        end
    end)

    it("SETTINGS_OPTION entries appear below expanded field", function()
        local msvc = fake_msvc()
        UI._set_expanded_field("arch")
        local entries = UI._build_entries(msvc)
        local arch_pos, opt_values = nil, {}
        for i, e in ipairs(entries) do
            if e.entity.type == UI._ENT.SETTINGS_FIELD and e.entity.field == "arch" then
                arch_pos = i
            end
            if e.entity.type == UI._ENT.SETTINGS_OPTION and e.entity.field == "arch" then
                opt_values[#opt_values + 1] = e.entity.value
                assert.is_truthy(arch_pos and i > arch_pos)
            end
        end
        assert.is_true(#opt_values > 0, "expected arch option entries")
        local has_x64 = false
        for _, v in ipairs(opt_values) do
            if v == "x64" then has_x64 = true end
        end
        assert.is_true(has_x64)
    end)

    it("expanding a different field collapses the first", function()
        local msvc = fake_msvc()
        UI._set_expanded_field("arch")
        UI._set_expanded_field("vs_version")
        assert.are.equal("vs_version", UI._get_expanded_field())
        local entries = UI._build_entries(msvc)
        local has_arch_opt = false
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.SETTINGS_OPTION and e.entity.field == "arch" then
                has_arch_opt = true
            end
        end
        assert.is_false(has_arch_opt)
    end)

    it("v prefix marker appears on expanded field line", function()
        local msvc = fake_msvc()
        UI._set_expanded_field("jobs")
        local entries = UI._build_entries(msvc)
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.SETTINGS_FIELD and e.entity.field == "jobs" then
                assert.is_truthy(e.text:find("^v "))
                return
            end
        end
    end)

    it("> marker appears on currently-selected option", function()
        local msvc = fake_msvc({ settings = { arch = "arm64" } })
        UI._set_expanded_field("arch")
        local entries = UI._build_entries(msvc)
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.SETTINGS_OPTION and e.entity.value == "arm64" then
                assert.is_truthy(e.text:find("> "))
                return
            end
        end
        error("arm64 option not found")
    end)

    -- ─── solutions section — normal mode ────────────────────────────────────

    it("shows no SOLUTION entries when solutions is empty", function()
        local msvc = fake_msvc({ solutions = {} })
        local entries = UI._build_entries(msvc)
        for _, e in ipairs(entries) do
            assert.are_not.equal(UI._ENT.SOLUTION, e.entity.type)
        end
    end)

    it("one SOLUTION entry per registered solution", function()
        local msvc = fake_msvc({
            solutions = { "/a/foo.sln", "/b/bar.sln" },
        })
        local entries = UI._build_entries(msvc)
        local slns = {}
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.SOLUTION then
                slns[#slns + 1] = e.entity.path
            end
        end
        assert.are.equal(2, #slns)
    end)

    it("active solution marked with * prefix", function()
        local msvc = fake_msvc({
            solution = "/a/foo.sln",
            solutions = { "/a/foo.sln", "/b/bar.sln" },
        })
        local entries = UI._build_entries(msvc)
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.SOLUTION and e.entity.path == "/a/foo.sln" then
                assert.is_truthy(e.text:find("^%* "))
                return
            end
        end
        error("active solution not found in entries")
    end)

    -- ─── solutions section — add mode ───────────────────────────────────────

    it("add mode shows STAGED_HEADER and UNSTAGED_HEADER", function()
        local msvc = fake_msvc({ solutions = { "/a/foo.sln" } })
        UI._set_mode("add")
        UI._set_discovered({})
        local entries = UI._build_entries(msvc)
        local has_staged, has_unstaged = false, false
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.STAGED_HEADER then has_staged = true end
            if e.entity.type == UI._ENT.UNSTAGED_HEADER then has_unstaged = true end
        end
        assert.is_true(has_staged, "STAGED_HEADER missing in add mode")
        assert.is_true(has_unstaged, "UNSTAGED_HEADER missing in add mode")
    end)

    it("add mode staged group contains SOLUTION entries from msvc.solutions", function()
        local msvc = fake_msvc({ solutions = { "/a/foo.sln" } })
        UI._set_mode("add")
        UI._set_discovered({})
        local entries = UI._build_entries(msvc)
        local found = false
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.SOLUTION and e.entity.path == "/a/foo.sln" then
                found = true
            end
        end
        assert.is_true(found)
    end)

    it("add mode unstaged group contains SOLUTION_UNSTAGED entries from _discovered", function()
        local msvc = fake_msvc({ solutions = {} })
        UI._set_mode("add")
        UI._set_discovered({ "/b/bar.sln", "/c/baz.sln" })
        local entries = UI._build_entries(msvc)
        local found = {}
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.SOLUTION_UNSTAGED then
                found[e.entity.path] = true
            end
        end
        assert.is_truthy(found["/b/bar.sln"])
        assert.is_truthy(found["/c/baz.sln"])
    end)

    it("SOLUTION_UNSTAGED entries appear after UNSTAGED_HEADER", function()
        local msvc = fake_msvc({ solutions = {} })
        UI._set_mode("add")
        UI._set_discovered({ "/b/bar.sln" })
        local entries = UI._build_entries(msvc)
        local hdr_pos, ent_pos = nil, nil
        for i, e in ipairs(entries) do
            if e.entity.type == UI._ENT.UNSTAGED_HEADER then hdr_pos = i end
            if e.entity.type == UI._ENT.SOLUTION_UNSTAGED then ent_pos = i end
        end
        assert.is_truthy(hdr_pos)
        assert.is_truthy(ent_pos)
        assert.is_true(ent_pos > hdr_pos)
    end)

    it("STAGED_HEADER appears before UNSTAGED_HEADER", function()
        local msvc = fake_msvc({ solutions = {} })
        UI._set_mode("add")
        UI._set_discovered({})
        local entries = UI._build_entries(msvc)
        local staged_pos, unstaged_pos = nil, nil
        for i, e in ipairs(entries) do
            if e.entity.type == UI._ENT.STAGED_HEADER then staged_pos = i end
            if e.entity.type == UI._ENT.UNSTAGED_HEADER then unstaged_pos = i end
        end
        assert.is_truthy(staged_pos)
        assert.is_truthy(unstaged_pos)
        assert.is_true(staged_pos < unstaged_pos)
    end)

    it("normal mode has no STAGED_HEADER, UNSTAGED_HEADER, or SOLUTION_UNSTAGED", function()
        local msvc = fake_msvc({ solutions = { "/a/foo.sln" } })
        -- _mode defaults to "normal" after _reset()
        local entries = UI._build_entries(msvc)
        for _, e in ipairs(entries) do
            assert.are_not.equal(UI._ENT.STAGED_HEADER, e.entity.type)
            assert.are_not.equal(UI._ENT.UNSTAGED_HEADER, e.entity.type)
            assert.are_not.equal(UI._ENT.SOLUTION_UNSTAGED, e.entity.type)
        end
    end)

    -- ─── state mutation tests ─────────────────────────────────────────────

    it("_set_pending / _get_pending round-trips correctly", function()
        local p = { action = "rebuild", solution = "/s.sln", project = "/p.vcxproj", project_name = "P" }
        UI._set_pending(p)
        assert.are.same(p, UI._get_pending())
    end)

    it("_set_expanded_field / _get_expanded_field round-trips", function()
        UI._set_expanded_field("platform")
        assert.are.equal("platform", UI._get_expanded_field())
        UI._set_expanded_field(nil)
        assert.is_nil(UI._get_expanded_field())
    end)

    it("_set_mode / _get_mode round-trips", function()
        UI._set_mode("add")
        assert.are.equal("add", UI._get_mode())
        UI._set_mode("normal")
        assert.are.equal("normal", UI._get_mode())
    end)

    it("_set_discovered / _get_discovered round-trips", function()
        local d = { "/a/foo.sln", "/b/bar.sln" }
        UI._set_discovered(d)
        assert.are.same(d, UI._get_discovered())
    end)

    it("_reset clears all module state including mode and discovered", function()
        UI._set_pending({ action = "build", solution = "/s.sln" })
        UI._set_expanded_field("arch")
        UI._set_mode("add")
        UI._set_discovered({ "/a/foo.sln" })
        UI._reset()
        assert.is_nil(UI._get_pending())
        assert.is_nil(UI._get_expanded_field())
        assert.are.equal("normal", UI._get_mode())
        assert.are.same({}, UI._get_discovered())
    end)

    -- ─── project entries ─────────────────────────────────────────────────────

    it("PROJECT entries appear after their parent SOLUTION entry", function()
        local sln = "/a/foo.sln"
        local msvc = fake_msvc({ solutions = { sln } })
        local Discover = require("msvc.discover")
        local orig = Discover.parse_solution_projects
        Discover.parse_solution_projects = function(_)
            return { { name = "MyProj", path = "/a/src/MyProj.vcxproj" } }
        end
        local entries = UI._build_entries(msvc)
        Discover.parse_solution_projects = orig
        local sln_pos, proj_pos = nil, nil
        for i, e in ipairs(entries) do
            if e.entity.type == UI._ENT.SOLUTION and e.entity.path == sln then
                sln_pos = i
            end
            if e.entity.type == UI._ENT.PROJECT and e.entity.name == "MyProj" then
                proj_pos = i
            end
        end
        assert.is_truthy(sln_pos, "SOLUTION entry not found")
        assert.is_truthy(proj_pos, "PROJECT entry not found")
        assert.is_true(proj_pos > sln_pos, "PROJECT must appear after SOLUTION")
    end)

    it("pinned project is marked with '> ' prefix", function()
        local sln = "/a/foo.sln"
        local proj = "/a/src/MyProj.vcxproj"
        local msvc = fake_msvc({
            solution = sln,
            project = proj,
            solutions = { sln },
        })
        local Discover = require("msvc.discover")
        local orig = Discover.parse_solution_projects
        Discover.parse_solution_projects = function(_)
            return { { name = "MyProj", path = proj } }
        end
        local entries = UI._build_entries(msvc)
        Discover.parse_solution_projects = orig
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.PROJECT and e.entity.name == "MyProj" then
                assert.is_truthy(e.text:find("> "), "pinned project should have '> ' marker")
                return
            end
        end
        error("PROJECT entry for MyProj not found")
    end)

    it("non-pinned project has no '> ' marker", function()
        local sln = "/a/foo.sln"
        local msvc = fake_msvc({
            solution = sln,
            project = nil,
            solutions = { sln },
        })
        local Discover = require("msvc.discover")
        local orig = Discover.parse_solution_projects
        Discover.parse_solution_projects = function(_)
            return { { name = "UnpinnedProj", path = "/a/src/U.vcxproj" } }
        end
        local entries = UI._build_entries(msvc)
        Discover.parse_solution_projects = orig
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.PROJECT and e.entity.name == "UnpinnedProj" then
                assert.is_falsy(e.text:find("> "), "unpinned project should not have '> ' marker")
                return
            end
        end
        error("PROJECT entry for UnpinnedProj not found")
    end)

    it("compile_file pending action shows 'compile' and file basename in label", function()
        local msvc = fake_msvc()
        UI._set_pending({
            action = "compile_file",
            solution = "/s.sln",
            project = "/p.vcxproj",
            file = "/a/b/main.cpp",
        })
        local entries = UI._build_entries(msvc)
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.PENDING then
                assert.is_truthy(e.text:find("compile"))
                assert.is_truthy(e.text:find("main%.cpp"))
                return
            end
        end
        error("no PENDING entity found")
    end)

    -- ─── open() mode state ──────────────────────────────────────────────────
    -- Use real, normalized fixture paths so Util.normalize_path inside open()
    -- produces the same string we compare against.

    it("open() with mode='add' sets _mode to 'add' and populates _discovered", function()
        local Util = require("msvc.util")
        local sln = Util.normalize_path(
            Util.join_path(vim.fn.getcwd(), "tests/fixtures/burn-media/BurnMediaCli.sln")
        )
        local msvc = fake_msvc({ solutions = {} })
        UI.open(msvc, "add", { sln })
        assert.are.equal("add", UI._get_mode())
        local disc = UI._get_discovered()
        assert.are.equal(1, #disc)
        assert.are.equal(sln, disc[1])
        local b = UI._get_buf()
        if b and vim.api.nvim_buf_is_valid(b) then
            vim.api.nvim_buf_delete(b, { force = true })
        end
    end)

    it("open() filters already-staged solutions from _discovered", function()
        local Util = require("msvc.util")
        local staged = Util.normalize_path(
            Util.join_path(vim.fn.getcwd(), "tests/fixtures/sample.sln")
        )
        local unstaged = Util.normalize_path(
            Util.join_path(vim.fn.getcwd(), "tests/fixtures/burn-media/BurnMediaCli.sln")
        )
        local msvc = fake_msvc({ solutions = { staged } })
        UI.open(msvc, "add", { staged, unstaged })
        local disc = UI._get_discovered()
        assert.are.equal(1, #disc)
        assert.are.equal(unstaged, disc[1])
        local b = UI._get_buf()
        if b and vim.api.nvim_buf_is_valid(b) then
            vim.api.nvim_buf_delete(b, { force = true })
        end
    end)

    it("open() in normal mode clears _discovered even if called after add mode", function()
        local Util = require("msvc.util")
        local sln = Util.normalize_path(
            Util.join_path(vim.fn.getcwd(), "tests/fixtures/burn-media/BurnMediaCli.sln")
        )
        local msvc = fake_msvc({ solutions = {} })
        UI.open(msvc, "add", { sln })
        UI.open(msvc, "normal")
        assert.are.equal("normal", UI._get_mode())
        assert.are.same({}, UI._get_discovered())
        local b = UI._get_buf()
        if b and vim.api.nvim_buf_is_valid(b) then
            vim.api.nvim_buf_delete(b, { force = true })
        end
    end)

    -- ─── keymap interactions ─────────────────────────────────────────────────

    it("rebuild pending action shows action name in label", function()
        local msvc = fake_msvc()
        UI._set_pending({
            action = "rebuild",
            solution = "/a/app.sln",
            project = "/a/src/App.vcxproj",
            project_name = "App",
        })
        local entries = UI._build_entries(msvc)
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.PENDING then
                assert.is_truthy(e.text:find("rebuild"))
                assert.is_truthy(e.text:find("App"))
                return
            end
        end
        error("no PENDING entity found")
    end)

    -- ─── keymap interactions ─────────────────────────────────────────────────
    -- These tests drive real keymaps by feeding keys with nvim_feedkeys.

    describe("keymap interactions (burn-media fixture)", function()
        local burn_sln = "/fake/burn-media/BurnMediaCli.sln"

        -- Helper: set up a scratch buffer with rendered content and keymaps.
        -- Returns (buf, line_map).  Caller must clean up with buf_delete.
        local function setup_keymap_buf(msvc, mode, discovered)
            UI._reset()
            UI._set_mode(mode or "normal")
            if mode == "add" then
                local staged = {}
                for _, p in ipairs(msvc.solutions or {}) do
                    staged[p:lower()] = true
                end
                local disc = {}
                for _, p in ipairs(discovered or {}) do
                    if not staged[p:lower()] then
                        disc[#disc + 1] = p
                    end
                end
                UI._set_discovered(disc)
            end
            local buf = vim.api.nvim_create_buf(false, true)
            vim.bo[buf].buftype = "nofile"
            vim.bo[buf].bufhidden = "wipe"
            vim.bo[buf].swapfile = false
            UI._set_buf(buf)
            local entries = UI._build_entries(msvc)
            local lines, lm = {}, {}
            for i, e in ipairs(entries) do
                lines[i] = e.text
                lm[i] = e.entity
            end
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
            UI._set_line_map(lm)
            UI._setup_keymaps(msvc, buf)
            vim.cmd("split")
            vim.api.nvim_win_set_buf(0, buf)
            return buf, lm
        end

        local function feed(key)
            vim.api.nvim_feedkeys(
                vim.api.nvim_replace_termcodes(key, true, false, true),
                "x",
                false
            )
        end

        local function find_line(lm, pred)
            for i, e in ipairs(lm) do
                if pred(e) then return i end
            end
            return nil
        end

        after_each(function()
            local b = UI._get_buf()
            if b and vim.api.nvim_buf_is_valid(b) then
                vim.api.nvim_buf_delete(b, { force = true })
            end
            UI._reset()
        end)

        it("<CR> on SOLUTION activates it and re-renders", function()
            local msvc = fake_msvc({ solutions = { burn_sln } })
            local _, lm = setup_keymap_buf(msvc, "normal")
            local sol_line = find_line(lm, function(e)
                return e.type == UI._ENT.SOLUTION and e.path == burn_sln
            end)
            assert.is_truthy(sol_line, "SOLUTION line not found")
            vim.api.nvim_win_set_cursor(0, { sol_line, 0 })
            feed("<CR>")
            assert.are.equal(burn_sln, msvc.solution)
        end)

        it("<CR> on SOLUTION_UNSTAGED stages + activates and removes from _discovered", function()
            local msvc = fake_msvc({ solutions = {} })
            local _, lm = setup_keymap_buf(msvc, "add", { burn_sln })
            local sol_line = find_line(lm, function(e)
                return e.type == UI._ENT.SOLUTION_UNSTAGED and e.path == burn_sln
            end)
            assert.is_truthy(sol_line, "SOLUTION_UNSTAGED line not found")
            vim.api.nvim_win_set_cursor(0, { sol_line, 0 })
            feed("<CR>")
            assert.are.equal(burn_sln, msvc.solution)
            assert.are.equal(1, #msvc.solutions)
            assert.are.equal(0, #UI._get_discovered())
        end)

        it("- on SOLUTION_UNSTAGED stages it without activating", function()
            local msvc = fake_msvc({ solutions = {} })
            local _, lm = setup_keymap_buf(msvc, "add", { burn_sln })
            local sol_line = find_line(lm, function(e)
                return e.type == UI._ENT.SOLUTION_UNSTAGED and e.path == burn_sln
            end)
            assert.is_truthy(sol_line)
            vim.api.nvim_win_set_cursor(0, { sol_line, 0 })
            feed("-")
            assert.is_nil(msvc.solution, "- should not activate")
            assert.are.equal(1, #msvc.solutions, "should be staged")
            assert.are.equal(0, #UI._get_discovered(), "removed from discovered")
        end)

        it("- on staged SOLUTION removes it from solutions in normal mode", function()
            local msvc = fake_msvc({ solutions = { burn_sln } })
            local _, lm = setup_keymap_buf(msvc, "normal")
            local sol_line = find_line(lm, function(e)
                return e.type == UI._ENT.SOLUTION and e.path == burn_sln
            end)
            assert.is_truthy(sol_line)
            vim.api.nvim_win_set_cursor(0, { sol_line, 0 })
            feed("-")
            assert.are.equal(0, #msvc.solutions)
        end)

        it("- on staged SOLUTION in add mode moves it back to _discovered", function()
            local msvc = fake_msvc({ solutions = { burn_sln } })
            local _, lm = setup_keymap_buf(msvc, "add", {})
            local sol_line = find_line(lm, function(e)
                return e.type == UI._ENT.SOLUTION and e.path == burn_sln
            end)
            assert.is_truthy(sol_line)
            vim.api.nvim_win_set_cursor(0, { sol_line, 0 })
            feed("-")
            assert.are.equal(0, #msvc.solutions)
            local disc = UI._get_discovered()
            assert.are.equal(1, #disc)
            assert.are.equal(burn_sln, disc[1])
        end)

        it("- on active SOLUTION clears msvc.solution and msvc.project", function()
            local msvc = fake_msvc({
                solutions = { burn_sln },
                solution = burn_sln,
            })
            msvc.project = "/fake/P.vcxproj"
            local _, lm = setup_keymap_buf(msvc, "normal")
            local sol_line = find_line(lm, function(e)
                return e.type == UI._ENT.SOLUTION and e.path == burn_sln
            end)
            assert.is_truthy(sol_line)
            vim.api.nvim_win_set_cursor(0, { sol_line, 0 })
            feed("-")
            assert.is_nil(msvc.solution)
            assert.is_nil(msvc.project)
            assert.are.equal(0, #msvc.solutions)
        end)
    end)
end)
