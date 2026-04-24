local TestUtils = require("msvc.test.utils")

describe("msvc.extensions", function()
    before_each(function()
        TestUtils.reset()
    end)

    it("event_names is frozen", function()
        local Ext = require("msvc.extensions")
        assert.equals("BUILD_START", Ext.event_names.BUILD_START)
        assert.has_error(function()
            Ext.event_names.NEW_EVENT = "NEW_EVENT"
        end)
    end)

    it("add_listener + emit dispatches in registration order", function()
        local Ext = require("msvc.extensions")
        local bus = Ext.MsvcExtensions:new()
        local seen = {}
        bus:add_listener({
            BUILD_START = function(ctx)
                seen[#seen + 1] = "a:" .. ctx.tag
            end,
        })
        bus:add_listener({
            BUILD_START = function(ctx)
                seen[#seen + 1] = "b:" .. ctx.tag
            end,
            BUILD_DONE = function()
                seen[#seen + 1] = "b:done"
            end,
        })
        bus:emit("BUILD_START", { tag = "go" })
        bus:emit("BUILD_DONE")
        assert.same({ "a:go", "b:go", "b:done" }, seen)
    end)

    it("pcall isolates failing listeners", function()
        local Ext = require("msvc.extensions")
        local bus = Ext.MsvcExtensions:new()
        local cap = TestUtils.capture_notify()
        local hit = {}
        bus:add_listener({
            BUILD_START = function()
                error("boom")
            end,
        })
        bus:add_listener({
            BUILD_START = function()
                hit[#hit + 1] = "second"
            end,
        })
        bus:emit("BUILD_START")
        cap.restore()
        assert.same({ "second" }, hit)
        assert.is_true(#cap.calls >= 1)
        assert.is_true(cap.calls[1].msg:find("listener error", 1, true) ~= nil)
    end)

    it("clear_listeners empties the bus", function()
        local Ext = require("msvc.extensions")
        local bus = Ext.MsvcExtensions:new()
        bus:add_listener({ BUILD_START = function() end })
        assert.equals(1, #bus.listeners)
        bus:clear_listeners()
        assert.equals(0, #bus.listeners)
    end)
end)
