local TestUtils = require("msvc.test.utils")

-- Verify `:Msvc update` invalidates the cached install_path and re-resolves
-- via vswhere when a vs_* / vswhere_path field is overridden.
describe("msvc.commands update vs_* invalidates install_path", function()
    before_each(function()
        TestUtils.reset()
    end)

    -- Stub vswhere with a configurable installs list. Returns a table
    -- whose fields can be mutated between calls so individual `it`
    -- blocks can swap which install matches.
    local function stub_vswhere(installs_for)
        local VsWhere = require("msvc.vswhere")
        local async_calls = 0
        VsWhere.find_latest = function(opts)
            local installs = installs_for(opts) or {}
            -- Mirror the real pick_latest behaviour: first install wins
            -- when stable; tests pre-filter so we just take #1.
            return installs[1]
        end
        VsWhere.list_installations = function(opts)
            return installs_for(opts) or {}
        end
        VsWhere.list_installations_async = function(opts, cb)
            async_calls = async_calls + 1
            cb(installs_for(opts) or {}, nil)
        end
        return {
            async_call_count = function()
                return async_calls
            end,
        }
    end

    local function run_update(prop, value)
        local Commands = require("msvc.commands")
        local update = Commands.test.subcommands.update
        update.impl({ prop, value })
    end

    local function with_profile_selected()
        local msvc = require("msvc")
        msvc.config = require("msvc.config").merge_config({
            settings = { default_profile = "base" },
            profiles = { base = { vs_version = "latest" } },
        })
        msvc.state:set("profile", "base")
    end

    it(
        "clears install_path then re-resolves to the matching install",
        function()
            local msvc = require("msvc")
            local PATH_2017 = "C:\\VS\\2017"
            local PATH_2022 = "C:\\VS\\2022"

            local function installs_for(opts)
                -- The stub replaces VsWhere.find_latest, which receives the
                -- raw profile-view opts (translation happens inside vswhere
                -- internals we don't reach here). So branch on user-facing
                -- vs_version values, not the translated range.
                local v = opts and opts.vs_version
                if v == "2017" or v == "15" then
                    return {
                        {
                            installationPath = PATH_2017,
                            installationVersion = "15.9.0",
                            displayName = "Visual Studio Community 2017",
                            catalog = { productLineVersion = "2017" },
                        },
                    }
                elseif
                    v == "2022"
                    or v == "17"
                    or v == nil
                    or v == "latest"
                then
                    return {
                        {
                            installationPath = PATH_2022,
                            installationVersion = "17.9.0",
                            displayName = "Visual Studio Community 2022",
                            catalog = { productLineVersion = "2022" },
                        },
                    }
                end
                return {}
            end

            local stub = stub_vswhere(installs_for)
            with_profile_selected()
            -- Pre-condition: emulate prior warm caching the 2022 path.
            msvc.state:set("install_path", PATH_2022)

            run_update("vs_version", "2017")

            assert.are.equal(PATH_2017, msvc.state.install_path)
            assert.are.equal(
                "Visual Studio Community 2017",
                msvc.state.install_display_name
            )
            assert.are.equal("15.9.0", msvc.state.install_version)
            assert.are.equal("2017", msvc.state.install_product_line_version)
            -- Async warm should also have been triggered.
            assert.is_true(stub.async_call_count() >= 1)
        end
    )

    it(
        "warns and clears all install_* fields when no install matches",
        function()
            local msvc = require("msvc")
            stub_vswhere(function()
                return {}
            end)
            with_profile_selected()
            msvc.state:set("install_path", "C:\\VS\\2022")
            msvc.state:set(
                "install_display_name",
                "Visual Studio Community 2022"
            )
            msvc.state:set("install_version", "17.9.0")
            msvc.state:set("install_product_line_version", "2022")

            local notify = TestUtils.capture_notify()
            run_update("vs_version", "9999")
            notify.restore()

            assert.is_nil(msvc.state.install_path)
            assert.is_nil(msvc.state.install_display_name)
            assert.is_nil(msvc.state.install_version)
            assert.is_nil(msvc.state.install_product_line_version)

            local joined = ""
            for _, c in ipairs(notify.calls) do
                joined = joined .. (c.msg or "") .. "\n"
            end
            assert.is_truthy(
                joined:find("no Visual Studio installation matches", 1, true)
            )
            assert.is_truthy(joined:find("9999", 1, true))
            -- Override is still applied so the user can fix related fields
            -- without reverting first.
            assert.are.equal("9999", msvc.profile_overrides.base.vs_version)
        end
    )

    it("re-resolves when other vs_* fields are overridden too", function()
        local msvc = require("msvc")
        local seen_opts = nil
        stub_vswhere(function(opts)
            seen_opts = opts
            return {
                {
                    installationPath = "C:\\VS\\Pro",
                    installationVersion = "17.9.0",
                },
            }
        end)
        with_profile_selected()
        msvc.state:set("install_path", "C:\\VS\\Old")

        run_update("vs_prerelease", "true")

        assert.are.equal("C:\\VS\\Pro", msvc.state.install_path)
        assert.is_not_nil(seen_opts)
    end)

    it("does not touch install_path for non-vs_* overrides", function()
        local msvc = require("msvc")
        stub_vswhere(function()
            error("vswhere should not be invoked for unrelated overrides")
        end)
        with_profile_selected()
        msvc.state:set("install_path", "C:\\VS\\Stable")

        run_update("configuration", "Release")

        assert.are.equal("C:\\VS\\Stable", msvc.state.install_path)
    end)

    -- Integration: drive `:Msvc update vs_version <full-semver>` through
    -- the real find_latest → list_installations → build_args → run_vswhere
    -- chain. Stub at run_vswhere so build_args is exercised end-to-end and
    -- we can observe the translated `-version` argument that hits vswhere.
    describe("full-version exact-match selection", function()
        local PATH_2017 = "C:\\VS\\2017\\Pro"
        local PATH_2022 = "C:\\VS\\2022\\Pro"
        local INST_2017 = {
            installationPath = PATH_2017,
            installationVersion = "15.9.37202.19",
            displayName = "Visual Studio Professional 2017",
            catalog = { productLineVersion = "2017" },
            isPrerelease = false,
        }
        local INST_2022 = {
            installationPath = PATH_2022,
            installationVersion = "17.14.37216.2",
            displayName = "Visual Studio Professional 2022",
            catalog = { productLineVersion = "2022" },
            isPrerelease = false,
        }

        local function index_of(args, val)
            for i, a in ipairs(args) do
                if a == val then
                    return i
                end
            end
            return nil
        end

        -- Stub vswhere at the run_vswhere boundary. The sync path
        -- (find_latest → list_installations → run_vswhere) runs unchanged
        -- so build_args performs the real translation. Capture the args
        -- list each call so tests can inspect the translated `-version`.
        --
        -- We also stub list_installations_async (the unfiltered warm
        -- pre-fills the candidate cache) to return both installs without
        -- invoking vswhere.
        local function stub_run_vswhere(installs_db)
            local VsWhere = require("msvc.vswhere")
            local captured = { calls = {} }
            VsWhere.find_vswhere = function()
                return "C:\\fake\\vswhere.exe"
            end
            VsWhere.run_vswhere = function(args, _exe)
                captured.calls[#captured.calls + 1] = vim.deepcopy(args)
                local i = index_of(args, "-version")
                local v = i and args[i + 1] or nil
                local matches = {}
                for _, inst in ipairs(installs_db) do
                    if v == nil then
                        matches[#matches + 1] = inst
                    else
                        -- Only honour the exact-match `[X,X]` form here:
                        -- that's the form the fix emits for full semver.
                        local exact =
                            v:match("^%[(.-),(.-)%]$")
                        if exact then
                            local lo, hi =
                                v:match("^%[(.-),(.-)%]$")
                            if
                                lo == hi
                                and lo == inst.installationVersion
                            then
                                matches[#matches + 1] = inst
                            end
                        end
                    end
                end
                return matches, nil
            end
            VsWhere.list_installations_async = function(opts, cb)
                -- Mirror the real chain: list_installations_async → vswhere
                -- with build_args(opts). Reusing run_vswhere here means the
                -- filtered async warm respects the translated `-version`
                -- so a non-existent version yields an empty list (instead
                -- of always returning everything and clobbering state).
                local args = VsWhere._build_args(opts or {})
                local result = VsWhere.run_vswhere(args, "C:\\fake\\vswhere.exe")
                cb(result or {}, nil)
            end
            return captured
        end

        it(
            "translates full VS 2017 semver to [X,X] and pins to that install",
            function()
                local msvc = require("msvc")
                local cap = stub_run_vswhere({ INST_2017, INST_2022 })
                with_profile_selected()
                msvc.state:set("install_path", PATH_2022)

                run_update("vs_version", "15.9.37202.19")

                -- Confirm at least one vswhere call carried the bracketed form.
                local saw_bracket = false
                for _, args in ipairs(cap.calls) do
                    local i = index_of(args, "-version")
                    if
                        i
                        and args[i + 1]
                            == "[15.9.37202.19,15.9.37202.19]"
                    then
                        saw_bracket = true
                    end
                end
                assert.is_true(
                    saw_bracket,
                    "expected vswhere to be called with -version "
                        .. "[15.9.37202.19,15.9.37202.19]"
                )

                assert.are.equal(PATH_2017, msvc.state.install_path)
                assert.are.equal(
                    "15.9.37202.19",
                    msvc.state.install_version
                )
                assert.are.equal(
                    "Visual Studio Professional 2017",
                    msvc.state.install_display_name
                )
            end
        )

        it(
            "translates full VS 2022 semver to [X,X] and pins to that install",
            function()
                local msvc = require("msvc")
                local cap = stub_run_vswhere({ INST_2017, INST_2022 })
                with_profile_selected()
                msvc.state:set("install_path", PATH_2017)

                run_update("vs_version", "17.14.37216.2")

                local saw_bracket = false
                for _, args in ipairs(cap.calls) do
                    local i = index_of(args, "-version")
                    if
                        i
                        and args[i + 1]
                            == "[17.14.37216.2,17.14.37216.2]"
                    then
                        saw_bracket = true
                    end
                end
                assert.is_true(saw_bracket)

                assert.are.equal(PATH_2022, msvc.state.install_path)
                assert.are.equal(
                    "17.14.37216.2",
                    msvc.state.install_version
                )
                assert.are.equal(
                    "Visual Studio Professional 2022",
                    msvc.state.install_display_name
                )
            end
        )

        it(
            "non-existent full version clears state and warns",
            function()
                local msvc = require("msvc")
                stub_run_vswhere({ INST_2017, INST_2022 })
                with_profile_selected()
                msvc.state:set("install_path", PATH_2022)
                msvc.state:set(
                    "install_display_name",
                    "Visual Studio Professional 2022"
                )
                msvc.state:set("install_version", "17.14.37216.2")
                msvc.state:set("install_product_line_version", "2022")

                local notify = TestUtils.capture_notify()
                run_update("vs_version", "15.9.99999.99")
                notify.restore()

                assert.is_nil(msvc.state.install_path)
                assert.is_nil(msvc.state.install_display_name)
                assert.is_nil(msvc.state.install_version)
                assert.is_nil(msvc.state.install_product_line_version)

                local joined = ""
                for _, c in ipairs(notify.calls) do
                    joined = joined .. (c.msg or "") .. "\n"
                end
                assert.is_truthy(
                    joined:find(
                        "no Visual Studio installation matches",
                        1,
                        true
                    )
                )
                assert.is_truthy(
                    joined:find("15.9.99999.99", 1, true)
                )
            end
        )
    end)
end)
