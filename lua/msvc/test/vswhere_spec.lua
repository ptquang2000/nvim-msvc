local helpers = require("msvc.test.utils")

describe("msvc.vswhere", function()
    local VsWhere

    before_each(function()
        helpers.reset()
        VsWhere = require("msvc.vswhere")
    end)

    describe("translate_version", function()
        local t = function(v)
            return VsWhere._translate_version(v)
        end

        it("returns nil for nil/empty/latest", function()
            assert.is_nil(t(nil))
            assert.is_nil(t(""))
            assert.is_nil(t("latest"))
        end)

        it("translates marketing year tokens", function()
            assert.are.equal("[15.0,16.0)", t("2017"))
            assert.are.equal("[16.0,17.0)", t("2019"))
            assert.are.equal("[17.0,18.0)", t("2022"))
        end)

        it("translates single-component to range", function()
            assert.are.equal("[17.0,18.0)", t("17"))
        end)

        it("translates two-component to minor range", function()
            assert.are.equal("[17.10,17.11)", t("17.10"))
        end)

        it("formats multi-component as exact range", function()
            assert.are.equal(
                "[15.9.37202.19,15.9.37202.19]",
                t("15.9.37202.19")
            )
        end)

        it("passes through pre-formatted ranges", function()
            assert.are.equal("[16.0,17.0)", t("[16.0,17.0)"))
        end)
    end)

    describe("build_args", function()
        it("includes -all and -products * by default", function()
            local args = VsWhere._build_args({})
            assert.are.equal("-products", args[1])
            assert.are.equal("*", args[2])
            assert.are.equal("-all", args[3])
        end)

        it("expands vs_products and vs_requires", function()
            local args = VsWhere._build_args({
                vs_products = { "P1", "P2" },
                vs_requires = { "R1" },
                vs_prerelease = true,
                vs_version = "2022",
            })
            local s = table.concat(args, " ")
            assert.is_truthy(s:find("-products P1 P2"))
            assert.is_truthy(s:find("-prerelease"))
            assert.is_truthy(s:find("-version %[17.0,18.0%)"))
            assert.is_truthy(s:find("-requires R1"))
        end)
    end)
end)
