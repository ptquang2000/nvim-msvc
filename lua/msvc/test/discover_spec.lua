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

    it("discover_targets parses platforms with spaces (Any CPU)", function()
        local sln = Util.join_path(tmpdir, "S.sln")
        write(
            sln,
            table.concat({
                "Global",
                "\tGlobalSection(SolutionConfigurationPlatforms) = preSolution",
                "\t\tDebug|Any CPU = Debug|Any CPU",
                "\t\tRelease|Any CPU = Release|Any CPU",
                "\tEndGlobalSection",
                "EndGlobal",
            }, "\r\n")
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
        assert.is_true(has(r.platforms, "Any CPU"))
    end)

    it("discover_vcxproj_toolchain parses WindowsTargetPlatformVersion", function()
        local vcxproj = Util.join_path(tmpdir, "proj.vcxproj")
        write(
            vcxproj,
            table.concat({
                "<?xml version=\"1.0\" encoding=\"utf-8\"?>",
                "<Project xmlns=\"http://schemas.microsoft.com/developer/msbuild/2003\">",
                "  <PropertyGroup>",
                "    <WindowsTargetPlatformVersion>10.0.19041.0</WindowsTargetPlatformVersion>",
                "    <PlatformToolset>v142</PlatformToolset>",
                "  </PropertyGroup>",
                "</Project>",
            }, "\n")
        )
        local r = Discover.discover_vcxproj_toolchain(vcxproj)
        assert.are.equal("10.0.19041.0", r.winsdk)
        assert.are.equal("v142", r.vcvars_ver)
    end)

    it("discover_vcxproj_toolchain returns empty table for missing file", function()
        local r = Discover.discover_vcxproj_toolchain(nil)
        assert.are.same({}, r)
        local r2 = Discover.discover_vcxproj_toolchain("/nonexistent.vcxproj")
        assert.are.same({}, r2)
    end)

    it("discover_vcxproj_toolchain returns nil fields when tags are absent", function()
        local vcxproj = Util.join_path(tmpdir, "bare.vcxproj")
        write(vcxproj, "<Project/>")
        local r = Discover.discover_vcxproj_toolchain(vcxproj)
        assert.is_nil(r.winsdk)
        assert.is_nil(r.vcvars_ver)
    end)

    it("discover_vcxproj_toolchain detects v141 toolset (VS 2017)", function()
        local vcxproj = Util.join_path(tmpdir, "vs2017.vcxproj")
        write(
            vcxproj,
            "<Project><PropertyGroup><PlatformToolset>v141</PlatformToolset></PropertyGroup></Project>"
        )
        local r = Discover.discover_vcxproj_toolchain(vcxproj)
        assert.are.equal("v141", r.vcvars_ver)
    end)
end)
