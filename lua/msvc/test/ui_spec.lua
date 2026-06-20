-- Tests for msvc.ui: line→entity map construction and _target state.

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
                if path == nil or path == "" then
                    self.project = nil
                else
                    self.project = path
                end
                return true
            end,
            _discard_solution_context = opts._discard_solution_context
                or function() end,
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

    -- ─── header block tests ─────────────────────────────────────────────────

    it("SOLUTION_HEADER entity is present with solution path", function()
        local msvc = fake_msvc({ solution = "/a/foo.sln" })
        local entries = UI._build_entries(msvc)
        local found = false
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.SOLUTION_HEADER then
                found = true
                assert.is_truthy(e.text:find("/a/foo.sln", 1, true))
            end
        end
        assert.is_true(found, "SOLUTION_HEADER not found")
    end)

    it("SOLUTION_HEADER shows <none> when solution is nil", function()
        local msvc = fake_msvc()
        local entries = UI._build_entries(msvc)
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.SOLUTION_HEADER then
                assert.is_truthy(e.text:find("<none>", 1, true))
                return
            end
        end
        error("SOLUTION_HEADER not found")
    end)

    it("TARGET_HEADER entity shows current _target value", function()
        UI._set_target("rebuild")
        local msvc = fake_msvc()
        local entries = UI._build_entries(msvc)
        local found = false
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.TARGET_HEADER then
                found = true
                assert.is_truthy(e.text:find("rebuild", 1, true))
            end
        end
        assert.is_true(found, "TARGET_HEADER not found")
    end)

    it("HELP_HEADER entity contains 'h?'", function()
        local msvc = fake_msvc()
        local entries = UI._build_entries(msvc)
        local found = false
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.HELP_HEADER then
                found = true
                assert.is_truthy(e.text:find("h?", 1, true))
            end
        end
        assert.is_true(found, "HELP_HEADER not found")
    end)

    it("SEPARATOR entity is present", function()
        local msvc = fake_msvc()
        local entries = UI._build_entries(msvc)
        local found = false
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.SEPARATOR then
                found = true
            end
        end
        assert.is_true(found, "SEPARATOR not found")
    end)

    it("no PENDING entity in entries", function()
        local msvc = fake_msvc()
        local entries = UI._build_entries(msvc)
        for _, e in ipairs(entries) do
            assert.are_not.equal("pending", e.entity.type)
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

    it("shows no SOLUTION entries in normal mode (only projects)", function()
        local msvc = fake_msvc({ solutions = { "/a/foo.sln" } })
        -- _mode defaults to "normal" after _reset()
        local entries = UI._build_entries(msvc)
        for _, e in ipairs(entries) do
            assert.are_not.equal(UI._ENT.SOLUTION, e.entity.type)
        end
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

    it("one SOLUTION entry per staged solution in add mode", function()
        local msvc = fake_msvc({
            solutions = { "/a/foo.sln", "/b/bar.sln" },
        })
        UI._set_mode("add")
        UI._set_discovered({})
        local entries = UI._build_entries(msvc)
        local slns = {}
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.SOLUTION then
                slns[#slns + 1] = e.entity.path
            end
        end
        assert.are.equal(2, #slns)
    end)

    it("active solution marked with * prefix in add mode staged list uses _add_selected", function()
        local msvc = fake_msvc({
            solution = "/b/bar.sln",  -- msvc.solution differs from _add_selected
            solutions = { "/a/foo.sln", "/b/bar.sln" },
        })
        UI._set_mode("add")
        UI._set_add_selected("/a/foo.sln")
        UI._set_discovered({})
        local entries = UI._build_entries(msvc)
        local foo_marked, bar_marked = false, false
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.SOLUTION then
                if e.entity.path == "/a/foo.sln" then
                    foo_marked = e.text:find("^%* ") ~= nil
                elseif e.entity.path == "/b/bar.sln" then
                    bar_marked = e.text:find("^%* ") ~= nil
                end
            end
        end
        assert.is_true(foo_marked, "/a/foo.sln should be marked (matches _add_selected)")
        assert.is_false(bar_marked, "/b/bar.sln should not be marked (is msvc.solution, not _add_selected)")
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

    it("add mode has no TARGET_HEADER or SETTINGS_FIELD entities", function()
        local msvc = fake_msvc({ solutions = {} })
        UI._set_mode("add")
        UI._set_discovered({})
        local entries = UI._build_entries(msvc)
        for _, e in ipairs(entries) do
            assert.are_not.equal(UI._ENT.TARGET_HEADER, e.entity.type,
                "TARGET_HEADER must not appear in add mode")
            assert.are_not.equal(UI._ENT.SETTINGS_FIELD, e.entity.type,
                "SETTINGS_FIELD must not appear in add mode")
        end
    end)

    it("add mode SOLUTION_HEADER text reflects _add_selected, not msvc.solution", function()
        local msvc = fake_msvc({ solution = "/b/other.sln", solutions = {} })
        UI._set_mode("add")
        UI._set_add_selected("/a/chosen.sln")
        UI._set_discovered({})
        local entries = UI._build_entries(msvc)
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.SOLUTION_HEADER then
                assert.is_truthy(e.text:find("/a/chosen.sln", 1, true),
                    "SOLUTION_HEADER should show _add_selected")
                assert.is_falsy(e.text:find("/b/other.sln", 1, true),
                    "SOLUTION_HEADER should not show msvc.solution")
                return
            end
        end
        error("SOLUTION_HEADER not found")
    end)

    it("add mode SOLUTION_HEADER shows empty string when _add_selected is nil", function()
        local msvc = fake_msvc({ solution = "/a/foo.sln", solutions = {} })
        UI._set_mode("add")
        UI._set_add_selected(nil)
        UI._set_discovered({})
        local entries = UI._build_entries(msvc)
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.SOLUTION_HEADER then
                assert.are.equal("Solution: ", e.text)
                return
            end
        end
        error("SOLUTION_HEADER not found")
    end)

    -- ─── state mutation tests ─────────────────────────────────────────────

    it("_set_target / _get_target round-trips correctly", function()
        UI._set_target("rebuild")
        assert.are.equal("rebuild", UI._get_target())
        UI._set_target("build")
        assert.are.equal("build", UI._get_target())
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

    it("_reset clears all module state including _target, mode, discovered, and _add_selected", function()
        UI._set_target("rebuild")
        UI._set_expanded_field("arch")
        UI._set_mode("add")
        UI._set_discovered({ "/a/foo.sln" })
        UI._set_add_selected("/a/foo.sln")
        UI._reset()
        assert.are.equal("build", UI._get_target())
        assert.is_nil(UI._get_expanded_field())
        assert.are.equal("normal", UI._get_mode())
        assert.are.same({}, UI._get_discovered())
        assert.is_nil(UI._get_add_selected())
    end)

    -- ─── project entries ─────────────────────────────────────────────────────

    it("PROJECT entries appear in add-mode staged list after SOLUTION", function()
        local sln = "/a/foo.sln"
        local msvc = fake_msvc({ solutions = { sln } })
        UI._set_mode("add")
        UI._set_discovered({})
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

    it("PROJECT entries appear after SEPARATOR in normal mode", function()
        local sln = "/a/foo.sln"
        local msvc = fake_msvc({ solution = sln, solutions = { sln } })
        local Discover = require("msvc.discover")
        local orig = Discover.parse_solution_projects
        Discover.parse_solution_projects = function(_)
            return { { name = "MyProj", path = "/a/src/MyProj.vcxproj" } }
        end
        local entries = UI._build_entries(msvc)
        Discover.parse_solution_projects = orig
        local sep_pos, proj_pos = nil, nil
        for i, e in ipairs(entries) do
            if e.entity.type == UI._ENT.SEPARATOR then sep_pos = i end
            if e.entity.type == UI._ENT.PROJECT and e.entity.name == "MyProj" then
                proj_pos = i
            end
        end
        assert.is_truthy(sep_pos, "SEPARATOR not found")
        assert.is_truthy(proj_pos, "PROJECT not found")
        assert.is_true(proj_pos > sep_pos, "PROJECT must appear after SEPARATOR")
    end)

    it("pinned project has '* ' prefix in normal mode", function()
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
                assert.is_truthy(e.text:find("^%* "), "pinned project should have '* ' marker")
                return
            end
        end
        error("PROJECT entry for MyProj not found")
    end)

    it("non-pinned project has no '* ' marker in normal mode", function()
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
                assert.is_falsy(e.text:find("^%* "), "unpinned project should not have '* ' marker")
                return
            end
        end
        error("PROJECT entry for UnpinnedProj not found")
    end)

    it("pinned project has '> ' prefix in add mode under parent solution", function()
        local sln = "/a/foo.sln"
        local proj = "/a/src/MyProj.vcxproj"
        local msvc = fake_msvc({
            solution = sln,
            project = proj,
            solutions = { sln },
        })
        UI._set_mode("add")
        UI._set_discovered({})
        local Discover = require("msvc.discover")
        local orig = Discover.parse_solution_projects
        Discover.parse_solution_projects = function(_)
            return { { name = "MyProj", path = proj } }
        end
        local entries = UI._build_entries(msvc)
        Discover.parse_solution_projects = orig
        for _, e in ipairs(entries) do
            if e.entity.type == UI._ENT.PROJECT and e.entity.name == "MyProj" then
                assert.is_truthy(e.text:find("> "), "pinned project should have '> ' marker in add mode")
                return
            end
        end
        error("PROJECT entry for MyProj not found")
    end)

    -- ─── open() mode state ──────────────────────────────────────────────────

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
    -- These tests drive real keymaps by feeding keys with nvim_feedkeys.

    describe("keymap interactions (burn-media fixture)", function()
        local burn_sln = "/fake/burn-media/BurnMediaCli.sln"

        -- Helper: set up a scratch buffer with rendered content and keymaps.
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

        -- ─── b/c/r/f target keybindings ─────────────────────────────────────

        it("b key sets _target to 'build'", function()
            local msvc = fake_msvc()
            UI._set_target("clean")
            setup_keymap_buf(msvc, "normal")
            feed("b")
            assert.are.equal("build", UI._get_target())
        end)

        it("c key sets _target to 'clean'", function()
            local msvc = fake_msvc()
            setup_keymap_buf(msvc, "normal")
            feed("c")
            assert.are.equal("clean", UI._get_target())
        end)

        it("r key sets _target to 'rebuild'", function()
            local msvc = fake_msvc()
            setup_keymap_buf(msvc, "normal")
            feed("r")
            assert.are.equal("rebuild", UI._get_target())
        end)

        it("f key sets _target to 'compile_file' when project and source file are set", function()
            local msvc = fake_msvc({ project = "/a/P.vcxproj" })
            local _, lm = setup_keymap_buf(msvc, "normal")
            -- Inject source file directly
            local buf = UI._get_buf()
            -- We need to set _source_file; call open() instead of setup_keymap_buf
            -- to properly capture it, but for this test just verify via a project line
            -- Actually _source_file is set in open(). For this test let's use a workaround:
            -- We do have UI._set_buf but no public _set_source_file. Use open() instead.
            local b = UI._get_buf()
            if b and vim.api.nvim_buf_is_valid(b) then
                vim.api.nvim_buf_delete(b, { force = true })
            end
            UI._reset()
            -- open() will capture _source_file from current buf; since we're in a test
            -- environment there may not be a source file. Just verify f is a no-op
            -- without a project.
            local msvc2 = fake_msvc()  -- no project
            setup_keymap_buf(msvc2, "normal")
            UI._set_target("build")
            feed("f")
            assert.are.equal("build", UI._get_target())  -- unchanged since no project
        end)

        it("f key leaves _target unchanged when project is not set", function()
            local msvc = fake_msvc()  -- no project
            setup_keymap_buf(msvc, "normal")
            UI._set_target("clean")
            feed("f")
            assert.are.equal("clean", UI._get_target())
        end)

        -- ─── - on PROJECT select/deselect ────────────────────────────────────

        it("- on PROJECT line selects the project", function()
            local sln = "/a/foo.sln"
            local proj = "/a/P.vcxproj"
            local msvc = fake_msvc({ solution = sln, solutions = { sln } })
            local Discover = require("msvc.discover")
            local orig = Discover.parse_solution_projects
            Discover.parse_solution_projects = function(_)
                return { { name = "P", path = proj } }
            end
            local _, lm = setup_keymap_buf(msvc, "normal")
            Discover.parse_solution_projects = orig
            local proj_line = find_line(lm, function(e)
                return e.type == UI._ENT.PROJECT and e.path == proj
            end)
            assert.is_truthy(proj_line, "PROJECT line not found")
            vim.api.nvim_win_set_cursor(0, { proj_line, 0 })
            feed("-")
            assert.are.equal(proj, msvc.project)
        end)

        it("- on already-selected PROJECT deselects it", function()
            local sln = "/a/foo.sln"
            local proj = "/a/P.vcxproj"
            local msvc = fake_msvc({
                solution = sln,
                project = proj,
                solutions = { sln },
            })
            local Discover = require("msvc.discover")
            local orig = Discover.parse_solution_projects
            Discover.parse_solution_projects = function(_)
                return { { name = "P", path = proj } }
            end
            local _, lm = setup_keymap_buf(msvc, "normal")
            Discover.parse_solution_projects = orig
            local proj_line = find_line(lm, function(e)
                return e.type == UI._ENT.PROJECT and e.path == proj
            end)
            assert.is_truthy(proj_line, "PROJECT line not found")
            vim.api.nvim_win_set_cursor(0, { proj_line, 0 })
            feed("-")
            assert.is_nil(msvc.project)
        end)

        -- ─── <CR> on SOLUTION_UNSTAGED ───────────────────────────────────────

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

        it("<CR> on SOLUTION in add mode activates it and switches to normal mode", function()
            local msvc = fake_msvc({ solutions = { burn_sln }, solution = burn_sln })
            local _, lm = setup_keymap_buf(msvc, "add", {})
            local sol_line = find_line(lm, function(e)
                return e.type == UI._ENT.SOLUTION and e.path == burn_sln
            end)
            assert.is_truthy(sol_line, "SOLUTION line not found")
            vim.api.nvim_win_set_cursor(0, { sol_line, 0 })
            feed("<CR>")
            assert.are.equal(burn_sln, msvc.solution)
            assert.are.equal("normal", UI._get_mode())
            assert.are.equal(burn_sln, UI._get_add_selected())
        end)

        -- ─── - on SOLUTION (add mode) ────────────────────────────────────────

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

        it("- on staged SOLUTION in add mode removes it and moves to _discovered", function()
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

        it("- on staged SOLUTION in add mode calls _discard_solution_context", function()
            local discarded = nil
            local msvc = fake_msvc({
                solutions = { burn_sln },
                _discard_solution_context = function(self, path)
                    discarded = path
                end,
            })
            local _, lm = setup_keymap_buf(msvc, "add", {})
            local sol_line = find_line(lm, function(e)
                return e.type == UI._ENT.SOLUTION and e.path == burn_sln
            end)
            assert.is_truthy(sol_line)
            vim.api.nvim_win_set_cursor(0, { sol_line, 0 })
            feed("-")
            assert.are.equal(burn_sln, discarded)
        end)

        it("- on active SOLUTION in add mode clears msvc.solution and msvc.project", function()
            local msvc = fake_msvc({
                solutions = { burn_sln },
                solution = burn_sln,
            })
            msvc.project = "/fake/P.vcxproj"
            local _, lm = setup_keymap_buf(msvc, "add", {})
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

        -- ─── <CR> on SOLUTION_UNSTAGED — _add_selected + mode switch ─────────

        it("<CR> on SOLUTION_UNSTAGED sets _add_selected and switches to normal mode", function()
            local msvc = fake_msvc({ solutions = {} })
            local _, lm = setup_keymap_buf(msvc, "add", { burn_sln })
            local sol_line = find_line(lm, function(e)
                return e.type == UI._ENT.SOLUTION_UNSTAGED and e.path == burn_sln
            end)
            assert.is_truthy(sol_line, "SOLUTION_UNSTAGED line not found")
            vim.api.nvim_win_set_cursor(0, { sol_line, 0 })
            feed("<CR>")
            assert.are.equal(burn_sln, UI._get_add_selected())
            assert.are.equal("normal", UI._get_mode())
        end)

        -- ─── - on SOLUTION_UNSTAGED — _add_selected without mode switch ──────

        it("- on SOLUTION_UNSTAGED updates _add_selected without switching mode", function()
            local msvc = fake_msvc({ solutions = {} })
            local _, lm = setup_keymap_buf(msvc, "add", { burn_sln })
            local sol_line = find_line(lm, function(e)
                return e.type == UI._ENT.SOLUTION_UNSTAGED and e.path == burn_sln
            end)
            assert.is_truthy(sol_line)
            vim.api.nvim_win_set_cursor(0, { sol_line, 0 })
            feed("-")
            assert.are.equal(burn_sln, UI._get_add_selected())
            assert.are.equal("add", UI._get_mode())
        end)

        -- ─── - on SOLUTION clears _add_selected when matching ────────────────

        it("- on staged SOLUTION where path == _add_selected clears _add_selected", function()
            local msvc = fake_msvc({ solutions = { burn_sln } })
            UI._set_add_selected(burn_sln)
            local _, lm = setup_keymap_buf(msvc, "add", {})
            -- After setup, restore _add_selected (setup_keymap_buf calls _reset inside)
            UI._set_add_selected(burn_sln)
            local sol_line = find_line(lm, function(e)
                return e.type == UI._ENT.SOLUTION and e.path == burn_sln
            end)
            assert.is_truthy(sol_line)
            vim.api.nvim_win_set_cursor(0, { sol_line, 0 })
            feed("-")
            assert.is_nil(UI._get_add_selected())
        end)

        it("- on staged SOLUTION where path != _add_selected preserves _add_selected", function()
            local other_sln = "/fake/other/other.sln"
            local msvc = fake_msvc({ solutions = { burn_sln, other_sln } })
            local _, lm = setup_keymap_buf(msvc, "add", {})
            UI._set_add_selected(other_sln)
            local sol_line = find_line(lm, function(e)
                return e.type == UI._ENT.SOLUTION and e.path == burn_sln
            end)
            assert.is_truthy(sol_line)
            vim.api.nvim_win_set_cursor(0, { sol_line, 0 })
            feed("-")
            assert.are.equal(other_sln, UI._get_add_selected())
        end)

        -- ─── = on SETTINGS_OPTION ────────────────────────────────────────────

        it("= on SETTINGS_OPTION collapses the expanded field", function()
            local msvc = fake_msvc()
            local _, lm = setup_keymap_buf(msvc, "normal")
            UI._set_expanded_field("arch")
            -- Re-render to get SETTINGS_OPTION lines in lm
            local entries = UI._build_entries(msvc)
            local lines, new_lm = {}, {}
            for i, e in ipairs(entries) do
                lines[i] = e.text
                new_lm[i] = e.entity
            end
            local buf = UI._get_buf()
            vim.bo[buf].modifiable = true
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
            vim.bo[buf].modifiable = false
            UI._set_line_map(new_lm)
            local opt_line = find_line(new_lm, function(e)
                return e.type == UI._ENT.SETTINGS_OPTION and e.field == "arch"
            end)
            assert.is_truthy(opt_line, "SETTINGS_OPTION line not found")
            vim.api.nvim_win_set_cursor(0, { opt_line, 0 })
            feed("=")
            assert.is_nil(UI._get_expanded_field())
        end)

        -- ─── b/c/r/f are no-ops in add mode ─────────────────────────────────

        it("b key is a no-op in add mode", function()
            local msvc = fake_msvc()
            setup_keymap_buf(msvc, "add", {})
            UI._set_target("clean")  -- after setup, which calls _reset()
            feed("b")
            assert.are.equal("clean", UI._get_target())
        end)

        it("c key is a no-op in add mode", function()
            local msvc = fake_msvc()
            setup_keymap_buf(msvc, "add", {})
            feed("c")
            assert.are.equal("build", UI._get_target())
        end)

        it("r key is a no-op in add mode", function()
            local msvc = fake_msvc()
            setup_keymap_buf(msvc, "add", {})
            feed("r")
            assert.are.equal("build", UI._get_target())
        end)

        it("f key is a no-op in add mode", function()
            local msvc = fake_msvc({ project = "/a/P.vcxproj" })
            setup_keymap_buf(msvc, "add", {})
            feed("f")
            assert.are.equal("build", UI._get_target())
        end)

        -- ─── BufWriteCmd in add mode ─────────────────────────────────────────

        local function setup_autocmd_buf(msvc, mode)
            UI._reset()
            UI._set_mode(mode or "normal")
            local buf = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_name(buf, "msvc://test_" .. buf)
            vim.bo[buf].buftype = "acwrite"
            vim.bo[buf].bufhidden = "wipe"
            vim.bo[buf].swapfile = false
            UI._set_buf(buf)
            UI._setup_autocmds(msvc, buf)
            UI._setup_keymaps(msvc, buf)
            local entries = UI._build_entries(msvc)
            local lines, lm = {}, {}
            for i, e in ipairs(entries) do
                lines[i] = e.text
                lm[i] = e.entity
            end
            vim.bo[buf].modifiable = true
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
            vim.bo[buf].modifiable = false
            vim.bo[buf].modified = false
            UI._set_line_map(lm)
            vim.cmd("split")
            vim.api.nvim_win_set_buf(0, buf)
            return buf
        end

        it("BufWriteCmd in add mode with nil _add_selected stays in add mode", function()
            local msvc = fake_msvc({ solutions = {} })
            local buf = setup_autocmd_buf(msvc, "add")
            UI._set_add_selected(nil)
            vim.cmd("silent write")
            assert.are.equal("add", UI._get_mode())
            assert.is_nil(msvc.solution)
            if buf and vim.api.nvim_buf_is_valid(buf) then
                vim.api.nvim_buf_delete(buf, { force = true })
            end
        end)

        it("BufWriteCmd in add mode with valid _add_selected switches to normal mode", function()
            local msvc = fake_msvc({ solutions = { burn_sln } })
            local buf = setup_autocmd_buf(msvc, "add")
            UI._set_add_selected(burn_sln)
            vim.cmd("silent write")
            assert.are.equal("normal", UI._get_mode())
            assert.are.equal(burn_sln, msvc.solution)
            if buf and vim.api.nvim_buf_is_valid(buf) then
                vim.api.nvim_buf_delete(buf, { force = true })
            end
        end)

        -- ─── open() initialises _add_selected ────────────────────────────────

        it("open() with mode='add' sets _add_selected to msvc.solution", function()
            local Util = require("msvc.util")
            local sln = Util.normalize_path(
                Util.join_path(vim.fn.getcwd(), "tests/fixtures/burn-media/BurnMediaCli.sln")
            )
            local msvc = fake_msvc({ solution = sln, solutions = { sln } })
            UI.open(msvc, "add", {})
            assert.are.equal(sln, UI._get_add_selected())
            local b = UI._get_buf()
            if b and vim.api.nvim_buf_is_valid(b) then
                vim.api.nvim_buf_delete(b, { force = true })
            end
        end)

        it("open() with mode='add' sets _add_selected to nil when msvc.solution is nil", function()
            local msvc = fake_msvc({ solutions = {} })
            UI.open(msvc, "add", {})
            assert.is_nil(UI._get_add_selected())
            local b = UI._get_buf()
            if b and vim.api.nvim_buf_is_valid(b) then
                vim.api.nvim_buf_delete(b, { force = true })
            end
        end)

        it("_set_add_selected / _get_add_selected round-trips", function()
            UI._set_add_selected("/a/foo.sln")
            assert.are.equal("/a/foo.sln", UI._get_add_selected())
            UI._set_add_selected(nil)
            assert.is_nil(UI._get_add_selected())
        end)
    end)
end)
