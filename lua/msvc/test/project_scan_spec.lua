local TestUtils = require("msvc.test.utils")

describe("msvc.project_scan", function()
    before_each(function()
        TestUtils.reset()
    end)

    local function fixture(name)
        return vim.fn.getcwd() .. "/tests/fixtures/" .. name
    end

    it(
        "parse_sln captures every SolutionConfigurationPlatforms tuple",
        function()
            local PS = require("msvc.project_scan")
            local content = PS.read_file(fixture("sample.sln"))
            assert.is_truthy(content)
            local pairs_ = PS.parse_sln(content)
            assert.equals(5, #pairs_)
            local seen = {}
            for _, p in ipairs(pairs_) do
                seen[p[1] .. "|" .. p[2]] = true
            end
            assert.is_true(seen["Debug|x64"])
            assert.is_true(seen["Debug|Win32"])
            assert.is_true(seen["Release|x64"])
            assert.is_true(seen["Release|Win32"])
            assert.is_true(seen["ReleaseCTR|ARM64"])
        end
    )

    it(
        "parse_vcxproj captures every ProjectConfiguration tuple including Any CPU",
        function()
            local PS = require("msvc.project_scan")
            local content = PS.read_file(fixture("sample.vcxproj"))
            assert.is_truthy(content)
            local pairs_ = PS.parse_vcxproj(content)
            assert.equals(5, #pairs_)
            local seen = {}
            for _, p in ipairs(pairs_) do
                seen[p[1] .. "|" .. p[2]] = true
            end
            assert.is_true(seen["debug_static|Any CPU"])
            assert.is_true(seen["Debug|Win32"])
        end
    )

    it(
        "dedup_sort returns sorted unique configurations and platforms",
        function()
            local PS = require("msvc.project_scan")
            local result = PS.dedup_sort({
                { "Debug", "x64" },
                { "Release", "Win32" },
                { "Debug", "Win32" },
                { "Debug", "Any CPU" },
                { "ReleaseCTR", "ARM64" },
            })
            assert.same(
                { "Debug", "Release", "ReleaseCTR" },
                result.configurations
            )
            assert.same(
                { "ARM64", "Any CPU", "Win32", "x64" },
                result.platforms
            )
        end
    )

    it("fallback_defaults returns the static minimal list", function()
        local PS = require("msvc.project_scan")
        local fb = PS.fallback_defaults()
        assert.same({ "Debug", "Release" }, fb.configurations)
        assert.same({ "Win32", "x64" }, fb.platforms)
    end)
end)
