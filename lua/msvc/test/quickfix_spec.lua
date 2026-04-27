local helpers = require("msvc.test.utils")

describe("msvc.quickfix", function()
    local QF

    before_each(function()
        helpers.reset()
        QF = require("msvc.quickfix")
    end)

    it("parses MSVC error / warning lines", function()
        local entries = QF.parse_lines({
            [[C:\src\foo.cpp(12,3): error C2065: 'x': undeclared identifier]],
            [[C:\src\bar.cpp(7,1): warning C4101: 'y': unreferenced local variable]],
            "this line should be ignored",
        })
        assert.are.equal(2, #entries)
        assert.are.equal(12, entries[1].lnum)
        assert.are.equal(3, entries[1].col)
        assert.are.equal("e", entries[1].type)
        assert.are.equal("w", entries[2].type)
    end)

    it("publishes to qf list", function()
        QF.publish({
            {
                filename = "C:\\foo.cpp",
                lnum = 1,
                col = 1,
                type = "E",
                text = "boom",
            },
        }, { title = "test" })
        local list = vim.fn.getqflist({ items = 0, title = 0 })
        assert.are.equal("test", list.title)
        assert.are.equal(1, #list.items)
    end)
end)
