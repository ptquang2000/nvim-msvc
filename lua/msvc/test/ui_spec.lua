-- Tests for msvc.ui: line→entity map construction and pending-action state.

local helpers = require("msvc.test.utils")

describe("msvc.ui", function()
    local UI, Config

    before_each(function()
        helpers.reset()
        UI = require("msvc.ui")
        Config = require("msvc.config")
        UI._reset()
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
            solution_candidates = opts.solution_candidates or {},
            solution_projects = opts.solution_projects or {},
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
                -- must come after the field line
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

    -- ─── solutions section tests ─────────────────────────────────────────────

    it("shows no SOLUTION entries when solution_candidates is empty", function()
        local msvc = fake_msvc({ solution_candidates = {} })
        local entries = UI._build_entries(msvc)
        for _, e in ipairs(entries) do
            assert.are_not.equal(UI._ENT.SOLUTION, e.entity.type)
        end
    end)

    it("one SOLUTION entry per candidate", function()
        local msvc = fake_msvc({
            solution_candidates = { "/a/foo.sln", "/b/bar.sln" },
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
            solution_candidates = { "/a/foo.sln", "/b/bar.sln" },
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

    it("_reset clears all module state", function()
        UI._set_pending({ action = "build", solution = "/s.sln" })
        UI._set_expanded_field("arch")
        UI._reset()
        assert.is_nil(UI._get_pending())
        assert.is_nil(UI._get_expanded_field())
    end)

    -- ─── project entries ─────────────────────────────────────────────────────

    it("PROJECT entries appear after their parent SOLUTION entry", function()
        local sln = "/a/foo.sln"
        local msvc = fake_msvc({ solution_candidates = { sln } })
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
            solution_candidates = { sln },
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
            solution_candidates = { sln },
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
end)
