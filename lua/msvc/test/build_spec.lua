local helpers = require("msvc.test.utils")

describe("msvc.build", function()
    local Build

    before_each(function()
        helpers.reset()
        Build = require("msvc.build")
    end)

    it("composes argv with configuration, platform, jobs, target", function()
        local argv = Build._build_argv({
            msbuild = "C:\\MSBuild.exe",
            target_path = "C:\\foo.sln",
            configuration = "Release",
            platform = "Win32",
            jobs = 6,
            target = "Build",
        })
        assert.are.equal("C:\\MSBuild.exe", argv[1])
        assert.are.equal("C:\\foo.sln", argv[2])
        assert.are.equal("/nr:false", argv[3])
        assert.are.equal("/p:Configuration=Release", argv[4])
        assert.are.equal("/p:Platform=Win32", argv[5])
        -- jobs=6 is a total budget; split_budget(6) → {nodes=3, mpcount=2}.
        assert.are.equal("/m:3", argv[6])
        assert.are.equal("/p:CL_MPCount:2", argv[7])
        assert.are.equal("/t:Build", argv[8])
    end)

    it("omits /m, CL_MPCount, /t when jobs and target are nil", function()
        local argv = Build._build_argv({
            msbuild = "M",
            target_path = "T",
            configuration = "Debug",
            platform = "x64",
        })
        local s = table.concat(argv, " ")
        assert.is_falsy(s:find("/m:"))
        assert.is_falsy(s:find("CL_MPCount"))
        assert.is_falsy(s:find("/t:"))
        assert.is_truthy(s:find("/nr:false"))
    end)

    it("appends /p:SolutionDir when solution_dir is provided", function()
        local argv = Build._build_argv({
            msbuild = "M",
            target_path = "P.vcxproj",
            configuration = "Debug",
            platform = "x64",
            solution_dir = "C:\\Projects\\Sol",
        })
        local s = table.concat(argv, " ")
        assert.is_truthy(s:find("SolutionDir"))
        assert.is_truthy(s:find("C:\\Projects\\Sol"))
    end)

    it("appends /p:SelectedFiles when selected_files is provided", function()
        local argv = Build._build_argv({
            msbuild = "M",
            target_path = "P.vcxproj",
            configuration = "Debug",
            platform = "x64",
            selected_files = "C:\\src\\main.cpp",
        })
        local s = table.concat(argv, " ")
        assert.is_truthy(s:find("SelectedFiles"))
        assert.is_truthy(s:find("main%.cpp"))
    end)

    it("omits SolutionDir and SelectedFiles when not provided", function()
        local argv = Build._build_argv({
            msbuild = "M",
            target_path = "T",
            configuration = "Debug",
            platform = "x64",
        })
        local s = table.concat(argv, " ")
        assert.is_falsy(s:find("SolutionDir"))
        assert.is_falsy(s:find("SelectedFiles"))
    end)

    -- ─── runtime guards ──────────────────────────────────────────────────────

    it("is_running returns false when no build is active", function()
        assert.is_false(Build.is_running())
    end)

    it("cancel returns false when no build is active", function()
        local result = Build.cancel()
        assert.is_false(result)
    end)

    it("spawn returns false when msbuild path is nil", function()
        local result = Build.spawn({
            msbuild = nil,
            target_path = "T.sln",
            configuration = "Debug",
            platform = "x64",
        })
        assert.is_false(result)
    end)

    it("spawn returns false when msbuild path does not exist on disk", function()
        local result = Build.spawn({
            msbuild = "/nonexistent/MSBuild.exe",
            target_path = "T.sln",
            configuration = "Debug",
            platform = "x64",
        })
        assert.is_false(result)
    end)

    it("spawn returns false when target path does not exist on disk", function()
        local Util = require("msvc.util")
        local tmpdir = vim.fn.tempname()
        vim.fn.mkdir(tmpdir, "p")
        local fake_msbuild = Util.join_path(tmpdir, "MSBuild.exe")
        local fh = io.open(fake_msbuild, "wb")
        fh:write("fake")
        fh:close()
        local result = Build.spawn({
            msbuild = fake_msbuild,
            target_path = "/nonexistent/target.sln",
            configuration = "Debug",
            platform = "x64",
        })
        vim.fn.delete(tmpdir, "rf")
        assert.is_false(result)
    end)
end)
