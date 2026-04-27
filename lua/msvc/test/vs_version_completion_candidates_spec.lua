local TestUtils = require("msvc.test.utils")

-- Strict completion-candidate rules for vs_version after BUG 2 fix:
--   * "latest" sentinel always present
--   * full installationVersion per install
--   * canonical major-range "[N.0,(N+1).0)" per unique major
--   * marketing-year (productLineVersion) and bare-major are NOT suggested
describe("msvc._populate_vs_completion_candidates", function()
    before_each(function()
        TestUtils.reset()
    end)

    local INSTALLS = {
        {
            installationVersion = "17.9.34728.123",
            productId = "Microsoft.VisualStudio.Product.Community",
            catalog = { productLineVersion = "2022" },
            packages = {
                {
                    id = "Microsoft.VisualStudio.Component.VC.ATL",
                    type = "Component",
                },
                {
                    id = "Microsoft.VisualStudio.Workload.NativeDesktop",
                    type = "Workload",
                },
                { id = "Some.Vsix.Package", type = "Vsix" },
            },
        },
        {
            installationVersion = "16.11.50",
            productId = "Microsoft.VisualStudio.Product.BuildTools",
            catalog = { productLineVersion = "2019" },
            packages = {
                {
                    id = "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
                    type = "Component",
                },
            },
        },
    }

    local function vset(c)
        local s = {}
        for _, v in ipairs(c.vs_version) do
            s[v] = true
        end
        return s
    end

    it(
        "includes 'latest' sentinel and full installationVersion entries",
        function()
            local msvc = require("msvc")
            msvc:_populate_vs_completion_candidates(INSTALLS)
            local s = vset(msvc.vs_completion_candidates)
            assert.is_true(s["latest"])
            assert.is_true(s["17.9.34728.123"])
            assert.is_true(s["16.11.50"])
        end
    )

    it("includes [N.0,(N+1).0) range per unique major", function()
        local msvc = require("msvc")
        msvc:_populate_vs_completion_candidates(INSTALLS)
        local s = vset(msvc.vs_completion_candidates)
        assert.is_true(s["[17.0,18.0)"])
        assert.is_true(s["[16.0,17.0)"])
    end)

    it("does NOT include marketing year (productLineVersion)", function()
        local msvc = require("msvc")
        msvc:_populate_vs_completion_candidates(INSTALLS)
        local s = vset(msvc.vs_completion_candidates)
        assert.is_nil(s["2022"])
        assert.is_nil(s["2019"])
        assert.is_nil(s["2017"])
        assert.is_nil(s["2015"])
    end)

    it("does NOT include bare-major shorthand", function()
        local msvc = require("msvc")
        msvc:_populate_vs_completion_candidates(INSTALLS)
        local s = vset(msvc.vs_completion_candidates)
        assert.is_nil(s["14"])
        assert.is_nil(s["15"])
        assert.is_nil(s["16"])
        assert.is_nil(s["17"])
        assert.is_nil(s["18"])
    end)

    it(
        "de-duplicates ranges across multiple installs of the same major",
        function()
            local msvc = require("msvc")
            msvc:_populate_vs_completion_candidates({
                { installationVersion = "17.9.0" },
                { installationVersion = "17.14.37216.2" },
                { installationVersion = "17.0.1" },
            })
            local count = 0
            for _, v in ipairs(msvc.vs_completion_candidates.vs_version) do
                if v == "[17.0,18.0)" then
                    count = count + 1
                end
            end
            assert.equals(1, count)
        end
    )

    it("sort order: latest first, then majors descending", function()
        local msvc = require("msvc")
        msvc:_populate_vs_completion_candidates(INSTALLS)
        local list = msvc.vs_completion_candidates.vs_version
        assert.equals("latest", list[1])
        -- The next non-latest entry must have the highest major (17).
        assert.is_truthy(list[2]:match("^%[?17"))
    end)

    it("empty install list yields { 'latest' } only on vs_version", function()
        local msvc = require("msvc")
        msvc:_populate_vs_completion_candidates({})
        local c = msvc.vs_completion_candidates
        assert.same({ "latest" }, c.vs_version)
        assert.equals(4, #c.vs_products)
        assert.same({}, c.vs_requires)
    end)

    it("vs_prerelease stays static {'false','true'}", function()
        local msvc = require("msvc")
        msvc:_populate_vs_completion_candidates(INSTALLS)
        assert.same(
            { "false", "true" },
            msvc.vs_completion_candidates.vs_prerelease
        )
    end)

    it(
        "vs_products picks up productId and de-dups against the static four",
        function()
            local msvc = require("msvc")
            msvc:_populate_vs_completion_candidates(INSTALLS)
            local pset = {}
            for _, v in ipairs(msvc.vs_completion_candidates.vs_products) do
                pset[v] = true
            end
            assert.is_true(pset["Microsoft.VisualStudio.Product.Community"])
            assert.is_true(pset["Microsoft.VisualStudio.Product.BuildTools"])
            assert.is_true(pset["Microsoft.VisualStudio.Product.Enterprise"])
            assert.is_true(pset["Microsoft.VisualStudio.Product.Professional"])
        end
    )

    it(
        "vs_requires is union of Component+Workload (no Vsix), sorted",
        function()
            local msvc = require("msvc")
            msvc:_populate_vs_completion_candidates(INSTALLS)
            assert.same({
                "Microsoft.VisualStudio.Component.VC.ATL",
                "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
                "Microsoft.VisualStudio.Workload.NativeDesktop",
            }, msvc.vs_completion_candidates.vs_requires)
        end
    )
end)
