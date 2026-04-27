local TestUtils = require("msvc.test.utils")

describe("msvc.util", function()
    before_each(function()
        TestUtils.reset()
    end)

    it("normalize_path collapses backslashes and strips trailing", function()
        local Util = require("msvc.util")
        assert.equals("C:\\foo\\bar", Util.normalize_path("C:/foo/bar"))
        assert.equals("C:\\foo\\bar", Util.normalize_path("C:\\\\foo\\\\bar\\"))
        assert.equals("C:\\", Util.normalize_path("C:\\"))
        assert.equals(
            "\\\\server\\share\\dir",
            Util.normalize_path("\\\\server\\\\share\\\\dir\\")
        )
        assert.is_nil(Util.normalize_path(nil))
    end)

    it("join_path concatenates and normalizes", function()
        local Util = require("msvc.util")
        assert.equals("C:\\a\\b\\c", Util.join_path("C:\\a", "b", "c"))
        assert.equals("C:\\a\\b", Util.join_path("C:\\a\\", "\\b"))
        assert.equals("C:\\a", Util.join_path("C:\\a", "", nil))
    end)

    it("shell_escape quotes embedded quotes per CommandLineToArgvW", function()
        local Util = require("msvc.util")
        assert.equals("plain", Util.shell_escape("plain"))
        assert.equals("\"a b\"", Util.shell_escape("a b"))
        assert.equals([[""]], Util.shell_escape(""))
        assert.equals([[""]], Util.shell_escape(nil))
        assert.equals([["a\"b"]], Util.shell_escape([[a"b]]))
        assert.equals([["a b\\"]], Util.shell_escape("a b\\"))
    end)

    it("tbl_deep_merge: overrides win, arrays replaced wholesale", function()
        local Util = require("msvc.util")
        local merged = Util.tbl_deep_merge(
            { a = 1, nested = { x = 1, y = 2 } },
            { a = 9, nested = { y = 20, z = 30 } }
        )
        assert.equals(9, merged.a)
        assert.equals(1, merged.nested.x)
        assert.equals(20, merged.nested.y)
        assert.equals(30, merged.nested.z)

        local arr = Util.tbl_deep_merge(
            { items = { "a", "b", "c" } },
            { items = { "x", "y" } }
        )
        assert.same({ "x", "y" }, arr.items)
    end)

    it("basename / dirname / extension", function()
        local Util = require("msvc.util")
        assert.equals("file.cpp", Util.basename("C:\\foo\\file.cpp"))
        assert.equals("file.cpp", Util.basename("C:/foo/file.cpp"))
        assert.equals("C:\\foo", Util.dirname("C:\\foo\\file.cpp"))
        assert.equals("", Util.dirname("file.cpp"))
        assert.equals("cpp", Util.extension("Main.CPP"))
        assert.equals("", Util.extension("Makefile"))
    end)

    it(
        "is_absolute detects Windows drive, UNC, POSIX, and rejects relative",
        function()
            local Util = require("msvc.util")
            -- Windows drive-letter (back- or forward-slash, with or without sep)
            assert.is_true(Util.is_absolute("C:\\foo"))
            assert.is_true(Util.is_absolute("c:/foo"))
            assert.is_true(Util.is_absolute("D:\\"))
            assert.is_true(Util.is_absolute("D:"))
            -- UNC
            assert.is_true(Util.is_absolute("\\\\server\\share\\dir"))
            assert.is_true(Util.is_absolute("//server/share/dir"))
            -- POSIX-style
            assert.is_true(Util.is_absolute("/etc/passwd"))
            -- Relative / empty
            assert.is_false(Util.is_absolute("build"))
            assert.is_false(Util.is_absolute("..\\build"))
            assert.is_false(Util.is_absolute("./out"))
            assert.is_false(Util.is_absolute(""))
            assert.is_false(Util.is_absolute(nil))
        end
    )

    it(
        "resolve_path joins relative against anchor; absolute pass-through",
        function()
            local Util = require("msvc.util")
            -- Absolute pass-through (normalized).
            assert.equals(
                "C:\\already\\abs",
                Util.resolve_path("C:/already/abs", "C:\\anchor")
            )
            -- Relative joined under anchor.
            assert.equals(
                "C:\\anchor\\build",
                Util.resolve_path("build", "C:\\anchor")
            )
            -- Trailing slash on anchor is normalized away.
            assert.equals(
                "C:\\anchor\\out",
                Util.resolve_path("out", "C:\\anchor\\")
            )
            -- ".." segments survive (we don't canonicalize) but join cleanly.
            assert.equals(
                "C:\\anchor\\..\\sib",
                Util.resolve_path("..\\sib", "C:\\anchor")
            )
            -- No anchor → just normalize.
            assert.equals("build", Util.resolve_path("build", nil))
            assert.equals("build", Util.resolve_path("build", ""))
            -- Empty / nil input → nil.
            assert.is_nil(Util.resolve_path("", "C:\\anchor"))
            assert.is_nil(Util.resolve_path(nil, "C:\\anchor"))
        end
    )
end)
