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

    -- ─── burn-media fixture (C#-only solution) ──────────────────────────────

    it("parse_solution_projects returns empty for csharp-only sln", function()
        local sln = Util.join_path(
            vim.fn.getcwd(),
            "tests/fixtures/burn-media/BurnMediaCli.sln"
        )
        local out = Discover.parse_solution_projects(sln)
        assert.are.equal(0, #out)  -- only .csproj entries, none are .vcxproj
    end)

    it("discover_targets parses Any CPU platform from BurnMediaCli.sln", function()
        local sln = Util.join_path(
            vim.fn.getcwd(),
            "tests/fixtures/burn-media/BurnMediaCli.sln"
        )
        local r = Discover.discover_targets(sln, nil)
        local function has(t, v)
            for _, x in ipairs(t) do
                if x == v then return true end
            end
            return false
        end
        assert.is_true(has(r.configurations, "Debug"))
        assert.is_true(has(r.configurations, "Release"))
        assert.is_true(has(r.platforms, "Any CPU"))
    end)

    it("find_sln_files discovers BurnMediaCli.sln via rg stub", function()
        local sln = Util.normalize_path(
            Util.join_path(vim.fn.getcwd(), "tests/fixtures/burn-media/BurnMediaCli.sln")
        )
        local orig_executable = vim.fn.executable
        local orig_system = vim.fn.system
        vim.fn.executable = function(cmd) return cmd == "rg" and 1 or 0 end
        vim.fn.system = function(_) return sln .. "\n" end
        local burn_dir = Util.join_path(vim.fn.getcwd(), "tests/fixtures/burn-media")
        local r = Discover.find_sln_files(burn_dir)
        vim.fn.executable = orig_executable
        vim.fn.system = orig_system
        assert.are.equal(1, #r)
        assert.are.equal(sln, r[1])
    end)

    -- ─── find_sln_files ─────────────────────────────────────────────────────

    it("find_sln_files returns empty list for non-existent directory", function()
        local r = Discover.find_sln_files("/nonexistent/path/xyz")
        assert.are.same({}, r)
    end)

    it("find_sln_files uses rg when available and returns normalized paths", function()
        local sln_path = Util.join_path(tmpdir, "Foo.sln")
        write(sln_path, "")

        local orig_executable = vim.fn.executable
        local orig_system = vim.fn.system
        vim.fn.executable = function(cmd) return cmd == "rg" and 1 or 0 end
        local captured_cmd = nil
        vim.fn.system = function(cmd)
            captured_cmd = cmd
            return sln_path .. "\n"
        end

        local r = Discover.find_sln_files(tmpdir)

        vim.fn.executable = orig_executable
        vim.fn.system = orig_system

        assert.is_table(captured_cmd)
        assert.are.equal("rg", captured_cmd[1])
        assert.are.equal("--no-ignore", captured_cmd[2])
        assert.are.equal("--files", captured_cmd[3])
        assert.are.equal("--glob", captured_cmd[4])
        assert.are.equal("*.sln", captured_cmd[5])
        assert.are.equal(1, #r)
        assert.are.equal(Util.normalize_path(sln_path), r[1])
    end)

    it("find_sln_files uses PowerShell when rg is not available", function()
        local sln_path = Util.join_path(tmpdir, "Bar.sln")
        write(sln_path, "")

        local orig_executable = vim.fn.executable
        local orig_system = vim.fn.system
        vim.fn.executable = function(_) return 0 end
        local captured_cmd = nil
        vim.fn.system = function(cmd)
            captured_cmd = cmd
            return sln_path .. "\r\n"
        end

        local r = Discover.find_sln_files(tmpdir)

        vim.fn.executable = orig_executable
        vim.fn.system = orig_system

        assert.is_string(captured_cmd)
        assert.is_truthy(captured_cmd:find("powershell", 1, true))
        assert.is_truthy(captured_cmd:find("Get%-ChildItem"))
        assert.are.equal(1, #r)
        assert.are.equal(Util.normalize_path(sln_path), r[1])
    end)

    it("find_sln_files deduplicates and sorts results", function()
        local sln_a = Util.join_path(tmpdir, "aaa.sln")
        local sln_b = Util.join_path(tmpdir, "bbb.sln")
        write(sln_a, "")
        write(sln_b, "")

        local orig_executable = vim.fn.executable
        local orig_system = vim.fn.system
        vim.fn.executable = function(cmd) return cmd == "rg" and 1 or 0 end
        vim.fn.system = function(_)
            -- Return b before a, and duplicate b
            return sln_b .. "\n" .. sln_a .. "\n" .. sln_b .. "\n"
        end

        local r = Discover.find_sln_files(tmpdir)

        vim.fn.executable = orig_executable
        vim.fn.system = orig_system

        assert.are.equal(2, #r)
        assert.is_true(r[1] < r[2], "results should be sorted")
    end)

    -- ─── parse_vcxproj_defines ──────────────────────────────────────────────

    describe("parse_vcxproj_defines", function()
        it("returns correct defines for matching Configuration|Platform", function()
            local vcxproj = Util.join_path(tmpdir, "defines.vcxproj")
            write(
                vcxproj,
                table.concat({
                    "<Project>",
                    "  <ItemDefinitionGroup Condition=\"'$(Configuration)|$(Platform)'=='Debug|x64'\">",
                    "    <ClCompile>",
                    "      <PreprocessorDefinitions>FOO;BAR=1;%(PreprocessorDefinitions)</PreprocessorDefinitions>",
                    "    </ClCompile>",
                    "  </ItemDefinitionGroup>",
                    "</Project>",
                }, "\n")
            )
            local r = Discover.parse_vcxproj_defines(vcxproj, "Debug", "x64")
            assert.are.same({ "-DFOO", "-DBAR=1" }, r)
        end)

        it("returns {} when condition block is absent", function()
            local vcxproj = Util.join_path(tmpdir, "nodefs.vcxproj")
            write(vcxproj, "<Project/>")
            local r = Discover.parse_vcxproj_defines(vcxproj, "Debug", "x64")
            assert.are.same({}, r)
        end)

        it("drops %(PreprocessorDefinitions) tokens", function()
            local vcxproj = Util.join_path(tmpdir, "inherit.vcxproj")
            write(
                vcxproj,
                table.concat({
                    "<Project>",
                    "  <ItemDefinitionGroup Condition=\"'$(Configuration)|$(Platform)'=='Release|Win32'\">",
                    "    <ClCompile>",
                    "      <PreprocessorDefinitions>NDEBUG;%(PreprocessorDefinitions)</PreprocessorDefinitions>",
                    "    </ClCompile>",
                    "  </ItemDefinitionGroup>",
                    "</Project>",
                }, "\n")
            )
            local r = Discover.parse_vcxproj_defines(vcxproj, "Release", "Win32")
            assert.are.same({ "-DNDEBUG" }, r)
        end)

        it("returns {} for missing or nil file", function()
            assert.are.same({}, Discover.parse_vcxproj_defines(nil, "Debug", "x64"))
            assert.are.same(
                {},
                Discover.parse_vcxproj_defines("/nonexistent.vcxproj", "Debug", "x64")
            )
        end)

        it("falls back to unconditional ItemDefinitionGroup", function()
            local vcxproj = Util.join_path(tmpdir, "uncond.vcxproj")
            write(
                vcxproj,
                table.concat({
                    "<Project>",
                    "  <ItemDefinitionGroup>",
                    "    <ClCompile>",
                    "      <PreprocessorDefinitions>GLOBAL_DEFINE;%(PreprocessorDefinitions)</PreprocessorDefinitions>",
                    "    </ClCompile>",
                    "  </ItemDefinitionGroup>",
                    "</Project>",
                }, "\n")
            )
            local r = Discover.parse_vcxproj_defines(vcxproj, "Debug", "x64")
            assert.are.same({ "-DGLOBAL_DEFINE" }, r)
        end)

        it("handles multiple defines separated by semicolons", function()
            local vcxproj = Util.join_path(tmpdir, "multi.vcxproj")
            write(
                vcxproj,
                table.concat({
                    "<Project>",
                    "  <ItemDefinitionGroup Condition=\"'$(Configuration)|$(Platform)'=='Debug|x64'\">",
                    "    <ClCompile>",
                    "      <PreprocessorDefinitions>A;B=2;C=hello;%(PreprocessorDefinitions)</PreprocessorDefinitions>",
                    "    </ClCompile>",
                    "  </ItemDefinitionGroup>",
                    "</Project>",
                }, "\n")
            )
            local r = Discover.parse_vcxproj_defines(vcxproj, "Debug", "x64")
            assert.are.same({ "-DA", "-DB=2", "-DC=hello" }, r)
        end)
    end)

    it("find_sln_files returns empty list when system returns nothing", function()
        local orig_executable = vim.fn.executable
        local orig_system = vim.fn.system
        vim.fn.executable = function(cmd) return cmd == "rg" and 1 or 0 end
        vim.fn.system = function(_) return "" end

        local r = Discover.find_sln_files(tmpdir)

        vim.fn.executable = orig_executable
        vim.fn.system = orig_system

        assert.are.same({}, r)
    end)
end)
