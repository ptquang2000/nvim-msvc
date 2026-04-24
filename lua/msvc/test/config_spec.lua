local TestUtils = require("msvc.test.utils")

describe("msvc.config", function()
    before_each(function()
        TestUtils.reset()
    end)

    it("get_default_config returns expected keys", function()
        local Config = require("msvc.config")
        local cfg = Config.get_default_config()
        assert.equals("table", type(cfg.settings))
        assert.equals("table", type(cfg.default))
        assert.equals(vim.log.levels.INFO, cfg.settings.notify_level)
        assert.equals(true, cfg.settings.open_quickfix)
        assert.equals("x64", cfg.default.arch)
        assert.equals(nil, cfg.default.configuration)
        assert.equals("table", type(cfg.default.msbuild_args))
    end)

    it("merge_config layers settings/default and exposes profiles", function()
        local Config = require("msvc.config")
        local cfg = Config.merge_config({
            settings = { qf_height = 25, echo_command = true },
            default = { configuration = "Release" },
            ["Release|x64"] = { platform = "x64" },
        })
        assert.equals(25, cfg.settings.qf_height)
        assert.equals(true, cfg.settings.echo_command)
        assert.equals("Release", cfg.default.configuration)
        local profile = Config.get_config(cfg, "Release|x64")
        assert.equals("Release", profile.configuration)
        assert.equals("x64", profile.platform)

        local fallback = Config.get_config(cfg, "missing")
        assert.equals("Release", fallback.configuration)
    end)

    it("validate errors on wrong types", function()
        local Config = require("msvc.config")
        assert.has_error(function()
            Config.validate({ settings = { qf_height = "tall" } })
        end)
        assert.has_error(function()
            Config.validate({ default = { jobs = "lots" } })
        end)
        assert.has_error(function()
            Config.validate({ settings = { qf_height = 0 } })
        end)
        assert.has_error(function()
            Config.validate({
                default = { msbuild_args = { 1, 2, 3 } },
            })
        end)
    end)

    it("validate accepts a freshly built default config", function()
        local Config = require("msvc.config")
        Config.validate(Config.get_default_config())
    end)
end)
