local TestUtils = require("msvc.test.utils")

describe("msvc.config install_path removal", function()
    before_each(function()
        TestUtils.reset()
    end)

    it("KNOWN_PROFILE no longer lists install_path", function()
        local Config = require("msvc.config")
        assert.is_nil(Config.KNOWN_PROFILE.install_path)
    end)

    it(
        "validate emits a deprecation warning when install_path is set",
        function()
            local Config = require("msvc.config")
            local notify = TestUtils.capture_notify()
            Config.validate({
                settings = { default_profile = "base" },
                profiles = {
                    base = {
                        install_path = "C:\\fake",
                    },
                },
            })
            notify.restore()
            local joined = ""
            for _, c in ipairs(notify.calls) do
                joined = joined .. (c.msg or "") .. "\n"
            end
            assert.is_truthy(joined:find("install_path", 1, true))
            assert.is_truthy(joined:find("deprecated", 1, true))
        end
    )

    it("validate does not raise on install_path", function()
        local Config = require("msvc.config")
        local notify = TestUtils.capture_notify()
        local ok = pcall(Config.validate, {
            settings = { default_profile = "base" },
            profiles = { base = { install_path = "C:\\fake" } },
        })
        notify.restore()
        assert.is_true(ok)
    end)
end)
