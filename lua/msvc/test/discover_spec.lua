local TestUtils = require("msvc.test.utils")

local uv = vim.uv or vim.loop

local function mktempdir()
    local base = vim.fn.tempname()
    vim.fn.mkdir(base, "p")
    return base
end

local function touch(path)
    local fd = assert(uv.fs_open(path, "w", 420))
    uv.fs_close(fd)
end

local function rmrf(dir)
    vim.fn.delete(dir, "rf")
end

describe("msvc.discover.find_vcxprojs", function()
    before_each(function()
        TestUtils.reset()
    end)

    it("filters CMake meta-targets case-insensitively", function()
        local Discover = require("msvc.discover")
        local Util = require("msvc.util")
        local dir = mktempdir()
        local kept = Util.join_path(dir, "mylib.vcxproj")
        local also_kept = Util.join_path(dir, "libwaacd.vcxproj")
        local meta = {
            "ALL_BUILD.vcxproj",
            "ZERO_CHECK.vcxproj",
            "install.vcxproj", -- lowercase
            "RUN_TESTS.vcxproj",
            "Package.vcxproj", -- mixed case
            "RESTORE.vcxproj",
            "Continuous.vcxproj",
            "Experimental.vcxproj",
            "Nightly.vcxproj",
            "NIGHTLYMEMORYCHECK.vcxproj",
        }
        touch(kept)
        touch(also_kept)
        for _, m in ipairs(meta) do
            touch(Util.join_path(dir, m))
        end

        local found = Discover.find_vcxprojs(dir)
        local norm_kept = Util.normalize_path(kept)
        local norm_also = Util.normalize_path(also_kept)
        table.sort(found)
        local expected = { norm_also, norm_kept }
        table.sort(expected)
        assert.same(expected, found)

        rmrf(dir)
    end)

    it(
        "respects filter_meta_targets=false to return everything",
        function()
            local Discover = require("msvc.discover")
            local Util = require("msvc.util")
            local dir = mktempdir()
            touch(Util.join_path(dir, "mylib.vcxproj"))
            touch(Util.join_path(dir, "ALL_BUILD.vcxproj"))

            local found = Discover.find_vcxprojs(
                dir,
                { filter_meta_targets = false }
            )
            assert.are.equal(2, #found)

            rmrf(dir)
        end
    )

    it("exposes CMAKE_META_TARGETS as a public constant", function()
        local Discover = require("msvc.discover")
        assert.is_table(Discover.CMAKE_META_TARGETS)
        local names = {}
        for _, n in ipairs(Discover.CMAKE_META_TARGETS) do
            names[n] = true
        end
        for _, expected in ipairs({
            "ALL_BUILD",
            "ZERO_CHECK",
            "INSTALL",
            "PACKAGE",
            "RUN_TESTS",
            "RESTORE",
            "Continuous",
            "Experimental",
            "Nightly",
            "NightlyMemoryCheck",
        }) do
            assert.is_true(
                names[expected] == true,
                "missing meta target: " .. expected
            )
        end
    end)
end)
