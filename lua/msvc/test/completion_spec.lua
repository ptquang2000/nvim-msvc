local TestUtils = require("msvc.test.utils")

describe("msvc.commands update completion", function()
    before_each(function()
        TestUtils.reset()
    end)

    -- Drive the update.complete callback the same way nvim does.
    local function complete(arglead, cmdline)
        local Commands = require("msvc.commands")
        local sub = Commands.test.subcommands.update
        return sub.complete(arglead, cmdline, #cmdline)
    end

    it("vs_version returns dynamic candidates when warmed", function()
        local msvc = require("msvc")
        msvc.vs_completion_candidates = {
            vs_version = { "17", "17.9.0", "2022", "latest" },
            vs_prerelease = { "false", "true" },
            vs_products = {},
            vs_requires = {},
        }
        local out = complete("17", ":Msvc update vs_version 17")
        table.sort(out)
        assert.same({ "17", "17.9.0" }, out)
    end)

    it("vs_products falls back to static list when cache is empty", function()
        local msvc = require("msvc")
        msvc.vs_completion_candidates = {
            vs_version = {},
            vs_prerelease = { "false", "true" },
            vs_products = {},
            vs_requires = {},
        }
        local out = complete("Microsoft", ":Msvc update vs_products Microsoft")
        assert.is_true(#out >= 1)
        for _, v in ipairs(out) do
            assert.is_truthy(v:find("Microsoft%.VisualStudio%.Product"))
        end
    end)

    it("vs_requires returns warmed candidates filtered by prefix", function()
        local msvc = require("msvc")
        msvc.vs_completion_candidates = {
            vs_version = {},
            vs_prerelease = { "false", "true" },
            vs_products = {},
            vs_requires = {
                "Microsoft.VisualStudio.Component.VC.ATL",
                "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
                "Microsoft.VisualStudio.Workload.NativeDesktop",
            },
        }
        local out = complete(
            "Microsoft.VisualStudio.Component",
            ":Msvc update vs_requires Microsoft.VisualStudio.Component"
        )
        assert.equals(2, #out)
    end)

    it("configuration uses project_targets when populated", function()
        local msvc = require("msvc")
        msvc.project_targets = {
            configurations = { "Debug", "Release", "ReleaseCTR" },
            platforms = { "ARM64", "Win32", "x64" },
        }
        local out = complete("R", ":Msvc update configuration R")
        table.sort(out)
        assert.same({ "Release", "ReleaseCTR" }, out)
    end)

    it(
        "configuration falls back to {Debug,Release} when cache is empty",
        function()
            local msvc = require("msvc")
            msvc.project_targets = { configurations = {}, platforms = {} }
            local out = complete("", ":Msvc update configuration ")
            table.sort(out)
            assert.same({ "Debug", "Release" }, out)
        end
    )

    it("platform falls back to {Win32,x64} when cache is empty", function()
        local msvc = require("msvc")
        msvc.project_targets = { configurations = {}, platforms = {} }
        local out = complete("", ":Msvc update platform ")
        table.sort(out)
        assert.same({ "Win32", "x64" }, out)
    end)

    it("install_path is rejected with a deprecation warning", function()
        local Commands = require("msvc.commands")
        local notify = TestUtils.capture_notify()
        Commands.test.subcommands.update.impl(
            { "install_path", "C:\\fake" },
            {}
        )
        notify.restore()
        local joined = ""
        for _, c in ipairs(notify.calls) do
            joined = joined .. (c.msg or "") .. "\n"
        end
        assert.is_truthy(joined:find("install_path", 1, true))
        assert.is_truthy(joined:find("deprecated", 1, true))
    end)
end)
