local TestUtils = require("msvc.test.utils")

describe("msvc.quickfix", function()
    before_each(function()
        TestUtils.reset()
        vim.fn.setqflist({}, "r", { title = "MSBuild", items = {} })
    end)

    it("parse_lines parses MSBuild error/warning shapes", function()
        local Qf = require("msvc.quickfix")
        local lines = {
            [[C:\src\foo.cpp(42,7): error C2059: syntax error: ';']],
            [[C:\src\bar.cpp(13): warning C4100: 'arg' unreferenced]],
            [[some unrelated noise]],
        }
        local entries = Qf.parse_lines(lines)
        assert.equals(2, #entries)

        assert.equals(42, entries[1].lnum)
        assert.equals(7, entries[1].col)
        assert.equals("e", entries[1].type)
        assert.is_true(entries[1].text:find("C2059", 1, true) ~= nil)
        assert.is_true(entries[1].filename:find("foo.cpp", 1, true) ~= nil)

        assert.equals(13, entries[2].lnum)
        assert.equals("w", entries[2].type)
        assert.is_true(entries[2].text:find("C4100", 1, true) ~= nil)
    end)

    it("from_build_output publishes and returns count", function()
        local Qf = require("msvc.quickfix")
        local count = Qf.from_build_output({
            [[C:\src\foo.cpp(1,1): error C2143: missing token]],
            [[C:\src\foo.cpp(2,2): error C2144: another]],
        })
        assert.equals(2, count)
        local list = vim.fn.getqflist()
        assert.equals(2, #list)
    end)

    it("clear empties the quickfix list", function()
        local Qf = require("msvc.quickfix")
        Qf.from_build_output({
            [[C:\src\foo.cpp(1,1): error C2143: missing token]],
        })
        assert.is_true(#vim.fn.getqflist() >= 1)
        Qf.clear()
        assert.equals(0, #vim.fn.getqflist())
    end)

    it("parse_lines returns empty for empty input", function()
        local Qf = require("msvc.quickfix")
        assert.same({}, Qf.parse_lines({}))
        assert.same({}, Qf.parse_lines(nil))
    end)
end)
