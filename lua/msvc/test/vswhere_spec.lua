local VsWhere = require("msvc.vswhere")

local function has(args, val)
    for _, a in ipairs(args) do
        if a == val then
            return true
        end
    end
    return false
end

local function index_of(args, val)
    for i, a in ipairs(args) do
        if a == val then
            return i
        end
    end
    return nil
end

local function count(args, val)
    local n = 0
    for _, a in ipairs(args) do
        if a == val then
            n = n + 1
        end
    end
    return n
end

describe("msvc.vswhere build_args", function()
    it("defaults to '-products *' and includes '-all'", function()
        local args = VsWhere._build_args(nil)
        assert.are.equal("-products", args[1])
        assert.are.equal("*", args[2])
        assert.is_true(has(args, "-all"))
    end)

    it("omits -prerelease by default", function()
        local args = VsWhere._build_args({})
        assert.is_false(has(args, "-prerelease"))
    end)

    it("includes -prerelease when vs_prerelease is true", function()
        local args = VsWhere._build_args({ vs_prerelease = true })
        assert.is_true(has(args, "-prerelease"))
    end)

    it("removes -prerelease when vs_prerelease is false", function()
        local args = VsWhere._build_args({ vs_prerelease = false })
        assert.is_false(has(args, "-prerelease"))
    end)

    it("emits no -requires when vs_requires is nil", function()
        local args = VsWhere._build_args({})
        assert.is_false(has(args, "-requires"))
    end)

    it("emits no -requires when vs_requires is empty", function()
        local args = VsWhere._build_args({ vs_requires = {} })
        assert.is_false(has(args, "-requires"))
    end)

    it("emits one -requires per element", function()
        local args = VsWhere._build_args({ vs_requires = { "A", "B" } })
        assert.are.equal(2, count(args, "-requires"))
        local i = index_of(args, "-requires")
        assert.are.equal("A", args[i + 1])
        local j = index_of({ unpack(args, i + 2) }, "-requires")
        assert.is_not_nil(j)
        assert.are.equal("B", args[i + 2 + j])
    end)

    it("emits -version when vs_version is a concrete value", function()
        local args = VsWhere._build_args({ vs_version = "[17.0,18.0)" })
        local i = index_of(args, "-version")
        assert.is_not_nil(i)
        assert.are.equal("[17.0,18.0)", args[i + 1])
    end)

    it("omits -version for 'latest' / 'any' / nil / ''", function()
        for _, v in ipairs({ "latest", "any", "" }) do
            local args = VsWhere._build_args({ vs_version = v })
            assert.is_false(has(args, "-version"))
        end
        local args = VsWhere._build_args({})
        assert.is_false(has(args, "-version"))
    end)

    it("overrides -products * when vs_products is a non-empty list", function()
        local args = VsWhere._build_args({
            vs_products = { "Microsoft.VisualStudio.Product.Professional" },
        })
        assert.are.equal("-products", args[1])
        assert.are.equal(
            "Microsoft.VisualStudio.Product.Professional",
            args[2]
        )
        -- '*' must not appear right after -products
        assert.is_false(args[3] == "*")
    end)

    it("falls back to '*' for empty vs_products", function()
        local args = VsWhere._build_args({ vs_products = {} })
        assert.are.equal("-products", args[1])
        assert.are.equal("*", args[2])
    end)
end)
