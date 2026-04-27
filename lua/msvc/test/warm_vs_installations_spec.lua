local TestUtils = require("msvc.test.utils")

-- Verify the two-warm split (BUG 1):
--   * The first list_installations_async call must NOT pass vs_version /
--     vs_products / vs_requires; it MUST pass vs_prerelease=true and
--     include_packages=true. This is the completion warm.
--   * The second call (only when state.install_path is empty) MUST
--     forward all vs_* filters from the merged profile view. This is
--     the active-resolve warm.
describe("msvc._warm_vs_installations two-warm split", function()
    before_each(function()
        TestUtils.reset()
    end)

    local function with_profile(vs_version)
        local msvc = require("msvc")
        msvc.config = require("msvc.config").merge_config({
            settings = { default_profile = "base" },
            profiles = {
                base = {
                    vs_version = vs_version or "2017",
                    vs_prerelease = false,
                    vs_products = {
                        "Microsoft.VisualStudio.Product.Professional",
                    },
                    vs_requires = {
                        "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
                    },
                    vswhere_path = "C:\\fake\\vswhere.exe",
                },
            },
        })
        msvc.state:set("profile", "base")
        return msvc
    end

    -- Stub list_installations_async to capture every opts table it receives,
    -- and feed back canned installs.
    local function stub_async(installs_for)
        local VsWhere = require("msvc.vswhere")
        local seen = {}
        VsWhere.list_installations_async = function(opts, cb)
            seen[#seen + 1] = vim.deepcopy(opts or {})
            cb(installs_for(opts) or {}, nil)
        end
        return seen
    end

    it(
        "first warm is unfiltered: no vs_version/vs_products/vs_requires; prerelease=true",
        function()
            local msvc = with_profile("2017")
            local seen = stub_async(function()
                return {}
            end)
            msvc:_warm_vs_installations()

            assert.is_true(#seen >= 1)
            local first = seen[1]
            assert.is_nil(first.vs_version)
            assert.is_nil(first.vs_products)
            assert.is_nil(first.vs_requires)
            assert.is_true(first.vs_prerelease)
            assert.is_true(first.include_packages)
            assert.equals("C:\\fake\\vswhere.exe", first.vswhere_path)
        end
    )

    it(
        "second warm forwards profile vs_* filters (when install_path empty)",
        function()
            local msvc = with_profile("2017")
            local seen = stub_async(function()
                return {}
            end)
            -- Pre-condition: install_path is unset (default).
            assert.is_nil(msvc.state.install_path)

            msvc:_warm_vs_installations()

            assert.equals(2, #seen)
            local second = seen[2]
            assert.equals("2017", second.vs_version)
            assert.same(
                { "Microsoft.VisualStudio.Product.Professional" },
                second.vs_products
            )
            assert.same(
                { "Microsoft.VisualStudio.Component.VC.Tools.x86.x64" },
                second.vs_requires
            )
        end
    )

    it("second warm is skipped when install_path is already cached", function()
        local msvc = with_profile("2017")
        local seen = stub_async(function()
            return {}
        end)
        msvc.state:set("install_path", "C:\\VS\\Pinned")

        msvc:_warm_vs_installations()

        assert.equals(1, #seen) -- only the unfiltered call
    end)

    it(
        "regression: completion candidates list every install regardless of vs_version filter",
        function()
            local msvc = with_profile("2017")
            -- Vswhere stub: full 3-install list when -version omitted; only
            -- the 2017 install when vs_version="2017" / "[15.0,16.0)".
            stub_async(function(opts)
                local v = opts and opts.vs_version
                if v == nil then
                    return {
                        { installationVersion = "15.9.0" },
                        { installationVersion = "16.11.50" },
                        { installationVersion = "17.9.34728.123" },
                    }
                end
                if v == "2017" or v == "[15.0,16.0)" or v == "15" then
                    return { { installationVersion = "15.9.0" } }
                end
                return {}
            end)

            msvc:_warm_vs_installations()

            local s = {}
            for _, e in ipairs(msvc.vs_completion_candidates.vs_version) do
                s[e] = true
            end
            -- All three majors must surface in completion regardless of
            -- the active vs_version filter.
            assert.is_true(s["[15.0,16.0)"])
            assert.is_true(s["[16.0,17.0)"])
            assert.is_true(s["[17.0,18.0)"])
            assert.is_true(s["15.9.0"])
            assert.is_true(s["16.11.50"])
            assert.is_true(s["17.9.34728.123"])
        end
    )

    it(
        "regression: candidate count does not shrink after :Msvc update vs_version <X>",
        function()
            local msvc = with_profile("latest")
            stub_async(function(opts)
                local v = opts and opts.vs_version
                if v == nil or v == "latest" then
                    return {
                        {
                            installationVersion = "15.9.0",
                            installationPath = "C:\\VS\\2017",
                        },
                        {
                            installationVersion = "17.9.34728.123",
                            installationPath = "C:\\VS\\2022",
                        },
                    }
                end
                if v == "2017" or v == "[15.0,16.0)" or v == "15" then
                    return {
                        {
                            installationVersion = "15.9.0",
                            installationPath = "C:\\VS\\2017",
                        },
                    }
                end
                return {}
            end)

            -- Initial warm.
            msvc:_warm_vs_installations()
            local before =
                vim.deepcopy(msvc.vs_completion_candidates.vs_version)

            -- Stub VsWhere.find_latest for the sync path triggered by `update`.
            local VsWhere = require("msvc.vswhere")
            VsWhere.find_latest = function(_)
                return {
                    installationPath = "C:\\VS\\2017",
                    installationVersion = "15.9.0",
                }
            end

            -- Simulate `:Msvc update vs_version 2017`.
            local Commands = require("msvc.commands")
            Commands.test.subcommands.update.impl({ "vs_version", "2017" })

            local after = msvc.vs_completion_candidates.vs_version
            assert.equals(#before, #after)
            assert.same(before, after)
        end
    )
end)
