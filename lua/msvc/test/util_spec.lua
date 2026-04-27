local helpers = require("msvc.test.utils")

describe("msvc.util", function()
    local Util

    before_each(function()
        helpers.reset()
        Util = require("msvc.util")
    end)

    it("normalize_path collapses separators", function()
        if Util.is_windows() then
            assert.are.equal(
                "C:\\foo\\bar",
                Util.normalize_path("C:/foo//bar/")
            )
            assert.are.equal("C:\\", Util.normalize_path("C:\\"))
        else
            assert.are.equal("/foo/bar", Util.normalize_path("/foo//bar/"))
        end
    end)

    it("is_absolute detects drive-letter and UNC paths", function()
        if Util.is_windows() then
            assert.is_true(Util.is_absolute("C:\\foo"))
            assert.is_true(Util.is_absolute("c:/foo"))
            assert.is_true(Util.is_absolute("\\\\server\\share"))
            assert.is_false(Util.is_absolute("foo\\bar"))
        else
            assert.is_true(Util.is_absolute("/etc"))
            assert.is_false(Util.is_absolute("etc"))
        end
    end)

    it("join_path joins components", function()
        if Util.is_windows() then
            assert.are.equal("C:\\foo\\bar", Util.join_path("C:\\foo", "bar"))
            assert.are.equal(
                "C:\\foo\\bar\\baz",
                Util.join_path("C:\\foo", "bar\\", "baz")
            )
        else
            assert.are.equal("/foo/bar", Util.join_path("/foo", "bar"))
        end
    end)

    it("resolve_path returns absolute paths verbatim", function()
        if Util.is_windows() then
            assert.are.equal(
                "C:\\foo",
                Util.resolve_path("C:\\foo", "D:\\anchor")
            )
            assert.are.equal(
                "D:\\anchor\\bar",
                Util.resolve_path("bar", "D:\\anchor")
            )
        end
    end)

    it("basename / dirname split paths", function()
        assert.are.equal("baz.txt", Util.basename("/foo/bar/baz.txt"))
        assert.are.equal("/foo/bar", Util.dirname("/foo/bar/baz.txt"))
        assert.are.equal("", Util.dirname("foo"))
    end)

    it("dedupe preserves order, drops empties + duplicates", function()
        assert.are.same(
            { "a", "b", "c" },
            Util.dedupe({ "a", "b", "a", "", "c", "b" })
        )
    end)
end)
