local TestUtils = require("msvc.test.utils")

describe("msvc.compile_commands", function()
    before_each(function()
        TestUtils.reset()
    end)

    it("is_enabled defaults to true and respects explicit disable", function()
        local CC = require("msvc.compile_commands")
        assert.is_true(CC.is_enabled(nil))
        assert.is_true(CC.is_enabled({}))
        assert.is_true(CC.is_enabled({ enabled = true }))
        assert.is_false(CC.is_enabled({ enabled = false }))
    end)

    it("build_argv composes solution / project / -c -a -o flags", function()
        local CC = require("msvc.compile_commands")
        local argv = CC._internal.build_argv({
            extractor = "C:/tools/msbuild-extractor-sample.exe",
            solution = "C:/repo/app.sln",
            projects = { "C:/repo/extra1.vcxproj", "C:/repo/extra2.vcxproj" },
            configuration = "Debug",
            platform = "x64",
            outpath = "C:/out/compile_commands.json",
        })
        assert.same({
            "C:/tools/msbuild-extractor-sample.exe",
            "--solution",
            "C:/repo/app.sln",
            "--project",
            "C:/repo/extra1.vcxproj",
            "--project",
            "C:/repo/extra2.vcxproj",
            "-c",
            "Debug",
            "-a",
            "x64",
            "-o",
            "C:/out/compile_commands.json",
            "--merge",
            "--deduplicate",
        }, argv)
    end)

    it("build_argv honors merge=false and extra_args", function()
        local CC = require("msvc.compile_commands")
        local argv = CC._internal.build_argv({
            extractor = "msbuild-extractor-sample",
            solution = "app.sln",
            projects = {},
            configuration = "Release",
            platform = "x64",
            outpath = "out.json",
            merge = false,
            deduplicate = false,
            extra_args = { "--validate" },
        })
        assert.same({
            "msbuild-extractor-sample",
            "--solution",
            "app.sln",
            "-c",
            "Release",
            "-a",
            "x64",
            "-o",
            "out.json",
            "--validate",
        }, argv)
    end)

    it(
        "build_argv emits --vs-path when supplied and omits dev-env / msbuild-path",
        function()
            local CC = require("msvc.compile_commands")
            local argv = CC._internal.build_argv({
                extractor = "msbuild-extractor-sample",
                solution = "app.sln",
                projects = {},
                configuration = "Debug",
                platform = "x64",
                outpath = "out.json",
                vs_path = "C:/Program Files (x86)/Microsoft Visual Studio/2017/Professional",
            })
            assert.same({
                "msbuild-extractor-sample",
                "--solution",
                "app.sln",
                "-c",
                "Debug",
                "-a",
                "x64",
                "--vs-path",
                "C:/Program Files (x86)/Microsoft Visual Studio/2017/Professional",
                "-o",
                "out.json",
                "--merge",
                "--deduplicate",
            }, argv)
        end
    )

    it(
        "build_argv omits --vs-path when not supplied and never emits --use-dev-env / --msbuild-path",
        function()
            local CC = require("msvc.compile_commands")
            local argv = CC._internal.build_argv({
                extractor = "msbuild-extractor-sample",
                solution = "app.sln",
                projects = {},
                configuration = "Debug",
                platform = "x64",
                outpath = "out.json",
            })
            for _, a in ipairs(argv) do
                assert.is_not.equal("--use-dev-env", a)
                assert.is_not.equal("--msbuild-path", a)
                assert.is_not.equal("--vs-path", a)
            end
        end
    )

    it(
        "generate forwards active project and extra_projects to argv (deduplicated)",
        function()
            local CC = require("msvc.compile_commands")
            -- Ensure find_extractor returns a value so generate doesn't bail out.
            local orig_find = CC.find_extractor
            CC.find_extractor = function()
                return "C:/tools/msbuild-extractor-sample.exe"
            end
            local orig_system = vim.system
            local captured_argv
            vim.system = function(argv, _, _)
                captured_argv = argv
                return {
                    wait = function()
                        return { code = 0 }
                    end,
                }
            end
            local ok, err = pcall(function()
                CC.generate({
                    solution = "C:/repo/app.sln",
                    project = "C:/repo/src/active.vcxproj",
                    extra_projects = {
                        "C:/repo/src/active.vcxproj", -- duplicate of active
                        "C:/repo/src/other.vcxproj",
                        "not-a-vcxproj.txt", -- filtered out
                    },
                    configuration = "Debug",
                    platform = "x64",
                    cc = { enabled = true, outdir = "out" },
                })
            end)
            CC.find_extractor = orig_find
            vim.system = orig_system
            assert.is_true(ok, tostring(err))
            assert.is_table(captured_argv)
            local projs = {}
            for i, a in ipairs(captured_argv) do
                if a == "--project" then
                    projs[#projs + 1] = captured_argv[i + 1]
                end
            end
            -- active project present exactly once, plus the unique extra
            local saw_active, saw_other, dupes = 0, 0, 0
            for _, p in ipairs(projs) do
                if p:lower():find("active%.vcxproj$") then
                    saw_active = saw_active + 1
                elseif p:lower():find("other%.vcxproj$") then
                    saw_other = saw_other + 1
                end
            end
            assert.equals(1, saw_active)
            assert.equals(1, saw_other)
            for _, p in ipairs(projs) do
                assert.is_truthy(p:lower():match("%.vcxproj$"))
            end
            for _ = 1, dupes do
            end
        end
    )

    it("config rejects unknown keys and bad types", function()
        local Config = require("msvc.config")
        Config.validate({
            settings = {
                compile_commands = {
                    enabled = true,
                    outdir = "out",
                    builddir = "build",
                },
            },
        })
        assert.has_error(function()
            Config.validate({
                settings = {
                    compile_commands = { extra_args = { 1, 2 } },
                },
            })
        end)
        assert.has_error(function()
            Config.validate({
                settings = { compile_commands = { outdir = 7 } },
            })
        end)
    end)

    it("merge_config merges compile_commands per-key across calls", function()
        local Config = require("msvc.config")
        local cfg = Config.merge_config({
            settings = {
                compile_commands = { outdir = "first" },
            },
        })
        cfg = Config.merge_config({
            settings = {
                compile_commands = { builddir = "build" },
            },
        }, cfg)
        local cc = cfg.settings.compile_commands
        assert.equals("first", cc.outdir)
        assert.equals("build", cc.builddir)
    end)

    describe("anchor + path resolution", function()
        local Util = require("msvc.util")

        local function setup_dirs(root, subs)
            for _, s in ipairs(subs) do
                vim.fn.mkdir(Util.join_path(root, s), "p")
            end
        end

        local tmp_root
        local prev_cwd

        before_each(function()
            tmp_root = Util.normalize_path(vim.fn.tempname())
            vim.fn.mkdir(tmp_root, "p")
            prev_cwd = vim.fn.getcwd()
        end)

        after_each(function()
            vim.cmd("cd " .. vim.fn.fnameescape(prev_cwd))
            vim.fn.delete(tmp_root, "rf")
        end)

        it(
            "resolve_anchor prefers solution dir, then project dir, then cwd",
            function()
                local CC = require("msvc.compile_commands")
                local sol_dir = Util.join_path(tmp_root, "sol")
                local proj_dir = Util.join_path(tmp_root, "proj")
                setup_dirs(tmp_root, { "sol", "proj" })
                assert.equals(
                    Util.normalize_path(sol_dir),
                    CC._internal.resolve_anchor(
                        Util.join_path(sol_dir, "app.sln"),
                        Util.join_path(proj_dir, "p.vcxproj")
                    )
                )
                assert.equals(
                    Util.normalize_path(proj_dir),
                    CC._internal.resolve_anchor(
                        nil,
                        Util.join_path(proj_dir, "p.vcxproj")
                    )
                )
                vim.cmd("cd " .. vim.fn.fnameescape(tmp_root))
                assert.equals(
                    Util.normalize_path(tmp_root),
                    CC._internal.resolve_anchor(nil, nil)
                )
            end
        )

        it("relative outdir resolves against solution dir", function()
            local CC = require("msvc.compile_commands")
            local sol_dir = Util.join_path(tmp_root, "sol")
            setup_dirs(tmp_root, { "sol/build" })
            local out = CC._internal.resolve_outpath(
                "build",
                Util.join_path(sol_dir, "app.sln"),
                nil
            )
            assert.equals(
                Util.join_path(sol_dir, "build", "compile_commands.json"),
                out
            )
        end)

        it(
            "relative outdir falls back to project dir when no solution",
            function()
                local CC = require("msvc.compile_commands")
                local proj_dir = Util.join_path(tmp_root, "proj")
                setup_dirs(tmp_root, { "proj/out" })
                local out = CC._internal.resolve_outpath(
                    "out",
                    nil,
                    Util.join_path(proj_dir, "p.vcxproj")
                )
                assert.equals(
                    Util.join_path(proj_dir, "out", "compile_commands.json"),
                    out
                )
            end
        )

        it(
            "relative outdir falls back to cwd when no solution / project",
            function()
                local CC = require("msvc.compile_commands")
                setup_dirs(tmp_root, { "cwdout" })
                vim.cmd("cd " .. vim.fn.fnameescape(tmp_root))
                local out = CC._internal.resolve_outpath("cwdout", nil, nil)
                assert.equals(
                    Util.join_path(tmp_root, "cwdout", "compile_commands.json"),
                    out
                )
            end
        )

        it("absolute outdir passes through unchanged", function()
            local CC = require("msvc.compile_commands")
            local abs = Util.join_path(tmp_root, "absout")
            setup_dirs(tmp_root, { "absout" })
            -- A different (unrelated) solution dir must NOT be used as anchor.
            local other = Util.join_path(tmp_root, "other")
            setup_dirs(tmp_root, { "other" })
            local out = CC._internal.resolve_outpath(
                abs,
                Util.join_path(other, "app.sln"),
                nil
            )
            assert.equals(Util.join_path(abs, "compile_commands.json"), out)
        end)

        it("relative builddir resolves against solution dir", function()
            local CC = require("msvc.compile_commands")
            local sol_dir = Util.join_path(tmp_root, "sol")
            setup_dirs(tmp_root, { "sol/bd" })
            -- Returns empty list (no *.vcxproj inside) but must not warn
            -- because the directory exists. The crucial assertion is that
            -- the resolver did not fall back to cwd (where "bd" doesn't
            -- exist) — that path would emit a warn.
            local notify = TestUtils.capture_notify()
            local list = CC._internal.collect_builddir_vcxprojs(
                "bd",
                Util.join_path(sol_dir, "app.sln"),
                nil
            )
            notify.restore()
            assert.same({}, list)
            for _, c in ipairs(notify.calls) do
                assert.is_nil(
                    (c.msg or ""):find("builddir does not exist", 1, true)
                )
            end
        end)

        it("relative builddir falls back to project dir", function()
            local CC = require("msvc.compile_commands")
            local proj_dir = Util.join_path(tmp_root, "proj")
            setup_dirs(tmp_root, { "proj/bd" })
            local notify = TestUtils.capture_notify()
            CC._internal.collect_builddir_vcxprojs(
                "bd",
                nil,
                Util.join_path(proj_dir, "p.vcxproj")
            )
            notify.restore()
            for _, c in ipairs(notify.calls) do
                assert.is_nil(
                    (c.msg or ""):find("builddir does not exist", 1, true)
                )
            end
        end)

        it("relative builddir falls back to cwd", function()
            local CC = require("msvc.compile_commands")
            setup_dirs(tmp_root, { "bd" })
            vim.cmd("cd " .. vim.fn.fnameescape(tmp_root))
            local notify = TestUtils.capture_notify()
            CC._internal.collect_builddir_vcxprojs("bd", nil, nil)
            notify.restore()
            for _, c in ipairs(notify.calls) do
                assert.is_nil(
                    (c.msg or ""):find("builddir does not exist", 1, true)
                )
            end
        end)

        it("absolute builddir passes through unchanged", function()
            local CC = require("msvc.compile_commands")
            local abs = Util.join_path(tmp_root, "absbd")
            setup_dirs(tmp_root, { "absbd" })
            local other = Util.join_path(tmp_root, "elsewhere")
            setup_dirs(tmp_root, { "elsewhere" })
            local notify = TestUtils.capture_notify()
            CC._internal.collect_builddir_vcxprojs(
                abs,
                Util.join_path(other, "app.sln"),
                nil
            )
            notify.restore()
            for _, c in ipairs(notify.calls) do
                assert.is_nil(
                    (c.msg or ""):find("builddir does not exist", 1, true)
                )
            end
        end)

        it("does not mutate the stored cc.builddir / cc.outdir", function()
            local CC = require("msvc.compile_commands")
            local sol_dir = Util.join_path(tmp_root, "sol")
            setup_dirs(tmp_root, { "sol/build", "sol/out" })
            local cc = { builddir = "build", outdir = "out" }
            CC._internal.resolve_outpath(
                cc.outdir,
                Util.join_path(sol_dir, "app.sln"),
                nil
            )
            CC._internal.collect_builddir_vcxprojs(
                cc.builddir,
                Util.join_path(sol_dir, "app.sln"),
                nil
            )
            assert.equals("build", cc.builddir)
            assert.equals("out", cc.outdir)
        end)
    end)
end)
