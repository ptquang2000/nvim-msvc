local helpers = require("msvc.test.utils")

describe("msvc.compile_commands", function()
    local CC

    before_each(function()
        helpers.reset()
        CC = require("msvc.compile_commands")
    end)

    it("is_enabled defaults to true", function()
        assert.is_true(CC.is_enabled(nil))
        assert.is_true(CC.is_enabled({}))
        assert.is_true(CC.is_enabled({ enabled = true }))
        assert.is_false(CC.is_enabled({ enabled = false }))
    end)

    it("build_argv serializes solution + flags, no --project, always --merge-defaults", function()
        local argv = CC._internal.build_argv({
            extractor = "extractor.exe",
            solution = "C:\\foo.sln",
            configuration = "Release",
            platform = "Win32",
            outpath = "C:\\out\\compile_commands.json",
            vs_path = "C:\\VS\\2022",
        })
        local s = table.concat(argv, "|")
        local f = function(needle)
            return s:find(needle, 1, true)
        end
        assert.is_truthy(f("extractor.exe"))
        assert.is_truthy(f("--solution|C:\\foo.sln"))
        assert.is_falsy(f("--project"))
        assert.is_truthy(f("--merge-defaults"))
        assert.is_truthy(f("-c|Release"))
        assert.is_truthy(f("-a|Win32"))
        assert.is_truthy(f("--vs-path|C:\\VS\\2022"))
        assert.is_truthy(f("-o|C:\\out\\compile_commands.json"))
        assert.is_truthy(f("--deduplicate"))
    end)

    it("build_argv includes --vc-tools-install-dir when provided", function()
        local argv = CC._internal.build_argv({
            extractor = "extractor.exe",
            solution = "C:\\foo.sln",
            outpath = "C:\\out\\compile_commands.json",
            vs_path = "C:\\VS\\2022",
            vc_tools_install_dir = "C:\\VS\\2022\\VC\\Tools\\MSVC\\14.39.33519",
        })
        local s = table.concat(argv, "|")
        local f = function(needle) return s:find(needle, 1, true) end
        assert.is_truthy(f("--vc-tools-install-dir|C:\\VS\\2022\\VC\\Tools\\MSVC\\14.39.33519"))
    end)

    it("build_argv omits --vc-tools-install-dir when nil or empty", function()
        local argv_nil = CC._internal.build_argv({
            extractor = "extractor.exe",
            solution = "C:\\foo.sln",
            outpath = "C:\\out\\compile_commands.json",
            vc_tools_install_dir = nil,
        })
        local argv_empty = CC._internal.build_argv({
            extractor = "extractor.exe",
            solution = "C:\\foo.sln",
            outpath = "C:\\out\\compile_commands.json",
            vc_tools_install_dir = "",
        })
        assert.is_falsy(table.concat(argv_nil, "|"):find("--vc-tools-install-dir", 1, true))
        assert.is_falsy(table.concat(argv_empty, "|"):find("--vc-tools-install-dir", 1, true))
    end)

    describe("find_vc_tools_install_dir", function()
        it("returns nil for nil input", function()
            assert.is_nil(CC._internal.find_vc_tools_install_dir(nil))
        end)

        it("returns nil for empty string input", function()
            assert.is_nil(CC._internal.find_vc_tools_install_dir(""))
        end)

        it("returns nil for non-existent base path", function()
            assert.is_nil(CC._internal.find_vc_tools_install_dir("C:\\does\\not\\exist\\vs"))
        end)
    end)

    it("resolve_anchor falls back to project / cwd", function()
        local Util = require("msvc.util")
        local cwd = vim.fn.getcwd()
        assert.are.equal(
            Util.normalize_path(cwd),
            CC._internal.resolve_anchor(nil, nil)
        )
    end)

    describe("per-solution log lines in generate", function()
        local Log

        before_each(function()
            Log = require("msvc.log")
        end)

        it("emits [i/n] starting: and [i/n] done: for each solution", function()
            local appended = {}
            local orig_append = Log.build_append
            Log.build_append = function(_, msg, ...)
                appended[#appended + 1] = msg:format(...)
            end

            -- Stub vim.system to succeed immediately (synchronously via schedule)
            local orig_system = vim.system
            vim.system = function(_, _, cb)
                vim.schedule(function() cb({ code = 0, stderr = "" }) end)
                return { pid = 1 }
            end

            CC.reset_cache()
            CC._extractor_path = "/fake/extractor"

            local called_done = false
            CC.generate({
                solution = "/fake/A.sln",
                configuration = "Debug",
                platform = "x64",
                cc = { enabled = true },
                vs_path = "",
                on_done = function() called_done = true end,
            })

            vim.wait(500, function() return called_done end, 10)

            Log.build_append = orig_append
            vim.system = orig_system

            local has_starting = false
            local has_done = false
            for _, line in ipairs(appended) do
                if line:find("%[1/1%] starting: A%.sln") then has_starting = true end
                if line:find("%[1/1%] done: A%.sln") then has_done = true end
            end
            assert.is_true(has_starting, "must emit [1/1] starting: A.sln")
            assert.is_true(has_done, "must emit [1/1] done: A.sln")
        end)

        it("emits [i/n] extractor error line on failure, no done line", function()
            local appended = {}
            local orig_append = Log.build_append
            Log.build_append = function(_, msg, ...)
                appended[#appended + 1] = msg:format(...)
            end

            local orig_system = vim.system
            vim.system = function(_, _, cb)
                vim.schedule(function() cb({ code = 1, stderr = "fatal error" }) end)
                return { pid = 1 }
            end

            CC.reset_cache()
            CC._extractor_path = "/fake/extractor"

            local called_done = false
            CC.generate({
                solution = "/fake/B.sln",
                configuration = "Debug",
                platform = "x64",
                cc = { enabled = true },
                vs_path = "",
                on_done = function() called_done = true end,
            })

            vim.wait(500, function() return called_done end, 10)

            Log.build_append = orig_append
            vim.system = orig_system

            local has_starting = false
            local has_done = false
            local has_error = false
            for _, line in ipairs(appended) do
                if line:find("%[1/1%] starting: B%.sln") then has_starting = true end
                if line:find("%[1/1%] done: B%.sln") then has_done = true end
                if line:find("extractor exit") then has_error = true end
            end
            assert.is_true(has_starting, "must emit starting line even on failure")
            assert.is_false(has_done, "must NOT emit done line on failure")
            assert.is_true(has_error, "must emit error line on failure")
        end)
    end)

    it("resolve_outpath returns solution-root path", function()
        local Util = require("msvc.util")
        local sln = Util.join_path(vim.fn.getcwd(), "tests", "fixtures", "burn-media", "BurnMediaCli.sln")
        local outpath = CC._internal.resolve_outpath(sln, nil)
        assert.is_not_nil(outpath)
        local expected_dir = Util.normalize_path(Util.dirname(sln))
        assert.are.equal(Util.join_path(expected_dir, "compile_commands.json"), outpath)
    end)

    describe("generate_clangd", function()
        local tmpdir

        before_each(function()
            tmpdir = vim.fn.tempname()
            vim.fn.mkdir(tmpdir, "p")
        end)

        after_each(function()
            if tmpdir and vim.fn.isdirectory(tmpdir) == 1 then
                vim.fn.delete(tmpdir, "rf")
            end
        end)

        local function read_clangd(dir)
            local Util = require("msvc.util")
            local f = io.open(Util.join_path(dir, ".clangd"), "r")
            if not f then return nil end
            local c = f:read("*a")
            f:close()
            return c
        end

        it("writes .clangd at outdir with all Remove entries present", function()
            local ok = CC._internal.generate_clangd({ outdir = tmpdir })
            assert.is_true(ok)
            local c = read_clangd(tmpdir)
            assert.is_not_nil(c)
            assert.is_truthy(c:find("Generated by nvim-msvc", 1, true))
            assert.is_truthy(c:find("CompilationDatabase: .", 1, true))
            for _, flag in ipairs({ "/Zc:*", "/MP", "/analyze", "/sdl", "/GS", "/RTC1",
                                    "/GL", "/Gw", "/Gy", "/Gm-", "/ZH:SHA_256", "/Wall" }) do
                assert.is_truthy(c:find(flag, 1, true), "missing flag: " .. flag)
            end
        end)

        it("Add block is absent when no project is pinned", function()
            CC._internal.generate_clangd({ outdir = tmpdir })
            local c = read_clangd(tmpdir)
            assert.is_falsy(c:find("  Add:", 1, true))
        end)

        it("Add block is present with correct defines when project is pinned", function()
            local Util = require("msvc.util")
            local vcxproj = Util.join_path(tmpdir, "Proj.vcxproj")
            local fh = io.open(vcxproj, "wb")
            fh:write(table.concat({
                "<Project>",
                "  <ItemDefinitionGroup Condition=\"'$(Configuration)|$(Platform)'=='Debug|x64'\">",
                "    <ClCompile>",
                "      <PreprocessorDefinitions>MY_DEFINE;%(PreprocessorDefinitions)</PreprocessorDefinitions>",
                "    </ClCompile>",
                "  </ItemDefinitionGroup>",
                "</Project>",
            }, "\n"))
            fh:close()

            CC._internal.generate_clangd({
                outdir = tmpdir,
                project = vcxproj,
                configuration = "Debug",
                platform = "x64",
            })

            local c = read_clangd(tmpdir)
            assert.is_truthy(c:find("  Add:", 1, true))
            assert.is_truthy(c:find("-DMY_DEFINE", 1, true))
        end)

        it("overwrites an existing .clangd", function()
            local Util = require("msvc.util")
            local clangd_path = Util.join_path(tmpdir, ".clangd")
            local fw = io.open(clangd_path, "w")
            fw:write("old content")
            fw:close()

            CC._internal.generate_clangd({ outdir = tmpdir })

            local c = read_clangd(tmpdir)
            assert.is_falsy(c:find("old content", 1, true))
            assert.is_truthy(c:find("Generated by nvim-msvc", 1, true))
        end)

        it("Add block contains -I<km_path> for kernel-mode toolset", function()
            local km_path = CC._internal.find_wdk_km_path("10.0.17763.0")
            if not km_path then
                pending("WDK 10.0.17763.0 km\\ dir not found — skipping")
                return
            end
            local Util = require("msvc.util")
            local vcxproj = Util.join_path(tmpdir, "KmProj.vcxproj")
            local fh = io.open(vcxproj, "wb")
            fh:write(table.concat({
                "<Project>",
                "  <PropertyGroup>",
                "    <PlatformToolset>WindowsKernelModeDriver10.0</PlatformToolset>",
                "    <WindowsTargetPlatformVersion>10.0.17763.0</WindowsTargetPlatformVersion>",
                "  </PropertyGroup>",
                "</Project>",
            }, "\n"))
            fh:close()

            CC._internal.generate_clangd({
                outdir = tmpdir,
                project = vcxproj,
                configuration = "Debug",
                platform = "x64",
            })

            local c = read_clangd(tmpdir)
            assert.is_truthy(c:find("  Add:", 1, true))
            assert.is_truthy(c:find("-I" .. km_path:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"), 1, false),
                "expected -I" .. km_path .. " in .clangd")
        end)

        it("Add block contains arch and OS defines for kernel-mode x64 project", function()
            local Util = require("msvc.util")
            local vcxproj = Util.join_path(tmpdir, "KmProjX64.vcxproj")
            local fh = io.open(vcxproj, "wb")
            fh:write(table.concat({
                "<Project>",
                "  <PropertyGroup>",
                "    <PlatformToolset>WindowsKernelModeDriver10.0</PlatformToolset>",
                "    <WindowsTargetPlatformVersion>10.0.17763.0</WindowsTargetPlatformVersion>",
                "  </PropertyGroup>",
                "</Project>",
            }, "\n"))
            fh:close()

            CC._internal.generate_clangd({
                outdir = tmpdir,
                project = vcxproj,
                configuration = "Debug",
                platform = "x64",
            })

            local c = read_clangd(tmpdir)
            assert.is_truthy(c:find("-D_WIN64", 1, true))
            assert.is_truthy(c:find("-D_AMD64_", 1, true))
            assert.is_truthy(c:find("-DAMD64", 1, true))
            assert.is_truthy(c:find("-D_WIN32_WINNT=0x0A00", 1, true))
            assert.is_truthy(c:find("-DWINVER=0x0A00", 1, true))
        end)

        it("Add block contains arch defines for kernel-mode ARM64 project", function()
            local Util = require("msvc.util")
            local vcxproj = Util.join_path(tmpdir, "KmProjArm64.vcxproj")
            local fh = io.open(vcxproj, "wb")
            fh:write(table.concat({
                "<Project>",
                "  <PropertyGroup>",
                "    <PlatformToolset>WindowsKernelModeDriver10.0</PlatformToolset>",
                "    <WindowsTargetPlatformVersion>10.0.17763.0</WindowsTargetPlatformVersion>",
                "  </PropertyGroup>",
                "</Project>",
            }, "\n"))
            fh:close()

            CC._internal.generate_clangd({
                outdir = tmpdir,
                project = vcxproj,
                configuration = "Debug",
                platform = "ARM64",
            })

            local c = read_clangd(tmpdir)
            assert.is_truthy(c:find("-D_WIN64", 1, true))
            assert.is_truthy(c:find("-D_ARM64_", 1, true))
            assert.is_truthy(c:find("-DARM64", 1, true))
            assert.is_falsy(c:find("-D_AMD64_", 1, true))
        end)

        it("Add block contains arch defines for kernel-mode Win32 project", function()
            local Util = require("msvc.util")
            local vcxproj = Util.join_path(tmpdir, "KmProjWin32.vcxproj")
            local fh = io.open(vcxproj, "wb")
            fh:write(table.concat({
                "<Project>",
                "  <PropertyGroup>",
                "    <PlatformToolset>WindowsKernelModeDriver10.0</PlatformToolset>",
                "    <WindowsTargetPlatformVersion>10.0.17763.0</WindowsTargetPlatformVersion>",
                "  </PropertyGroup>",
                "</Project>",
            }, "\n"))
            fh:close()

            CC._internal.generate_clangd({
                outdir = tmpdir,
                project = vcxproj,
                configuration = "Debug",
                platform = "Win32",
            })

            local c = read_clangd(tmpdir)
            assert.is_truthy(c:find("-D_X86_", 1, true))
            assert.is_falsy(c:find("-D_WIN64", 1, true))
        end)

        it("user-mode toolset does not inject WDK arch or OS defines", function()
            local Util = require("msvc.util")
            local vcxproj = Util.join_path(tmpdir, "UmProjNoDef.vcxproj")
            local fh = io.open(vcxproj, "wb")
            fh:write(table.concat({
                "<Project>",
                "  <PropertyGroup>",
                "    <PlatformToolset>v143</PlatformToolset>",
                "    <WindowsTargetPlatformVersion>10.0.22621.0</WindowsTargetPlatformVersion>",
                "  </PropertyGroup>",
                "</Project>",
            }, "\n"))
            fh:close()

            CC._internal.generate_clangd({
                outdir = tmpdir,
                project = vcxproj,
                configuration = "Debug",
                platform = "x64",
            })

            local c = read_clangd(tmpdir)
            assert.is_falsy(c:find("-D_AMD64_", 1, true))
            assert.is_falsy(c:find("-D_WIN32_WINNT=", 1, true))
            assert.is_falsy(c:find("-DWINVER=", 1, true))
        end)

        it("Add block has no -I flag for user-mode toolset even with defines", function()
            local Util = require("msvc.util")
            local vcxproj = Util.join_path(tmpdir, "UmProj.vcxproj")
            local fh = io.open(vcxproj, "wb")
            fh:write(table.concat({
                "<Project>",
                "  <PropertyGroup>",
                "    <PlatformToolset>v143</PlatformToolset>",
                "    <WindowsTargetPlatformVersion>10.0.22621.0</WindowsTargetPlatformVersion>",
                "  </PropertyGroup>",
                "  <ItemDefinitionGroup Condition=\"'$(Configuration)|$(Platform)'=='Debug|x64'\">",
                "    <ClCompile>",
                "      <PreprocessorDefinitions>UM_DEFINE;%(PreprocessorDefinitions)</PreprocessorDefinitions>",
                "    </ClCompile>",
                "  </ItemDefinitionGroup>",
                "</Project>",
            }, "\n"))
            fh:close()

            CC._internal.generate_clangd({
                outdir = tmpdir,
                project = vcxproj,
                configuration = "Debug",
                platform = "x64",
            })

            local c = read_clangd(tmpdir)
            assert.is_falsy(c:find("    - -I", 1, true), "no -I flag expected for user-mode toolset")
            assert.is_truthy(c:find("-DUM_DEFINE", 1, true))
        end)
    end)

    describe("wdk_arch_defines", function()
        it("returns correct defines for x64", function()
            local d = CC._internal.wdk_arch_defines("x64")
            assert.is_truthy(vim.tbl_contains(d, "-D_WIN64"))
            assert.is_truthy(vim.tbl_contains(d, "-D_AMD64_"))
            assert.is_truthy(vim.tbl_contains(d, "-DAMD64"))
        end)

        it("returns correct defines for ARM64", function()
            local d = CC._internal.wdk_arch_defines("ARM64")
            assert.is_truthy(vim.tbl_contains(d, "-D_WIN64"))
            assert.is_truthy(vim.tbl_contains(d, "-D_ARM64_"))
            assert.is_truthy(vim.tbl_contains(d, "-DARM64"))
        end)

        it("returns correct defines for ARM", function()
            local d = CC._internal.wdk_arch_defines("ARM")
            assert.is_truthy(vim.tbl_contains(d, "-D_ARM_"))
            assert.are.equal(1, #d)
        end)

        it("returns correct defines for Win32", function()
            local d = CC._internal.wdk_arch_defines("Win32")
            assert.is_truthy(vim.tbl_contains(d, "-D_X86_"))
            assert.are.equal(1, #d)
        end)

        it("returns empty table for nil", function()
            assert.are.equal(0, #CC._internal.wdk_arch_defines(nil))
        end)

        it("returns empty table for unknown platform", function()
            assert.are.equal(0, #CC._internal.wdk_arch_defines("RISCV64"))
        end)
    end)

    describe("wdk_win32_winnt", function()
        it("returns 0x0A00 for Windows 10", function()
            assert.are.equal("0x0A00", CC._internal.wdk_win32_winnt("10.0.17763.0"))
        end)

        it("returns 0x0A00 for any 10.x.x.x", function()
            assert.are.equal("0x0A00", CC._internal.wdk_win32_winnt("10.0.22621.0"))
        end)

        it("returns 0x0603 for Windows 8.1", function()
            assert.are.equal("0x0603", CC._internal.wdk_win32_winnt("6.3.9600.0"))
        end)

        it("returns 0x0602 for Windows 8", function()
            assert.are.equal("0x0602", CC._internal.wdk_win32_winnt("6.2.9200.0"))
        end)

        it("returns 0x0601 for Windows 7", function()
            assert.are.equal("0x0601", CC._internal.wdk_win32_winnt("6.1.7601.0"))
        end)

        it("returns nil for nil input", function()
            assert.is_nil(CC._internal.wdk_win32_winnt(nil))
        end)

        it("returns nil for empty string", function()
            assert.is_nil(CC._internal.wdk_win32_winnt(""))
        end)

        it("returns nil for unrecognised major version", function()
            assert.is_nil(CC._internal.wdk_win32_winnt("5.1.2600.0"))
        end)

        it("returns nil for unrecognised Windows 6.x minor", function()
            assert.is_nil(CC._internal.wdk_win32_winnt("6.0.6002.0"))
        end)
    end)

    describe("find_wdk_km_path", function()
        it("returns nil for a non-existent winsdk version", function()
            local orig = vim.fn.system
            vim.fn.system = function() return "" end
            local result = CC._internal.find_wdk_km_path("99.0.0.0")
            vim.fn.system = orig
            assert.is_nil(result)
        end)

        it("returns a valid km\\ directory for the installed WDK version", function()
            local path = CC._internal.find_wdk_km_path("10.0.17763.0")
            if path == nil then
                pending("WDK 10.0.17763.0 not installed — skipping")
                return
            end
            local Util = require("msvc.util")
            assert.is_true(Util.is_dir(path), "returned path must be a directory: " .. path)
            assert.is_truthy(path:lower():find("\\km", 1, true), "path must end with \\km")
        end)
    end)

    describe("generate_clangd build-order define union", function()
        local tmpdir

        before_each(function()
            tmpdir = vim.fn.tempname()
            vim.fn.mkdir(tmpdir, "p")
        end)

        after_each(function()
            if tmpdir and vim.fn.isdirectory(tmpdir) == 1 then
                vim.fn.delete(tmpdir, "rf")
            end
        end)

        local function read_clangd(dir)
            local Util = require("msvc.util")
            local f = io.open(Util.join_path(dir, ".clangd"), "r")
            if not f then return nil end
            local c = f:read("*a")
            f:close()
            return c
        end

        -- Write a .vcxproj with a single Debug|x64 PreprocessorDefinitions list.
        local function write_proj(path, defs)
            local fh = io.open(path, "wb")
            fh:write(table.concat({
                "<Project>",
                "  <ItemDefinitionGroup Condition=\"'$(Configuration)|$(Platform)'=='Debug|x64'\">",
                "    <ClCompile>",
                "      <PreprocessorDefinitions>" .. defs ..
                    ";%(PreprocessorDefinitions)</PreprocessorDefinitions>",
                "    </ClCompile>",
                "  </ItemDefinitionGroup>",
                "</Project>",
            }, "\n"))
            fh:close()
        end

        -- Write a .sln referencing the given { name = relpath } projects, in order.
        local function write_sln(path, projects)
            local fh = io.open(path, "wb")
            fh:write("Microsoft Visual Studio Solution File, Format Version 12.00\n")
            for _, p in ipairs(projects) do
                fh:write(("Project(\"{GUID}\") = \"%s\", \"%s\", \"{P}\"\nEndProject\n")
                    :format(p.name, p.rel))
            end
            fh:close()
        end

        it("emits Add as a union of all projects' defines even when none pinned", function()
            local Util = require("msvc.util")
            write_proj(Util.join_path(tmpdir, "A.vcxproj"), "DEF_A")
            write_proj(Util.join_path(tmpdir, "B.vcxproj"), "DEF_B")
            local sln = Util.join_path(tmpdir, "main.sln")
            write_sln(sln, { { name = "A", rel = "A.vcxproj" }, { name = "B", rel = "B.vcxproj" } })

            CC._internal.generate_clangd({
                outdir = tmpdir,
                configuration = "Debug",
                platform = "x64",
                solutions = { sln },
            })

            local c = read_clangd(tmpdir)
            assert.is_truthy(c:find("  Add:", 1, true))
            assert.is_truthy(c:find("-DDEF_A", 1, true))
            assert.is_truthy(c:find("-DDEF_B", 1, true))
        end)

        it("dedups conflicting macros by name, build-order-last wins", function()
            local Util = require("msvc.util")
            -- Two solutions both define SHARED with different values.
            write_proj(Util.join_path(tmpdir, "Sub.vcxproj"), "SHARED=1")
            write_proj(Util.join_path(tmpdir, "Main.vcxproj"), "SHARED=2")
            local sub = Util.join_path(tmpdir, "sub.sln")
            local main = Util.join_path(tmpdir, "main.sln")
            write_sln(sub, { { name = "Sub", rel = "Sub.vcxproj" } })
            write_sln(main, { { name = "Main", rel = "Main.vcxproj" } })

            -- Build order = subs first, main last → main's SHARED=2 wins.
            CC._internal.generate_clangd({
                outdir = tmpdir,
                configuration = "Debug",
                platform = "x64",
                solutions = { sub, main },
            })

            local c = read_clangd(tmpdir)
            -- Exactly one entry for SHARED, and it is =2.
            local _, count = c:gsub("%-DSHARED", "")
            assert.are.equal(1, count, "expected exactly one -DSHARED entry")
            assert.is_truthy(c:find("-DSHARED=2", 1, true))
            assert.is_falsy(c:find("-DSHARED=1", 1, true))
        end)

        it("pinned project's define overrides all others for the same macro", function()
            local Util = require("msvc.util")
            write_proj(Util.join_path(tmpdir, "Other.vcxproj"), "SHARED=2")
            local pinned = Util.join_path(tmpdir, "Pinned.vcxproj")
            write_proj(pinned, "SHARED=99")
            local main = Util.join_path(tmpdir, "main.sln")
            write_sln(main, {
                { name = "Other", rel = "Other.vcxproj" },
                { name = "Pinned", rel = "Pinned.vcxproj" },
            })

            CC._internal.generate_clangd({
                outdir = tmpdir,
                project = pinned,
                configuration = "Debug",
                platform = "x64",
                solutions = { main },
            })

            local c = read_clangd(tmpdir)
            local _, count = c:gsub("%-DSHARED", "")
            assert.are.equal(1, count, "expected exactly one -DSHARED entry")
            assert.is_truthy(c:find("-DSHARED=99", 1, true))
        end)
    end)

    it("merge_temp_files keep-last: [subs…, main] order keeps main, later sub wins", function()
        -- temp1 = sub-solution A, temp2 = sub-solution B, temp3 = main solution.
        -- shared.cpp is in all three; among subs B (later) wins, then main wins overall.
        local tmp1 = os.tmpname() .. ".json"
        local tmp2 = os.tmpname() .. ".json"
        local tmp3 = os.tmpname() .. ".json"
        local out = os.tmpname() .. ".json"

        local function w(path, cmd)
            local f = io.open(path, "w")
            f:write(vim.json.encode({
                { file = "C:\\shared.cpp", command = cmd, directory = "C:\\" },
            }))
            f:close()
        end
        w(tmp1, "subA")
        w(tmp2, "subB")
        w(tmp3, "main")

        local ok = CC._internal.merge_temp_files({ tmp1, tmp2, tmp3 }, out, true)
        assert.is_true(ok)

        local decoded = vim.json.decode(io.open(out, "r"):read("*a"))
        assert.are.equal(1, #decoded)
        assert.are.equal("main", decoded[1].command)

        os.remove(out)
    end)

    it("merge_temp_files keep-last: among two subs the later-scanned entry wins", function()
        local tmp1 = os.tmpname() .. ".json"
        local tmp2 = os.tmpname() .. ".json"
        local out = os.tmpname() .. ".json"

        local function w(path, cmd)
            local f = io.open(path, "w")
            f:write(vim.json.encode({
                { file = "C:\\shared.cpp", command = cmd, directory = "C:\\" },
            }))
            f:close()
        end
        w(tmp1, "subA")
        w(tmp2, "subB")

        local ok = CC._internal.merge_temp_files({ tmp1, tmp2 }, out, true)
        assert.is_true(ok)

        local decoded = vim.json.decode(io.open(out, "r"):read("*a"))
        assert.are.equal(1, #decoded)
        assert.are.equal("subB", decoded[1].command)

        os.remove(out)
    end)

    it("merge_temp_files combines entries and deduplicates by file", function()
        local tmp1 = os.tmpname() .. ".json"
        local tmp2 = os.tmpname() .. ".json"
        local out = os.tmpname() .. ".json"

        local f1 = io.open(tmp1, "w")
        f1:write(vim.json.encode({
            { file = "C:\\a.cpp", command = "cl /c a.cpp", directory = "C:\\" },
            { file = "C:\\b.cpp", command = "cl /c b.cpp", directory = "C:\\" },
        }))
        f1:close()

        local f2 = io.open(tmp2, "w")
        f2:write(vim.json.encode({
            { file = "C:\\b.cpp", command = "cl /c b.cpp", directory = "C:\\" },
            { file = "C:\\c.cpp", command = "cl /c c.cpp", directory = "C:\\" },
        }))
        f2:close()

        local ok = CC._internal.merge_temp_files({ tmp1, tmp2 }, out, true)
        assert.is_true(ok)

        local content = io.open(out, "r"):read("*a")
        local decoded = vim.json.decode(content)
        assert.are.equal(3, #decoded)

        os.remove(out)
        -- tmp1 and tmp2 are cleaned up by merge_temp_files
    end)
end)
