local helpers = require("msvc.test.utils")

describe("msvc.commands", function()
    local Commands

    before_each(function()
        helpers.reset()
        Commands = require("msvc.commands")
    end)

    it("_SUBCOMMANDS has cancel and log entries", function()
        assert.is_not_nil(Commands._SUBCOMMANDS.cancel)
        assert.is_not_nil(Commands._SUBCOMMANDS.log)
        assert.is_truthy(Commands._SUBCOMMANDS.cancel.desc)
        assert.is_truthy(Commands._SUBCOMMANDS.log.desc)
    end)

    describe("_complete", function()
        it("returns all subcommands sorted when arglead is empty after 'Msvc '", function()
            local result = Commands._complete(nil, "", "Msvc ", nil)
            assert.are.equal(2, #result)
            assert.are.equal("cancel", result[1])
            assert.are.equal("log", result[2])
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
            -- "Msvc cancel " — second token done, trailing space → no more completions
            local result = Commands._complete(nil, "", "Msvc cancel ", nil)
            assert.are.equal(0, #result)
        end)

        it("returns empty list for a third token position", function()
            local result = Commands._complete(nil, "x", "Msvc cancel x", nil)
            assert.are.equal(0, #result)
        end)

        it("returns empty list when only the command name has been typed (no space)", function()
            -- "Msvc" — one token, no trailing space → not at arg1 position
            local result = Commands._complete(nil, "", "Msvc", nil)
            assert.are.equal(0, #result)
        end)
    end)
end)
