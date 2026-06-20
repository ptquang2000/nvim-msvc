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

    it("build_argv serializes solution + flags, no --project, no --merge", function()
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
        assert.is_falsy(f("--merge"))
        assert.is_truthy(f("-c|Release"))
        assert.is_truthy(f("-a|Win32"))
        assert.is_truthy(f("--vs-path|C:\\VS\\2022"))
        assert.is_truthy(f("-o|C:\\out\\compile_commands.json"))
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
