local helpers = require("msvc.test.utils")

describe("msvc.build", function()
    local Build

    before_each(function()
        helpers.reset()
        Build = require("msvc.build")
    end)

    it("composes argv with engine-injected flags before user args", function()
        local argv = Build._build_argv({
            msbuild = "C:\\MSBuild.exe",
            target_path = "C:\\foo.sln",
            configuration = "Release",
            platform = "Win32",
            jobs = 6,
            target = "Build",
            msbuild_args = { "/nologo", "/v:minimal" },
        })
        assert.are.equal("C:\\MSBuild.exe", argv[1])
        assert.are.equal("C:\\foo.sln", argv[2])
        assert.are.equal("/nr:false", argv[3])
        assert.are.equal("/p:Configuration=Release", argv[4])
        assert.are.equal("/p:Platform=Win32", argv[5])
        assert.are.equal("/m:6", argv[6])
        assert.are.equal("/t:Build", argv[7])
        assert.are.equal("/nologo", argv[8])
        assert.are.equal("/v:minimal", argv[9])
    end)

    it("omits /m when jobs is nil and /t when target is nil", function()
        local argv = Build._build_argv({
            msbuild = "M",
            target_path = "T",
            configuration = "Debug",
            platform = "x64",
        })
        local s = table.concat(argv, " ")
        assert.is_falsy(s:find("/m:"))
        assert.is_falsy(s:find("/t:"))
        assert.is_truthy(s:find("/nr:false"))
    end)
end)
