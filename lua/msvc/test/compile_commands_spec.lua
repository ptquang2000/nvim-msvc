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

    it("build_argv serializes solution + projects + flags", function()
        local argv = CC._internal.build_argv({
            extractor = "extractor.exe",
            solution = "C:\\foo.sln",
            projects = { "C:\\a.vcxproj", "C:\\b.vcxproj" },
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
        assert.is_truthy(f("--project|C:\\a.vcxproj"))
        assert.is_truthy(f("--project|C:\\b.vcxproj"))
        assert.is_truthy(f("-c|Release"))
        assert.is_truthy(f("-a|Win32"))
        assert.is_truthy(f("--vs-path|C:\\VS\\2022"))
        assert.is_truthy(f("-o|C:\\out\\compile_commands.json"))
        assert.is_truthy(f("--merge"))
        assert.is_truthy(f("--deduplicate"))
    end)

    it("resolve_anchor falls back to project / cwd", function()
        local Util = require("msvc.util")
        local cwd = vim.fn.getcwd()
        assert.are.equal(
            Util.normalize_path(cwd),
            CC._internal.resolve_anchor(nil, nil)
        )
    end)
end)
