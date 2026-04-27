local helpers = require("msvc.test.utils")

describe("msvc.extensions", function()
    local Ext

    before_each(function()
        helpers.reset()
        Ext = require("msvc.extensions")
        Ext.extensions:clear_listeners()
    end)

    it("event_names is frozen", function()
        assert.has_error(function()
            Ext.event_names.NEW_EVENT = "x"
        end)
    end)

    it("listeners receive events with arguments", function()
        local seen = {}
        Ext.extensions:add_listener({
            [Ext.event_names.BUILD_OUTPUT] = function(line)
                seen[#seen + 1] = line
            end,
        })
        Ext.extensions:emit(Ext.event_names.BUILD_OUTPUT, "hello")
        Ext.extensions:emit(Ext.event_names.BUILD_OUTPUT, "world")
        assert.are.same({ "hello", "world" }, seen)
    end)

    it("a listener throwing does not break other listeners", function()
        local notify_calls = helpers.capture_notify()
        local good = 0
        Ext.extensions:add_listener({
            [Ext.event_names.BUILD_DONE] = function()
                error("bang")
            end,
        })
        Ext.extensions:add_listener({
            [Ext.event_names.BUILD_DONE] = function()
                good = good + 1
            end,
        })
        Ext.extensions:emit(Ext.event_names.BUILD_DONE)
        notify_calls.restore()
        assert.are.equal(1, good)
        assert.are.equal(1, #notify_calls.calls)
    end)
end)
