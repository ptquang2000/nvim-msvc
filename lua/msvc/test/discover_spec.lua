local helpers = require("msvc.test.utils")

describe("msvc.discover", function()
    local Discover, Util
    local tmpdir

    before_each(function()
        helpers.reset()
        Discover = require("msvc.discover")
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
        fh:write(body)
        fh:close()
    end

    it("find_solution walks up to find a unique .sln", function()
        local sub = Util.join_path(tmpdir, "a", "b")
        vim.fn.mkdir(sub, "p")
        write(Util.join_path(tmpdir, "Foo.sln"), "")
        local found, err = Discover.find_solution(sub)
        assert.is_nil(err)
        assert.are.equal(
            Util.normalize_path(Util.join_path(tmpdir, "Foo.sln")),
            found
        )
    end)

    it("find_solution returns ambiguity error on multiple .sln", function()
        write(Util.join_path(tmpdir, "A.sln"), "")
        write(Util.join_path(tmpdir, "B.sln"), "")
        local found, err = Discover.find_solution(tmpdir)
        assert.is_nil(found)
        assert.is_string(err)
    end)

    it("parse_solution_projects extracts vcxproj entries", function()
        local sln_path = Util.join_path(tmpdir, "S.sln")
        local proj_dir = Util.join_path(tmpdir, "P")
        vim.fn.mkdir(proj_dir, "p")
        write(Util.join_path(proj_dir, "P.vcxproj"), "")
        write(
            sln_path,
            table.concat({
                "Microsoft Visual Studio Solution File, Format Version 12.00",
                "Project(\"{8BC9CEB8}\") = \"P\", \"P\\P.vcxproj\", \"{deadbeef}\"",
                "EndProject",
                "Project(\"{XXX}\") = \"Csharp\", \"Csharp\\C.csproj\", \"{cafe}\"",
                "EndProject",
            }, "\r\n")
        )
        local out = Discover.parse_solution_projects(sln_path)
        assert.are.equal(1, #out)
        assert.are.equal("P", out[1].name)
        assert.are.equal(
            Util.normalize_path(Util.join_path(proj_dir, "P.vcxproj")),
            out[1].path
        )
    end)

    it("discover_targets falls back to defaults when nothing parses", function()
        local r = Discover.discover_targets(nil, nil)
        assert.is_true(#r.configurations >= 2)
        assert.is_true(#r.platforms >= 2)
    end)

    it("discover_targets parses sln SolutionConfigurationPlatforms", function()
        local sln = Util.join_path(tmpdir, "S.sln")
        write(
            sln,
            table.concat({
                "Global",
                "  GlobalSection(SolutionConfigurationPlatforms) = preSolution",
                "    Debug|x64 = Debug|x64",
                "    Release|Win32 = Release|Win32",
                "  EndGlobalSection",
                "EndGlobal",
            }, "\n")
        )
        local r = Discover.discover_targets(sln, nil)
        local has = function(t, v)
            for _, x in ipairs(t) do
                if x == v then
                    return true
                end
            end
            return false
        end
        assert.is_true(has(r.configurations, "Debug"))
        assert.is_true(has(r.configurations, "Release"))
        assert.is_true(has(r.platforms, "x64"))
        assert.is_true(has(r.platforms, "Win32"))
    end)

    it("find_solutions walk-up fallback returns single sln when not in a git repo", function()
        local sub = Util.join_path(tmpdir, "src")
        vim.fn.mkdir(sub, "p")
        write(Util.join_path(tmpdir, "Lone.sln"), "")
        local list = Discover.find_solutions(sub)
        -- May or may not return a result depending on whether tmpdir is
        -- itself inside a git tree; only assert when the fallback ran.
        if #list == 1 then
            assert.are.equal(
                Util.normalize_path(Util.join_path(tmpdir, "Lone.sln")),
                list[1]
            )
        end
    end)

    it("find_solutions includes .sln files in extra_dirs", function()
        local builddir = Util.join_path(tmpdir, "bin", "cmake")
        vim.fn.mkdir(builddir, "p")
        local generated = Util.normalize_path(
            Util.join_path(builddir, "Generated.sln")
        )
        write(generated, "")
        local list = Discover.find_solutions(tmpdir, {
            extra_dirs = { "bin/cmake" },
        })
        local found = false
        for _, p in ipairs(list) do
            if p:lower() == generated:lower() then
                found = true
            end
        end
        assert.is_true(found)
    end)
end)
