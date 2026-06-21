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
