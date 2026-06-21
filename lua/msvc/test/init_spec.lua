-- Tests for msvc.init: context save/load with flat settings payload.

local helpers = require("msvc.test.utils")

describe("msvc.init — context store", function()
    local Msvc, Config, Util
    local tmpdir

    before_each(function()
        helpers.reset_init_only()
        Msvc = require("msvc")
        Config = require("msvc.config")
        Util = require("msvc.util")
        tmpdir = vim.fn.tempname()
        vim.fn.mkdir(tmpdir, "p")
    end)

    after_each(function()
        if tmpdir and vim.fn.isdirectory(tmpdir) == 1 then
            vim.fn.delete(tmpdir, "rf")
        end
    end)

    local function write(path, body)
        vim.fn.mkdir(Util.dirname(path), "p")
        local fh = io.open(path, "wb")
        fh:write(body or "")
        fh:close()
    end

    it("settings initialises from DEFAULT_SETTINGS", function()
        assert.is_nil(Msvc.settings.configuration)
        assert.is_nil(Msvc.settings.platform)
        assert.are.equal("x64", Msvc.settings.arch)
        assert.are.equal("latest", Msvc.settings.vs_version)
        assert.are.equal(6, Msvc.settings.jobs)
    end)

    it("_save_context stores a flat settings snapshot", function()
        local sln = Util.join_path(tmpdir, "A.sln")
        write(sln)
        Msvc.solution = sln
        Msvc.project = nil
        Msvc.settings.configuration = "Debug"
        Msvc.settings.platform = "x64"
        Msvc.settings.jobs = 4
        Msvc:_save_context()
        local key = sln .. "\0"
        local stored = Msvc._context_store[key]
        assert.are.equal("Debug", stored.configuration)
        assert.are.equal("x64", stored.platform)
        assert.are.equal("x64", stored.arch)
        assert.are.equal(4, stored.jobs)
    end)

    it("_save_context is independent for different context keys", function()
        local sln = Util.join_path(tmpdir, "A.sln")
        local proj = Util.join_path(tmpdir, "P.vcxproj")
        write(sln)
        write(proj)
        -- Save context for (sln, nil)
        Msvc.solution = sln
        Msvc.project = nil
        Msvc.settings.configuration = "Debug"
        Msvc:_save_context()
        -- Save context for (sln, proj)
        Msvc.solution = sln
        Msvc.project = proj
        Msvc.settings.configuration = "Release"
        Msvc:_save_context()
        local key_sln = sln .. "\0"
        local key_proj = sln .. "\0" .. proj
        assert.are.equal("Debug", Msvc._context_store[key_sln].configuration)
        assert.are.equal("Release", Msvc._context_store[key_proj].configuration)
    end)

    it("_load_context restores stored flat settings", function()
        local sln = Util.join_path(tmpdir, "B.sln")
        write(sln)
        local key = sln .. "\0"
        Msvc._context_store[key] = {
            configuration = "Release",
            platform = "Win32",
            arch = "x64",
            vs_version = "2022",
            jobs = 8,
        }
        Msvc:_load_context(sln, nil)
        assert.are.equal("Release", Msvc.settings.configuration)
        assert.are.equal("Win32", Msvc.settings.platform)
        assert.are.equal("2022", Msvc.settings.vs_version)
        assert.are.equal(8, Msvc.settings.jobs)
    end)

    it("_load_context falls back to DEFAULT_SETTINGS for unknown context", function()
        Msvc.settings.configuration = "Release"
        Msvc.settings.platform = "ARM64"
        Msvc:_load_context("nonexistent.sln", nil)
        assert.is_nil(Msvc.settings.configuration)
        assert.is_nil(Msvc.settings.platform)
        assert.are.equal("x64", Msvc.settings.arch)
        assert.are.equal("latest", Msvc.settings.vs_version)
    end)

    it("_load_context deep-copies stored table (no aliasing)", function()
        local sln = Util.join_path(tmpdir, "C.sln")
        write(sln)
        local key = sln .. "\0"
        Msvc._context_store[key] = { configuration = "Debug", platform = "x64", arch = "x64", vs_version = "latest", jobs = nil }
        Msvc:_load_context(sln, nil)
        Msvc.settings.configuration = "Release"
        assert.are.equal("Debug", Msvc._context_store[key].configuration)
    end)

    it("no profile_name, set_profile, active_profile, or overrides on singleton", function()
        assert.is_nil(Msvc.profile_name)
        assert.is_nil(Msvc.overrides)
        assert.is_nil(Msvc.set_profile)
        assert.is_nil(Msvc.active_profile)
        assert.is_nil(Msvc.set_override)
    end)

    it("_discard_solution_context removes matching keys and leaves others", function()
        local sln_a = Util.join_path(tmpdir, "A.sln")
        local sln_b = Util.join_path(tmpdir, "B.sln")
        local proj = Util.join_path(tmpdir, "P.vcxproj")
        -- Populate _context_store with keys for both solutions
        Msvc._context_store[sln_a .. "\0"] = { configuration = "Debug" }
        Msvc._context_store[sln_a .. "\0" .. proj] = { configuration = "Release" }
        Msvc._context_store[sln_b .. "\0"] = { configuration = "MinSizeRel" }
        Msvc:_discard_solution_context(sln_a)
        assert.is_nil(Msvc._context_store[sln_a .. "\0"])
        assert.is_nil(Msvc._context_store[sln_a .. "\0" .. proj])
        assert.are.equal("MinSizeRel", Msvc._context_store[sln_b .. "\0"].configuration)
    end)

    it("_discard_solution_context is case-insensitive on solution path", function()
        local sln = Util.join_path(tmpdir, "MyApp.sln")
        Msvc._context_store[sln .. "\0"] = { configuration = "Debug" }
        Msvc:_discard_solution_context(sln:upper())
        assert.is_nil(Msvc._context_store[sln .. "\0"])
    end)

    it("_discard_solution_context is a no-op for nil path", function()
        local sln = Util.join_path(tmpdir, "A.sln")
        Msvc._context_store[sln .. "\0"] = { configuration = "Debug" }
        assert.has_no.errors(function()
            Msvc:_discard_solution_context(nil)
        end)
        assert.are.equal("Debug", Msvc._context_store[sln .. "\0"].configuration)
    end)
end)

describe("msvc.init — set_solution / set_project", function()
    local Msvc, Util
    local tmpdir

    before_each(function()
        helpers.reset_init_only()
        Msvc = require("msvc")
        Util = require("msvc.util")
        tmpdir = vim.fn.tempname()
        vim.fn.mkdir(tmpdir, "p")
    end)

    after_each(function()
        if tmpdir and vim.fn.isdirectory(tmpdir) == 1 then
            vim.fn.delete(tmpdir, "rf")
        end
    end)

    -- ─── set_solution ─────────────────────────────────────────────────────────

    it("set_solution(nil) clears solution and returns true", function()
        Msvc.solution = "/fake/s.sln"
        Msvc.project = "/fake/p.vcxproj"
        local ok = Msvc:set_solution(nil)
        assert.is_true(ok)
        assert.is_nil(Msvc.solution)
        assert.is_nil(Msvc.project)
    end)

    it("set_solution('') clears solution and returns true", function()
        Msvc.solution = "/fake/s.sln"
        local ok = Msvc:set_solution("")
        assert.is_true(ok)
        assert.is_nil(Msvc.solution)
    end)

    it("set_solution matches by full path in candidates", function()
        local sln = "/fake/alpha.sln"
        Msvc.solutions = { sln }
        local ok = Msvc:set_solution(sln)
        assert.is_true(ok)
        assert.are.equal(sln, Msvc.solution)
    end)

    it("set_solution case-insensitive match in candidates", function()
        local sln = "/Fake/Alpha.sln"
        Msvc.solutions = { sln }
        local ok = Msvc:set_solution("/fake/alpha.sln")
        assert.is_true(ok)
        assert.are.equal(sln, Msvc.solution)
    end)

    it("set_solution matches candidate by basename", function()
        local sln = "/fake/myproject.sln"
        Msvc.solutions = { sln }
        local ok = Msvc:set_solution("myproject.sln")
        assert.is_true(ok)
        assert.are.equal(sln, Msvc.solution)
    end)

    it("set_solution returns false for path not in candidates and not on disk", function()
        Msvc.solutions = {}
        local ok = Msvc:set_solution("/nonexistent/path.sln")
        assert.is_false(ok)
        assert.is_nil(Msvc.solution)
    end)

    it("set_solution saves context before switching", function()
        local sln_a = "/fake/a.sln"
        local sln_b = "/fake/b.sln"
        Msvc.solutions = { sln_a, sln_b }
        Msvc.solution = sln_a
        Msvc.project = nil
        Msvc.settings.configuration = "Debug"
        Msvc.settings.platform = "x64"
        Msvc:set_solution(sln_b)
        local key = sln_a .. "\0"
        assert.are.equal("Debug", Msvc._context_store[key].configuration)
    end)

    it("set_solution clears project when switching solutions", function()
        local sln = "/fake/s.sln"
        Msvc.solutions = { sln }
        Msvc.project = "/fake/P.vcxproj"
        Msvc:set_solution(sln)
        assert.is_nil(Msvc.project)
    end)

    it("set_solution with real .sln file succeeds via direct path", function()
        local sln = Util.join_path(tmpdir, "real.sln")
        local fh = io.open(sln, "wb")
        fh:write("")
        fh:close()
        Msvc.solutions = {}
        local ok = Msvc:set_solution(sln)
        assert.is_true(ok)
        assert.are.equal(Util.normalize_path(sln), Msvc.solution)
    end)

    it("set_solution auto-populates configuration and platform when context has no stored settings", function()
        local sln = Util.join_path(tmpdir, "fresh.sln")
        local fh = io.open(sln, "wb"); fh:write(""); fh:close()
        local sln_norm = Util.normalize_path(sln)
        Msvc.solutions = { sln_norm }
        Msvc:set_solution(sln_norm)
        assert.is_not_nil(Msvc.settings.configuration)
        assert.is_not_nil(Msvc.settings.platform)
    end)

    it("set_solution preserves stored configuration and platform when context exists", function()
        local sln = Util.join_path(tmpdir, "stored.sln")
        local fh = io.open(sln, "wb"); fh:write(""); fh:close()
        local sln_norm = Util.normalize_path(sln)
        Msvc._context_store[sln_norm .. "\0"] = {
            configuration = "MyConfig", platform = "MyPlatform",
            arch = "x64", vs_version = "latest", jobs = 6,
        }
        Msvc.solutions = { sln_norm }
        Msvc:set_solution(sln_norm)
        assert.are.equal("MyConfig", Msvc.settings.configuration)
        assert.are.equal("MyPlatform", Msvc.settings.platform)
    end)

    -- ─── set_project ──────────────────────────────────────────────────────────

    it("set_project(nil) clears project and returns true", function()
        Msvc.project = "/fake/P.vcxproj"
        local ok = Msvc:set_project(nil)
        assert.is_true(ok)
        assert.is_nil(Msvc.project)
    end)

    it("set_project('') clears project and returns true", function()
        Msvc.project = "/fake/P.vcxproj"
        local ok = Msvc:set_project("")
        assert.is_true(ok)
        assert.is_nil(Msvc.project)
    end)

    it("set_project matches by name in solution_projects (no filesystem check)", function()
        local proj_path = "/fake/Alpha.vcxproj"
        Msvc.solution_projects = { { name = "Alpha", path = proj_path } }
        local ok = Msvc:set_project("Alpha")
        assert.is_true(ok)
        assert.are.equal(proj_path, Msvc.project)
    end)

    it("set_project returns false for path not in solution_projects and not on disk", function()
        Msvc.solution_projects = {}
        local ok = Msvc:set_project("/nonexistent/proj.vcxproj")
        assert.is_false(ok)
    end)

    it("set_project saves context before switching", function()
        local sln = "/fake/s.sln"
        Msvc.solution = sln
        Msvc.project = nil
        Msvc.settings.configuration = "Debug"
        Msvc.settings.platform = "Win32"
        local proj_path = "/fake/Alpha.vcxproj"
        Msvc.solution_projects = { { name = "Alpha", path = proj_path } }
        Msvc:set_project("Alpha")
        local key = sln .. "\0"
        assert.are.equal("Debug", Msvc._context_store[key].configuration)
    end)

    it("set_project with real file path succeeds", function()
        local proj = Util.join_path(tmpdir, "P.vcxproj")
        local fh = io.open(proj, "wb")
        fh:write("<Project/>")
        fh:close()
        Msvc.solution_projects = {}
        local ok = Msvc:set_project(proj)
        assert.is_true(ok)
        assert.are.equal(Util.normalize_path(proj), Msvc.project)
    end)
end)

describe("msvc.init — _compute_sln_mtime and compile_commands dirty check", function()
    local Msvc, Util, CompileCommands
    local tmpdir

    before_each(function()
        helpers.reset_init_only()
        Msvc = require("msvc")
        Util = require("msvc.util")
        CompileCommands = require("msvc.compile_commands")
        tmpdir = vim.fn.tempname()
        vim.fn.mkdir(tmpdir, "p")
        Msvc._cc_fingerprints = {}
        Msvc.config = { settings = { compile_commands = { enabled = true } } }
    end)

    after_each(function()
        if tmpdir and vim.fn.isdirectory(tmpdir) == 1 then
            vim.fn.delete(tmpdir, "rf")
        end
    end)

    local function write(path, body)
        vim.fn.mkdir(Util.dirname(path), "p")
        local fh = io.open(path, "wb")
        fh:write(body or "")
        fh:close()
    end

    -- ─── _compute_sln_mtime ───────────────────────────────────────────────────

    it("_compute_sln_mtime returns max of sln and vcxproj mtimes", function()
        local orig_get_mtime = Util.get_mtime
        local mtime_map = {
            ["/fake/A.sln"] = 100,
            ["/fake/P1.vcxproj"] = 200,
            ["/fake/P2.vcxproj"] = 150,
        }
        Util.get_mtime = function(p) return mtime_map[p] or 0 end

        Msvc.solution_projects = {
            { name = "P1", path = "/fake/P1.vcxproj" },
            { name = "P2", path = "/fake/P2.vcxproj" },
        }
        local result = Msvc:_compute_sln_mtime("/fake/A.sln")
        Util.get_mtime = orig_get_mtime

        assert.are.equal(200, result)
    end)

    it("_compute_sln_mtime returns sln mtime when no vcxprojs are higher", function()
        local orig_get_mtime = Util.get_mtime
        local mtime_map = {
            ["/fake/A.sln"] = 500,
            ["/fake/P.vcxproj"] = 300,
        }
        Util.get_mtime = function(p) return mtime_map[p] or 0 end

        Msvc.solution_projects = { { name = "P", path = "/fake/P.vcxproj" } }
        local result = Msvc:_compute_sln_mtime("/fake/A.sln")
        Util.get_mtime = orig_get_mtime

        assert.are.equal(500, result)
    end)

    it("_compute_sln_mtime returns 0 when nothing is stat-able", function()
        local orig_get_mtime = Util.get_mtime
        Util.get_mtime = function(_) return 0 end
        Msvc.solution_projects = {}
        local result = Msvc:_compute_sln_mtime("/nonexistent/A.sln")
        Util.get_mtime = orig_get_mtime
        assert.are.equal(0, result)
    end)

    -- ─── dirty-check skip ─────────────────────────────────────────────────────

    it("_run_compile_commands skips generation when fingerprint matches mtime", function()
        local orig_get_mtime = Util.get_mtime
        Util.get_mtime = function(_) return 1000 end
        local orig_generate = CompileCommands.generate
        local generate_called = false
        CompileCommands.generate = function(_) generate_called = true return true end

        local sln = "/fake/A.sln"
        Msvc.solution = sln
        Msvc.project = nil
        Msvc.solution_projects = {}
        Msvc._cc_fingerprints[sln:lower()] = 1000

        Msvc:_run_compile_commands(Msvc.settings, nil)

        Util.get_mtime = orig_get_mtime
        CompileCommands.generate = orig_generate
        assert.is_false(generate_called, "generate must not be called when fingerprint matches")
    end)

    it("_run_compile_commands generates and stores fingerprint on success when mtime changed", function()
        local orig_get_mtime = Util.get_mtime
        Util.get_mtime = function(_) return 2000 end
        local orig_generate = CompileCommands.generate
        local captured_on_done
        CompileCommands.generate = function(opts)
            captured_on_done = opts.on_done
            return true
        end

        local sln = "/fake/B.sln"
        Msvc.solution = sln
        Msvc.project = nil
        Msvc.solution_projects = {}
        Msvc._cc_fingerprints[sln:lower()] = 1000  -- stale fingerprint

        Msvc:_run_compile_commands(Msvc.settings, nil)
        -- Simulate the async on_done callback
        assert.is_truthy(captured_on_done, "on_done should be passed to generate")
        captured_on_done(true)

        Util.get_mtime = orig_get_mtime
        CompileCommands.generate = orig_generate
        assert.are.equal(2000, Msvc._cc_fingerprints[sln:lower()], "fingerprint should be stored on success")
    end)

    it("_run_compile_commands does not store fingerprint on failure", function()
        local orig_get_mtime = Util.get_mtime
        Util.get_mtime = function(_) return 3000 end
        local orig_generate = CompileCommands.generate
        local captured_on_done
        CompileCommands.generate = function(opts)
            captured_on_done = opts.on_done
            return true
        end

        local sln = "/fake/C.sln"
        Msvc.solution = sln
        Msvc.project = nil
        Msvc.solution_projects = {}

        Msvc:_run_compile_commands(Msvc.settings, nil)
        captured_on_done(false)  -- simulate failure

        Util.get_mtime = orig_get_mtime
        CompileCommands.generate = orig_generate
        assert.is_nil(Msvc._cc_fingerprints[sln:lower()], "fingerprint must not be stored on failure")
    end)

    it("_run_compile_commands always generates when current_mtime is 0", function()
        local orig_get_mtime = Util.get_mtime
        Util.get_mtime = function(_) return 0 end
        local orig_generate = CompileCommands.generate
        local generate_called = false
        CompileCommands.generate = function(_) generate_called = true return true end

        local sln = "/fake/D.sln"
        Msvc.solution = sln
        Msvc.project = nil
        Msvc.solution_projects = {}
        Msvc._cc_fingerprints[sln:lower()] = 0  -- same as computed mtime

        Msvc:_run_compile_commands(Msvc.settings, nil)

        Util.get_mtime = orig_get_mtime
        CompileCommands.generate = orig_generate
        assert.is_true(generate_called, "must always generate when mtime is 0 (stat failed)")
    end)

    it("_run_compile_commands is a no-op when solution is nil", function()
        local orig_generate = CompileCommands.generate
        local generate_called = false
        CompileCommands.generate = function(_) generate_called = true return true end

        Msvc.solution = nil
        Msvc:_run_compile_commands(Msvc.settings, nil)

        CompileCommands.generate = orig_generate
        assert.is_false(generate_called)
    end)
end)

describe("msvc.init — build on_done auto-cc", function()
    local Msvc, Util, Build, CompileCommands
    local tmpdir

    before_each(function()
        helpers.reset_init_only()
        Msvc = require("msvc")
        Util = require("msvc.util")
        Build = require("msvc.build")
        CompileCommands = require("msvc.compile_commands")
        tmpdir = vim.fn.tempname()
        vim.fn.mkdir(tmpdir, "p")
        Msvc._cc_fingerprints = {}
        Msvc.config = { settings = { compile_commands = { enabled = true } } }
    end)

    after_each(function()
        if tmpdir and vim.fn.isdirectory(tmpdir) == 1 then
            vim.fn.delete(tmpdir, "rf")
        end
    end)

    local function make_file(path)
        vim.fn.mkdir(Util.dirname(path), "p")
        local fh = io.open(path, "wb"); fh:write(""); fh:close()
    end

    local function stub_spawn(on_done_holder)
        local orig = Build.spawn
        Build.spawn = function(opts)
            on_done_holder.fn = opts.on_done
            on_done_holder.target = opts.target
            return true
        end
        return function() Build.spawn = orig end
    end

    it("build() on success calls _run_compile_commands with dispatch-time settings", function()
        local sln = Util.join_path(tmpdir, "A.sln")
        local msbuild = Util.join_path(tmpdir, "MSBuild.exe")
        make_file(sln); make_file(msbuild)
        Msvc.solutions = { sln }
        Msvc.solution = sln
        Msvc.settings = { configuration = "Debug", platform = "x64", jobs = 4 }
        local fake_install = { installationPath = tmpdir }
        Msvc.install = fake_install

        local on_done_holder = {}
        local restore = stub_spawn(on_done_holder)

        local orig_devenv = require("msvc.devenv")
        local orig_find = orig_devenv.find_msbuild
        orig_devenv.find_msbuild = function(_) return msbuild end

        local captured_settings, captured_install_path
        local orig_run = Msvc._run_compile_commands
        Msvc._run_compile_commands = function(self_arg, s, ip)
            captured_settings = s
            captured_install_path = ip
        end

        Msvc:build()
        assert.is_truthy(on_done_holder.fn, "Build.spawn must receive on_done")
        on_done_holder.fn(true)

        orig_devenv.find_msbuild = orig_find
        Msvc._run_compile_commands = orig_run
        restore()

        assert.is_truthy(captured_settings, "_run_compile_commands must be called on success")
        assert.are.equal("Debug", captured_settings.configuration)
        assert.are.equal(tmpdir, captured_install_path)
    end)

    it("build('Clean') does NOT call _run_compile_commands on success", function()
        local sln = Util.join_path(tmpdir, "B.sln")
        local msbuild = Util.join_path(tmpdir, "MSBuild.exe")
        make_file(sln); make_file(msbuild)
        Msvc.solutions = { sln }
        Msvc.solution = sln
        Msvc.settings = { configuration = "Release", platform = "x64" }
        Msvc.install = { installationPath = tmpdir }

        local on_done_holder = {}
        local restore = stub_spawn(on_done_holder)

        local orig_devenv = require("msvc.devenv")
        local orig_find = orig_devenv.find_msbuild
        orig_devenv.find_msbuild = function(_) return msbuild end

        local cc_called = false
        local orig_run = Msvc._run_compile_commands
        Msvc._run_compile_commands = function() cc_called = true end

        Msvc:build("Clean")
        assert.is_truthy(on_done_holder.fn)
        on_done_holder.fn(true)

        orig_devenv.find_msbuild = orig_find
        Msvc._run_compile_commands = orig_run
        restore()

        assert.is_false(cc_called, "_run_compile_commands must NOT be called for Clean")
    end)

    it("build() on failure does NOT call _run_compile_commands", function()
        local sln = Util.join_path(tmpdir, "C.sln")
        local msbuild = Util.join_path(tmpdir, "MSBuild.exe")
        make_file(sln); make_file(msbuild)
        Msvc.solutions = { sln }
        Msvc.solution = sln
        Msvc.settings = { configuration = "Debug", platform = "x64" }
        Msvc.install = { installationPath = tmpdir }

        local on_done_holder = {}
        local restore = stub_spawn(on_done_holder)

        local orig_devenv = require("msvc.devenv")
        local orig_find = orig_devenv.find_msbuild
        orig_devenv.find_msbuild = function(_) return msbuild end

        local cc_called = false
        local orig_run = Msvc._run_compile_commands
        Msvc._run_compile_commands = function() cc_called = true end

        Msvc:build()
        assert.is_truthy(on_done_holder.fn)
        on_done_holder.fn(false)  -- build failed

        orig_devenv.find_msbuild = orig_find
        Msvc._run_compile_commands = orig_run
        restore()

        assert.is_false(cc_called, "_run_compile_commands must NOT be called on failure")
    end)

    it("build('Rebuild') on success calls _run_compile_commands", function()
        local sln = Util.join_path(tmpdir, "D.sln")
        local msbuild = Util.join_path(tmpdir, "MSBuild.exe")
        make_file(sln); make_file(msbuild)
        Msvc.solutions = { sln }
        Msvc.solution = sln
        Msvc.settings = { configuration = "Release", platform = "x64" }
        Msvc.install = { installationPath = tmpdir }

        local on_done_holder = {}
        local restore = stub_spawn(on_done_holder)

        local orig_devenv = require("msvc.devenv")
        local orig_find = orig_devenv.find_msbuild
        orig_devenv.find_msbuild = function(_) return msbuild end

        local cc_called = false
        local orig_run = Msvc._run_compile_commands
        Msvc._run_compile_commands = function() cc_called = true end

        Msvc:build("Rebuild")
        assert.is_truthy(on_done_holder.fn)
        on_done_holder.fn(true)

        orig_devenv.find_msbuild = orig_find
        Msvc._run_compile_commands = orig_run
        restore()

        assert.is_true(cc_called, "_run_compile_commands must be called for Rebuild success")
    end)
end)

describe("msvc.init — build dispatches with fixture solutions", function()
    local Msvc, Config, Util, Build
    local FIXTURES = "tests/fixtures"

    before_each(function()
        helpers.reset_init_only()
        Msvc = require("msvc")
        Config = require("msvc.config")
        Util = require("msvc.util")
        Build = require("msvc.build")
    end)

    local function fixture(rel)
        return Util.normalize_path(Util.join_path(vim.fn.getcwd(), FIXTURES, rel))
    end

    -- Scenario: sol-b (filter-style) — Alpha project Debug|x64 with v141 toolset
    it("build context for sol-b Alpha: Debug|x64, toolset v141", function()
        local sln = fixture("sol-b/filter.sln")
        local proj = fixture("sol-b/src/Alpha/Alpha.vcxproj")
        if not Util.is_file(sln) or not Util.is_file(proj) then
            pending("fixture files not found")
            return
        end
        Msvc.solutions = { sln }
        Msvc.solution = sln
        Msvc.solution_projects = require("msvc.discover").parse_solution_projects(sln)
        Msvc.project = proj
        Msvc.settings = { configuration = "Debug", platform = "x64", arch = "x64", vs_version = "latest", jobs = nil }
        local Discover = require("msvc.discover")
        local tc = Discover.discover_vcxproj_toolchain(proj)
        assert.are.equal("v141", tc.vcvars_ver)
        assert.are.equal("10.0", tc.winsdk)
    end)

    -- Scenario: sol-b Beta project release_static|x64 with v141 toolset
    it("build context for sol-b Beta: release_static|x64, toolset v141", function()
        local sln = fixture("sol-b/filter.sln")
        local proj = fixture("sol-b/src/Beta/Beta.vcxproj")
        if not Util.is_file(sln) or not Util.is_file(proj) then
            pending("fixture files not found")
            return
        end
        Msvc.solution = sln
        Msvc.project = proj
        Msvc.settings = { configuration = "release_static", platform = "x64", arch = "x64", vs_version = "latest", jobs = nil }
        local Discover = require("msvc.discover")
        local tc = Discover.discover_vcxproj_toolchain(proj)
        assert.are.equal("v141", tc.vcvars_ver)
    end)

    -- Scenario: sol-a (owc-style) — full solution, Release|Any CPU
    it("sol-a full-solution Release|Any CPU context parses from sln", function()
        local sln = fixture("sol-a/alpha.sln")
        if not Util.is_file(sln) then
            pending("fixture files not found")
            return
        end
        local Discover = require("msvc.discover")
        local targets = Discover.discover_targets(sln, nil)
        local has_any_cpu = false
        for _, p in ipairs(targets.platforms) do
            if p == "Any CPU" then
                has_any_cpu = true
            end
        end
        assert.is_true(has_any_cpu, "Release|Any CPU should be in sol-a platforms")
        local has_release = false
        for _, c in ipairs(targets.configurations) do
            if c == "Release" then
                has_release = true
            end
        end
        assert.is_true(has_release)
    end)

    -- Scenario: sol-c (demand-style) — full solution, Release|Win32
    it("sol-c full-solution Release|Win32 context parses from sln", function()
        local sln = fixture("sol-c/demand.sln")
        if not Util.is_file(sln) then
            pending("fixture files not found")
            return
        end
        local Discover = require("msvc.discover")
        local targets = Discover.discover_targets(sln, nil)
        local has_win32 = false
        for _, p in ipairs(targets.platforms) do
            if p == "Win32" then
                has_win32 = true
            end
        end
        assert.is_true(has_win32, "Win32 should be in sol-c platforms")
        local has_release = false
        for _, c in ipairs(targets.configurations) do
            if c == "Release" then
                has_release = true
            end
        end
        assert.is_true(has_release)
    end)

    -- Project list parsing for all three fixtures
    it("sol-a parses 3 projects", function()
        local sln = fixture("sol-a/alpha.sln")
        if not Util.is_file(sln) then
            pending("fixture files not found")
            return
        end
        local Discover = require("msvc.discover")
        local projects = Discover.parse_solution_projects(sln)
        assert.are.equal(3, #projects)
        local names = {}
        for _, p in ipairs(projects) do
            names[p.name] = true
        end
        assert.is_true(names["Alpha"])
        assert.is_true(names["Beta"])
        assert.is_true(names["Gamma"])
    end)

    it("sol-b parses 5 projects", function()
        local sln = fixture("sol-b/filter.sln")
        if not Util.is_file(sln) then
            pending("fixture files not found")
            return
        end
        local Discover = require("msvc.discover")
        local projects = Discover.parse_solution_projects(sln)
        assert.are.equal(5, #projects)
    end)

    it("sol-c parses 5 projects", function()
        local sln = fixture("sol-c/demand.sln")
        if not Util.is_file(sln) then
            pending("fixture files not found")
            return
        end
        local Discover = require("msvc.discover")
        local projects = Discover.parse_solution_projects(sln)
        assert.are.equal(5, #projects)
    end)
end)
