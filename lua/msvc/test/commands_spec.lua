local helpers = require("msvc.test.utils")

describe("msvc.commands", function()
    local Commands

    before_each(function()
        helpers.reset()
        Commands = require("msvc.commands")
    end)

    it("_SUBCOMMANDS has add, cancel, and log entries", function()
        assert.is_not_nil(Commands._SUBCOMMANDS.add)
        assert.is_not_nil(Commands._SUBCOMMANDS.cancel)
        assert.is_not_nil(Commands._SUBCOMMANDS.log)
        assert.is_truthy(Commands._SUBCOMMANDS.add.desc)
        assert.is_truthy(Commands._SUBCOMMANDS.cancel.desc)
        assert.is_truthy(Commands._SUBCOMMANDS.log.desc)
    end)

    describe("_complete", function()
        it("returns all subcommands sorted when arglead is empty after 'Msvc '", function()
            local result = Commands._complete(nil, "", "Msvc ", nil)
            assert.are.equal(3, #result)
            assert.are.equal("add", result[1])
            assert.are.equal("cancel", result[2])
            assert.are.equal("log", result[3])
        end)

        it("filters to add when arglead is 'a'", function()
            local result = Commands._complete(nil, "a", "Msvc a", nil)
            assert.are.equal(1, #result)
            assert.are.equal("add", result[1])
        end)

        it("filters to cancel when arglead is 'ca'", function()
            local result = Commands._complete(nil, "ca", "Msvc ca", nil)
            assert.are.equal(1, #result)
            assert.are.equal("cancel", result[1])
        end)

        it("filters to log when arglead is 'l'", function()
            local result = Commands._complete(nil, "l", "Msvc l", nil)
            assert.are.equal(1, #result)
            assert.are.equal("log", result[1])
        end)

        it("returns empty list when arglead matches no subcommand", function()
            local result = Commands._complete(nil, "xyz", "Msvc xyz", nil)
            assert.are.equal(0, #result)
        end)

        it("returns empty list when trailing space follows subcommand", function()
            local result = Commands._complete(nil, "", "Msvc cancel ", nil)
            assert.are.equal(0, #result)
        end)

        it("returns empty list for a third token position", function()
            local result = Commands._complete(nil, "x", "Msvc cancel x", nil)
            assert.are.equal(0, #result)
        end)

        it("returns empty list when only the command name has been typed (no space)", function()
            local result = Commands._complete(nil, "", "Msvc", nil)
            assert.are.equal(0, #result)
        end)
    end)

    -- ─── :Msvc add dispatch — discovery branch ─────────────────────────────

    describe("SUBCOMMANDS.add discovery mode", function()
        local function fake_msvc_for_add()
            return {
                solutions = {},
                solution = nil,
                solution_projects = {},
                set_solution = function(self, path)
                    self.solution = path
                    return true
                end,
            }
        end

        it("triggers find_sln_files when no path given and buffer is not .sln", function()
            local orig_bufname = vim.api.nvim_buf_get_name
            vim.api.nvim_buf_get_name = function(_) return "/src/main.cpp" end
            local Discover = require("msvc.discover")
            local UI = require("msvc.ui")
            local orig_find = Discover.find_sln_files
            local orig_open = UI.open
            local find_called = false
            Discover.find_sln_files = function(_)
                find_called = true
                return {}
            end
            UI.open = function() end  -- prevent real buffer creation
            local msvc = fake_msvc_for_add()
            Commands._SUBCOMMANDS.add.run(msvc, {})
            vim.api.nvim_buf_get_name = orig_bufname
            Discover.find_sln_files = orig_find
            UI.open = orig_open
            assert.is_true(find_called)
        end)

        it("triggers find_sln_files when buffer name is empty", function()
            local orig_bufname = vim.api.nvim_buf_get_name
            vim.api.nvim_buf_get_name = function(_) return "" end
            local Discover = require("msvc.discover")
            local UI = require("msvc.ui")
            local orig_find = Discover.find_sln_files
            local orig_open = UI.open
            local find_called = false
            Discover.find_sln_files = function(_)
                find_called = true
                return {}
            end
            UI.open = function() end  -- prevent real buffer creation
            local msvc = fake_msvc_for_add()
            Commands._SUBCOMMANDS.add.run(msvc, {})
            vim.api.nvim_buf_get_name = orig_bufname
            Discover.find_sln_files = orig_find
            UI.open = orig_open
            assert.is_true(find_called)
        end)

        it("does NOT trigger discovery when explicit .sln arg is given", function()
            local Discover = require("msvc.discover")
            local orig_find = Discover.find_sln_files
            local find_called = false
            Discover.find_sln_files = function(_)
                find_called = true
                return {}
            end
            local msvc = fake_msvc_for_add()
            -- Pass a non-existent .sln — will fail file check but won't call find_sln_files
            Commands._SUBCOMMANDS.add.run(msvc, { "/nonexistent/path.sln" })
            Discover.find_sln_files = orig_find
            assert.is_false(find_called)
        end)

        it("errors when explicit arg is not a .sln file", function()
            local msvc = fake_msvc_for_add()
            local logged = {}
            local orig_notify = vim.notify
            vim.notify = function(msg, _) logged[#logged + 1] = msg end
            Commands._SUBCOMMANDS.add.run(msvc, { "/some/file.txt" })
            vim.notify = orig_notify
            assert.are.equal(0, #msvc.solutions)
        end)
    end)
end)
