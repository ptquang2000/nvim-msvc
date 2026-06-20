-- Tests for msvc.config: flat settings schema, merge, validate.

local helpers = require("msvc.test.utils")

describe("msvc.config", function()
    local Config

    before_each(function()
        helpers.reset()
        Config = require("msvc.config")
    end)

    it("SETTINGS_FIELDS contains the five context-level fields", function()
        local fields = Config.SETTINGS_FIELDS
        local required = { "configuration", "platform", "arch", "vs_version", "jobs" }
        for _, f in ipairs(required) do
            local found = false
            for _, sf in ipairs(fields) do
                if sf == f then
                    found = true
                    break
                end
            end
            assert.is_true(found, "missing SETTINGS_FIELDS entry: " .. f)
        end
        assert.are.equal(#required, #fields)
    end)

    it("DEFAULT_SETTINGS has arch=x64 and vs_version=latest with nil config/platform", function()
        local d = Config.DEFAULT_SETTINGS
        assert.is_nil(d.configuration)
        assert.is_nil(d.platform)
        assert.are.equal("x64", d.arch)
        assert.are.equal("latest", d.vs_version)
        assert.are.equal(6, d.jobs)
    end)

    it("merge_config default_settings key overrides jobs default", function()
        local cfg = Config.merge_config({ default_settings = { jobs = 12 } })
        assert.are.equal(12, cfg.default_settings.jobs)
        assert.are.equal("x64", cfg.default_settings.arch)
    end)

    it("merge_config without default_settings uses DEFAULT_SETTINGS.jobs", function()
        local cfg = Config.merge_config({})
        assert.are.equal(6, cfg.default_settings.jobs)
    end)

    it("get_default_config has settings layer with compile_commands", function()
        local cfg = Config.get_default_config()
        assert.is_not_nil(cfg.settings)
        assert.is_not_nil(cfg.settings.compile_commands)
        assert.is_nil(cfg.profiles)
        assert.is_nil(cfg.default)
    end)

    it("merge_config copies user settings over defaults", function()
        local cfg = Config.merge_config({
            settings = {
                log_level = "debug",
                compile_commands = { builddir = "out/cmake" },
            },
        })
        assert.are.equal("debug", cfg.settings.log_level)
        assert.are.equal("out/cmake", cfg.settings.compile_commands.builddir)
        -- default sub-keys preserved
        assert.are.equal("bin", cfg.settings.compile_commands.outdir)
    end)

    it("merge_config ignores unknown top-level keys (profiles, default)", function()
        local cfg = Config.merge_config({
            profiles = { rel = { configuration = "Release", platform = "x64" } },
            default = { arch = "arm64" },
        })
        assert.is_nil(cfg.profiles)
        assert.is_nil(cfg.default)
    end)

    it("validate accepts well-formed config", function()
        local cfg = Config.merge_config({ settings = { log_level = "warn" } })
        assert.has_no.errors(function()
            Config.validate(cfg)
        end)
    end)

    it("validate accepts empty user config", function()
        local cfg = Config.merge_config({})
        assert.has_no.errors(function()
            Config.validate(cfg)
        end)
    end)

    it("validate rejects non-string log_level", function()
        local cfg = Config.merge_config({})
        cfg.settings.log_level = 42
        assert.has_error(function()
            Config.validate(cfg)
        end)
    end)

    it("validate rejects non-table vs_requires", function()
        local cfg = Config.merge_config({})
        cfg.settings.vs_requires = "bad"
        assert.has_error(function()
            Config.validate(cfg)
        end)
    end)

    it("merge_config is idempotent on nil user arg", function()
        local a = Config.merge_config(nil)
        local b = Config.merge_config({})
        assert.are.same(a, b)
    end)
end)
