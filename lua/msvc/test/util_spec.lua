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

    it("split_budget splits a budget across /m and CL_MPCount axes", function()
        local cases = {
            { B = 2, nodes = 2, mpcount = 1 },
            { B = 6, nodes = 3, mpcount = 2 },
            { B = 14, nodes = 4, mpcount = 3 },
            { B = 30, nodes = 6, mpcount = 5 },
            { B = 1, nodes = 1, mpcount = 1 },
        }
        for _, c in ipairs(cases) do
            local s = Util.split_budget(c.B)
            assert.are.equal(c.nodes, s.nodes, "nodes for B=" .. c.B)
            assert.are.equal(c.mpcount, s.mpcount, "mpcount for B=" .. c.B)
            -- invariant: never oversubscribe the budget.
            assert.is_true(
                s.nodes * s.mpcount <= c.B,
                "nodes*mpcount <= B for B=" .. c.B
            )
        end
    end)

    it("split_budget clamps both axes to at least 1 at B=1", function()
        local s = Util.split_budget(1)
        assert.is_true(s.nodes >= 1)
        assert.is_true(s.mpcount >= 1)
    end)

    it("get_mtime returns 0 for nil path", function()
        assert.are.equal(0, Util.get_mtime(nil))
    end)

    it("get_mtime returns 0 for empty string", function()
        assert.are.equal(0, Util.get_mtime(""))
    end)

    it("get_mtime returns 0 for missing path", function()
        assert.are.equal(0, Util.get_mtime("/nonexistent/path/that/does/not/exist.sln"))
    end)

    it("get_mtime returns a positive integer for an existing file", function()
        local tmp = vim.fn.tempname() .. ".sln"
        local fh = io.open(tmp, "wb")
        fh:write("")
        fh:close()
        local mtime = Util.get_mtime(tmp)
        vim.fn.delete(tmp)
        assert.is_true(type(mtime) == "number", "get_mtime should return a number")
        assert.is_true(mtime > 0, "get_mtime should return a positive integer for existing file")
    end)
end)
