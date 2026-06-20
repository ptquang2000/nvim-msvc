local commands = require("msvc.commands")
local Util = require("msvc.util")
local SUBCOMMANDS = commands._SUBCOMMANDS
local _complete = commands._complete

-- Minimal stub helpers -------------------------------------------------------

local function make_msvc(sln_path)
    return {
        solution = sln_path or nil,
        solutions = sln_path and { sln_path } or {},
        solution_projects = {},
        set_solution = function(self, path)
            self.solution = path
            return true
        end,
    }
end

local fixture_sln = Util.normalize_path(vim.fn.getcwd() .. "/tests/fixtures/sample.sln")

-- Subcommand existence -------------------------------------------------------

describe("SUBCOMMANDS", function()
    it("add exists with a non-empty desc", function()
        assert.is_not_nil(SUBCOMMANDS.add)
        assert.is_truthy(SUBCOMMANDS.add.desc and #SUBCOMMANDS.add.desc > 0)
    end)

    it("cancel exists", function()
        assert.is_not_nil(SUBCOMMANDS.cancel)
    end)

    it("log exists", function()
        assert.is_not_nil(SUBCOMMANDS.log)
    end)
end)

-- Completion -----------------------------------------------------------------

describe("_complete — subcommand listing", function()
    it("returns sorted list of 3 subcommands after 'Msvc '", function()
        local result = _complete(nil, "", "Msvc ", 5)
        assert.are.same({ "add", "cancel", "log" }, result)
    end)

    it("filters by arglead 'a'", function()
        local result = _complete(nil, "a", "Msvc a", 6)
        assert.are.same({ "add" }, result)
    end)

    it("trailing space after 'cancel' returns empty (no sub-args)", function()
        local result = _complete(nil, "", "Msvc cancel ", 12)
        assert.are.same({}, result)
    end)

    it("trailing space after 'add' returns non-empty file completions", function()
        local result = _complete(nil, "", "Msvc add ", 9)
        assert.is_truthy(#result > 0)
    end)
end)

-- :Msvc add run function -----------------------------------------------------

describe("SUBCOMMANDS.add.run", function()
    it("adds fixture sln and sets solution when given explicit path", function()
        local msvc = make_msvc()
        SUBCOMMANDS.add.run(msvc, { fixture_sln })
        assert.are.equal(fixture_sln, msvc.solution)
        assert.are.same({ fixture_sln }, msvc.solutions)
    end)

    it("does not duplicate when same sln added twice", function()
        local msvc = make_msvc()
        SUBCOMMANDS.add.run(msvc, { fixture_sln })
        SUBCOMMANDS.add.run(msvc, { fixture_sln })
        assert.are.equal(1, #msvc.solutions)
    end)

    it("appends to existing solutions and keeps sorted", function()
        local sln_a = Util.normalize_path(vim.fn.getcwd() .. "/tests/fixtures/sol-a/alpha.sln")
        local sln_b = Util.normalize_path(vim.fn.getcwd() .. "/tests/fixtures/sol-b/filter.sln")
        local msvc = make_msvc()
        -- add in reverse order; result must still be sorted
        SUBCOMMANDS.add.run(msvc, { sln_b })
        SUBCOMMANDS.add.run(msvc, { sln_a })
        assert.are.equal(2, #msvc.solutions)
        assert.is_truthy(msvc.solutions[1] < msvc.solutions[2])
    end)

    it("errors when path does not end in .sln", function()
        local msvc = make_msvc()
        local logged = {}
        local orig = vim.notify
        vim.notify = function(msg, _) logged[#logged + 1] = msg end
        SUBCOMMANDS.add.run(msvc, { "/some/file.txt" })
        vim.notify = orig
        assert.are.equal(0, #msvc.solutions)
    end)

    it("errors when file does not exist", function()
        local msvc = make_msvc()
        SUBCOMMANDS.add.run(msvc, { "/nonexistent/path.sln" })
        assert.are.equal(0, #msvc.solutions)
    end)

    it("uses current buffer name when no path given and buffer is .sln", function()
        local orig = vim.api.nvim_buf_get_name
        vim.api.nvim_buf_get_name = function(_) return fixture_sln end
        local msvc = make_msvc()
        SUBCOMMANDS.add.run(msvc, {})
        vim.api.nvim_buf_get_name = orig
        assert.are.equal(fixture_sln, msvc.solution)
    end)

    it("triggers discovery mode when no sln path is available", function()
        local orig_bufname = vim.api.nvim_buf_get_name
        vim.api.nvim_buf_get_name = function(_) return "" end
        local Discover = require("msvc.discover")
        local orig_find = Discover.find_sln_files
        local find_called = false
        Discover.find_sln_files = function(_)
            find_called = true
            return {}
        end
        local msvc = make_msvc()
        SUBCOMMANDS.add.run(msvc, {})
        vim.api.nvim_buf_get_name = orig_bufname
        Discover.find_sln_files = orig_find
        assert.is_true(find_called)
        assert.are.equal(0, #msvc.solutions)
    end)
end)
