local VsWhere = require("msvc.vswhere")

describe("msvc.vswhere translate_version", function()
    local cases = {
        -- Marketing year shorthand → range covering that year only.
        { input = "2015", expect = "[14.0,15.0)" },
        { input = "2017", expect = "[15.0,16.0)" },
        { input = "2019", expect = "[16.0,17.0)" },
        { input = "2022", expect = "[17.0,18.0)" },
        -- Bare-major shorthand → exact-major range (NOT vswhere's >=N
        -- default; this is a deliberate behaviour change).
        { input = "14", expect = "[14.0,15.0)" },
        { input = "15", expect = "[15.0,16.0)" },
        { input = "16", expect = "[16.0,17.0)" },
        { input = "17", expect = "[17.0,18.0)" },
        { input = "18", expect = "[18.0,19.0)" },
        -- "no filter" sentinels collapse to nil so build_args omits the
        -- `-version` flag entirely.
        { input = "latest", expect = nil },
        { input = "any", expect = nil },
        { input = "", expect = nil },
        { input = nil, expect = nil },
        -- Pass-through for explicit range / unknown major / two-component.
        { input = "17.8.34330.188", expect = "[17.8.34330.188,17.8.34330.188]" },
        { input = "15.9.37202.19", expect = "[15.9.37202.19,15.9.37202.19]" },
        { input = "17.14.37216.2", expect = "[17.14.37216.2,17.14.37216.2]" },
        { input = "15.9.37202", expect = "[15.9.37202,15.9.37202]" },
        -- Two-component inputs are NOT wrapped: real installations have
        -- 4 components, so `[15.9,15.9]` would match nothing. Pass
        -- through verbatim and let vswhere apply its `>=` semantics.
        { input = "15.9", expect = "15.9" },
        { input = "[17.0,18.0)", expect = "[17.0,18.0)" },
        { input = "[15.0,16.0)", expect = "[15.0,16.0)" },
        { input = "99", expect = "99" },
    }

    for _, c in ipairs(cases) do
        it(
            ("maps %s → %s"):format(tostring(c.input), tostring(c.expect)),
            function()
                assert.are.equal(c.expect, VsWhere.translate_version(c.input))
            end
        )
    end
end)

describe("msvc.vswhere build_args translates vs_version", function()
    local function index_of(args, val)
        for i, a in ipairs(args) do
            if a == val then
                return i
            end
        end
        return nil
    end

    it("translates marketing year to range", function()
        local args = VsWhere._build_args({ vs_version = "2017" })
        local i = index_of(args, "-version")
        assert.is_not_nil(i)
        assert.are.equal("[15.0,16.0)", args[i + 1])
    end)

    it("translates bare major to exact-major range", function()
        local args = VsWhere._build_args({ vs_version = "17" })
        local i = index_of(args, "-version")
        assert.is_not_nil(i)
        assert.are.equal("[17.0,18.0)", args[i + 1])
    end)

    it("wraps full semver as closed-closed exact-match range", function()
        local args = VsWhere._build_args({ vs_version = "17.8.34330.188" })
        local i = index_of(args, "-version")
        assert.is_not_nil(i)
        assert.are.equal("[17.8.34330.188,17.8.34330.188]", args[i + 1])
    end)

    it("passes two-component vs_version through verbatim", function()
        local args = VsWhere._build_args({ vs_version = "15.9" })
        local i = index_of(args, "-version")
        assert.is_not_nil(i)
        assert.are.equal("15.9", args[i + 1])
    end)

    it("passes range syntax through verbatim", function()
        local args = VsWhere._build_args({ vs_version = "[15.0,16.0)" })
        local i = index_of(args, "-version")
        assert.is_not_nil(i)
        assert.are.equal("[15.0,16.0)", args[i + 1])
    end)
end)
