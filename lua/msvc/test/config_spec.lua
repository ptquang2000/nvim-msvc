local TestUtils = require("msvc.test.utils")

describe("msvc.config", function()
    before_each(function()
        TestUtils.reset()
    end)

    it("get_default_config returns expected keys", function()
        local Config = require("msvc.config")
        local cfg = Config.get_default_config()
        assert.equals("table", type(cfg.settings))
        assert.equals("table", type(cfg.profiles))
        assert.equals(0, vim.tbl_count(cfg.profiles))
        assert.equals(nil, cfg.settings.default_profile)
        assert.equals(vim.log.levels.INFO, cfg.settings.notify_level)
        assert.equals(true, cfg.settings.open_quickfix)
        -- Engine fallbacks now live internally and surface via get_profile.
        local p = Config.get_profile(cfg, nil)
        assert.equals("x64", p.arch)
        assert.equals("table", type(p.msbuild_args))
        assert.equals(nil, p.configuration)
    end)

    it(
        "merge_config layers settings/profiles and exposes get_profile",
        function()
            local Config = require("msvc.config")
            local cfg = Config.merge_config({
                settings = {
                    qf_height = 25,
                    echo_command = true,
                    default_profile = "base",
                },
                profiles = {
                    base = { configuration = "Release" },
                    ["Release|x64"] = { platform = "x64" },
                },
            })
            assert.equals(25, cfg.settings.qf_height)
            assert.equals(true, cfg.settings.echo_command)
            assert.equals("Release", cfg.profiles.base.configuration)
            local profile = Config.get_profile(cfg, "Release|x64")
            assert.equals("Release", profile.configuration)
            assert.equals("x64", profile.platform)

            -- Missing target profile still inherits from the root.
            local fallback = Config.get_profile(cfg, "missing")
            assert.equals("Release", fallback.configuration)
        end
    )

    it("get_profile flattens engine + root + named profile fields", function()
        local Config = require("msvc.config")
        local cfg = Config.merge_config({
            settings = { default_profile = "base" },
            profiles = {
                base = {
                    arch = "x64",
                    vcvars_ver = "14.16",
                },
                grsc = {
                    configuration = "Release",
                    platform = "Win32",
                    winsdk = "10.0.17763.0",
                },
                custom = {
                    arch = "arm64",
                },
            },
        })
        local r = Config.get_profile(cfg, "grsc")
        assert.equals("x64", r.arch)
        assert.equals("14.16", r.vcvars_ver)
        assert.equals("10.0.17763.0", r.winsdk)
        assert.equals("Release", r.configuration)
        local r2 = Config.get_profile(cfg, "custom")
        assert.equals("arm64", r2.arch)
        assert.equals("14.16", r2.vcvars_ver)
        -- Engine fallback still applies when nothing overrides it.
        assert.equals("x64", r.host_arch)
    end)

    it("merge_config warns on misplaced top-level keys", function()
        local Config = require("msvc.config")
        local notify = TestUtils.capture_notify()
        local cfg = Config.merge_config({
            -- Belongs in `settings.compile_commands`.
            compile_commands = { outdir = "bin" },
            -- Belongs on a profile entry.
            arch = "x64",
            -- Truly unknown.
            wibble = true,
        })
        notify.restore()
        -- Misplaced keys are dropped, not silently merged.
        assert.is_nil(cfg.compile_commands)
        assert.is_nil(cfg.arch)
        assert.is_nil(cfg.wibble)
        local joined = ""
        for _, c in ipairs(notify.calls) do
            joined = joined .. (c.msg or "") .. "\n"
        end
        assert.is_truthy(joined:find("compile_commands", 1, true))
        assert.is_truthy(joined:find("settings.compile_commands", 1, true))
        assert.is_truthy(joined:find("arch", 1, true))
        assert.is_truthy(joined:find("profile entry", 1, true))
        assert.is_truthy(joined:find("wibble", 1, true))
    end)

    it("list_profile_names includes the configured default_profile", function()
        local Config = require("msvc.config")
        local cfg = Config.merge_config({
            settings = { default_profile = "base" },
            profiles = {
                base = {},
                grsc = {},
                driver = {},
            },
        })
        local names = Config.list_profile_names(cfg)
        assert.same({ "base", "driver", "grsc" }, names)
    end)

    it(
        "list_profile_names ignores a default_profile that has no matching profile entry",
        function()
            local Config = require("msvc.config")
            local cfg = Config.merge_config({
                settings = { default_profile = "ghost" },
                profiles = { grsc = {}, driver = {} },
            })
            local names = Config.list_profile_names(cfg)
            assert.same({ "driver", "grsc" }, names)
        end
    )

    it(
        "list_profile_names without default_profile lists every profile",
        function()
            local Config = require("msvc.config")
            local cfg = Config.merge_config({
                profiles = { grsc = {}, driver = {} },
            })
            local names = Config.list_profile_names(cfg)
            assert.same({ "driver", "grsc" }, names)
        end
    )

    it("merge_config merges profile fields per-key across calls", function()
        local Config = require("msvc.config")
        local cfg = Config.merge_config({
            profiles = {
                grsc = {
                    configuration = "Release",
                    vcvars_ver = "14.16",
                },
            },
        })
        cfg = Config.merge_config({
            profiles = {
                grsc = {
                    winsdk = "10.0.17763.0",
                },
            },
        }, cfg)
        local r = Config.get_profile(cfg, "grsc")
        assert.equals("Release", r.configuration)
        assert.equals("14.16", r.vcvars_ver)
        assert.equals("10.0.17763.0", r.winsdk)
    end)

    it("validate errors on wrong types", function()
        local Config = require("msvc.config")
        assert.has_error(function()
            Config.validate({ settings = { qf_height = "tall" } })
        end)
        assert.has_error(function()
            Config.validate({ profiles = { base = { jobs = "lots" } } })
        end)
        assert.has_error(function()
            Config.validate({ settings = { qf_height = 0 } })
        end)
        assert.has_error(function()
            Config.validate({
                profiles = { base = { msbuild_args = { 1, 2, 3 } } },
            })
        end)
        assert.has_error(function()
            Config.validate({
                profiles = {
                    grsc = { arch = 42 },
                },
            })
        end)
    end)

    it("validate rejects the removed use_dev_env setting", function()
        local Config = require("msvc.config")
        local ok, err = pcall(Config.validate, {
            settings = { use_dev_env = true },
        })
        assert.is_false(ok)
        assert.matches("use_dev_env", tostring(err))
    end)

    it("validate accepts a freshly built default config", function()
        local Config = require("msvc.config")
        Config.validate(Config.get_default_config())
    end)

    it("default_profile is a recognized setting", function()
        local Config = require("msvc.config")
        local cfg = Config.merge_config({
            settings = { default_profile = "grsc" },
            profiles = { grsc = {}, driver = {} },
        })
        assert.equals("grsc", cfg.settings.default_profile)
        Config.validate(cfg)
    end)

    it("validate rejects non-string default_profile", function()
        local Config = require("msvc.config")
        assert.has_error(function()
            Config.validate({ settings = { default_profile = 42 } })
        end)
    end)

    it(
        "validate rejects default_profile that does not match any profile",
        function()
            local Config = require("msvc.config")
            local ok, err = pcall(Config.validate, {
                settings = { default_profile = "missing" },
                profiles = { grsc = {} },
            })
            assert.is_false(ok)
            assert.matches("default_profile", tostring(err))
        end
    )

    it("format_entry_lines emits sorted key=value lines", function()
        local Config = require("msvc.config")
        local lines = Config.format_entry_lines("profile=grsc", {
            platform = "Win32",
            configuration = "Release",
            vcvars_ver = "14.16",
        })
        assert.equals("profile=grsc", lines[1])
        assert.equals("  configuration = \"Release\"", lines[2])
        assert.equals("  platform = \"Win32\"", lines[3])
        assert.equals("  vcvars_ver = \"14.16\"", lines[4])
        assert.equals(4, #lines)
    end)
end)
