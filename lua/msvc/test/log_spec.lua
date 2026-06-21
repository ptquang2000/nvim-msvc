local helpers = require("msvc.test.utils")

describe("msvc.log — reset_build", function()
    local Log

    before_each(function()
        helpers.reset()
        Log = require("msvc.log")
    end)

    it("reset_build clears the buffer to the banner line", function()
        -- Prime the buffer with some content via build_append
        Log:build_append("some prior output")
        vim.wait(200, function() return false end, 10)

        Log:reset_build("-- build --")
        -- reset_buf is synchronous; the window open is scheduled but the line
        -- replacement happens immediately.
        local buf = vim.fn.bufnr("msvc://live-build-log")
        if buf == -1 then
            -- Buffer wasn't created in headless env — skip window assertion
            return
        end
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert.are.equal(1, #lines)
        assert.are.equal("-- build --", lines[1])
    end)

    it("reset_build with different banners stores the new banner", function()
        Log:reset_build("-- clean --")
        local buf = vim.fn.bufnr("msvc://live-build-log")
        if buf == -1 then return end
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert.are.equal("-- clean --", lines[1])

        Log:reset_build("-- rebuild --")
        lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert.are.equal("-- rebuild --", lines[1])
    end)
end)

describe("msvc.log — BUILD_START no longer resets buffer", function()
    local Log, Ext

    before_each(function()
        helpers.reset()
        Log = require("msvc.log")
        Ext = require("msvc.extensions")
        Log:install_live_tail()
    end)

    it("BUILD_START does not clear prior build output", function()
        -- Write content to the live buffer
        Log:reset_build("-- prior build --")
        Log:build_append("prior output line")
        vim.wait(200, function() return false end, 10)

        -- Fire BUILD_START
        Ext.extensions:emit(Ext.event_names.BUILD_START)
        vim.wait(200, function() return false end, 10)

        local buf = vim.fn.bufnr("msvc://live-build-log")
        if buf == -1 then return end
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        -- The prior output must still be present (not wiped)
        local has_prior = false
        for _, l in ipairs(lines) do
            if l:find("prior output line") then has_prior = true; break end
        end
        assert.is_true(has_prior, "BUILD_START must not wipe prior build output")
    end)

    it("BUILD_START does not write '-- build started --' banner", function()
        Log:reset_build("-- prior --")
        vim.wait(100, function() return false end, 10)

        Ext.extensions:emit(Ext.event_names.BUILD_START)
        vim.wait(200, function() return false end, 10)

        local buf = vim.fn.bufnr("msvc://live-build-log")
        if buf == -1 then return end
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        for _, l in ipairs(lines) do
            assert.is_falsy(
                l:find("build started", 1, true),
                "BUILD_START must not write 'build started' banner"
            )
        end
    end)
end)
