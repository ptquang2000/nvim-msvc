-- Tests for msvc.config: schema, merging, validation.

local helpers = require("msvc.test.utils")

describe("msvc.config", function()
    local Config

    before_each(function()
        helpers.reset()
        Config = require("msvc.config")
    end)

    it("merges user settings over defaults", function()
        local cfg = Config.merge_config({
            settings = {
                default_profile = "dbg",
                build_on_save = true,
                compile_commands = { builddir = "out/cmake" },
            },
            default = { jobs = 4 },
            profiles = {
                dbg = { configuration = "Debug", platform = "x64" },
            },
        })
        assert.are.equal("dbg", cfg.settings.default_profile)
        assert.is_true(cfg.settings.build_on_save)
        assert.are.equal("out/cmake", cfg.settings.compile_commands.builddir)
        -- defaults preserved when not overridden
        assert.are.equal("bin", cfg.settings.compile_commands.outdir)
        assert.are.equal(4, cfg.default.jobs)
    end)

    it("get_profile shallow-merges default under named entry", function()
        local cfg = Config.merge_config({
            default = { msbuild_args = { "/v:m" }, jobs = 6, arch = "x64" },
            profiles = {
                rel = { configuration = "Release", platform = "x64" },
                arm = {
                    configuration = "Release",
                    platform = "ARM64",
                    arch = "arm64",
                },
            },
        })
        local rel = Config.get_profile(cfg, "rel")
        assert.are.equal("Release", rel.configuration)
        assert.are.equal("x64", rel.platform)
        assert.are.equal(6, rel.jobs)
        assert.are.equal("x64", rel.arch)
        assert.are.same({ "/v:m" }, rel.msbuild_args)

        local arm = Config.get_profile(cfg, "arm")
        assert.are.equal("arm64", arm.arch) -- entry overrides default
        assert.are.equal(6, arm.jobs) -- inherited
    end)

    it("returns nil for missing profile name", function()
        local cfg = Config.merge_config({ profiles = {} })
        assert.is_nil(Config.get_profile(cfg, "nope"))
        assert.is_nil(Config.get_profile(cfg, nil))
    end)

    it("validate accepts a well-formed config", function()
        local cfg = Config.merge_config({
            settings = { default_profile = "rel" },
            profiles = {
                rel = { configuration = "Release", platform = "Win32" },
            },
        })
        assert.has_no.errors(function()
            Config.validate(cfg)
        end)
    end)

    it("validate rejects unknown profile fields", function()
        local cfg = Config.merge_config({
            profiles = {
                rel = {
                    configuration = "Release",
                    platform = "x64",
                    garbage = 1,
                },
            },
        })
        assert.has_error(function()
            Config.validate(cfg)
        end)
    end)

    it("validate rejects unknown fields in `default`", function()
        local cfg = Config.merge_config({
            default = { unknown_field = true },
            profiles = { rel = { configuration = "Release", platform = "x64" } },
        })
        assert.has_error(function()
            Config.validate(cfg)
        end)
    end)

    it("validate requires configuration + platform on each profile", function()
        local cfg = Config.merge_config({
            profiles = { broken = { configuration = "Release" } },
        })
        assert.has_error(function()
            Config.validate(cfg)
        end)
    end)

    it("validate rejects unknown default_profile name", function()
        local cfg = Config.merge_config({
            settings = { default_profile = "ghost" },
            profiles = { rel = { configuration = "Release", platform = "x64" } },
        })
        assert.has_error(function()
            Config.validate(cfg)
        end)
    end)

    it("validate rejects invalid arch", function()
        local cfg = Config.merge_config({
            profiles = {
                rel = {
                    configuration = "Release",
                    platform = "x64",
                    arch = "bogus",
                },
            },
        })
        assert.has_error(function()
            Config.validate(cfg)
        end)
    end)

    it("list_profile_names returns sorted names", function()
        local cfg = Config.merge_config({
            profiles = {
                z = { configuration = "Debug", platform = "x64" },
                a = { configuration = "Debug", platform = "x64" },
                m = { configuration = "Debug", platform = "x64" },
            },
        })
        assert.are.same({ "a", "m", "z" }, Config.list_profile_names(cfg))
    end)
end)
