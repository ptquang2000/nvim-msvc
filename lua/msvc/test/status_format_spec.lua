local TestUtils = require("msvc.test.utils")

-- BUG 3: :Msvc status displays a friendly version line + separate path
-- line when the install metadata is populated. Falls back to a synthetic
-- "Visual Studio <plv> (<v>)" composer when displayName is missing, then
-- to a single path-only line, then to "<none>".
describe("msvc.status install line formatting", function()
    before_each(function()
        TestUtils.reset()
    end)

    local function capture_status()
        local msvc = require("msvc")
        local notify = TestUtils.capture_notify()
        msvc:status()
        notify.restore()
        local lines = {}
        for _, c in ipairs(notify.calls) do
            lines[#lines + 1] = c.msg or ""
        end
        return lines
    end

    local function find_line(lines, prefix)
        for _, l in ipairs(lines) do
            if l:sub(1, #prefix) == prefix then
                return l
            end
        end
        return nil
    end

    it("friendly path: install + path lines from full metadata", function()
        local msvc = require("msvc")
        msvc.state:set(
            "install_path",
            "C:\\Program Files\\Microsoft Visual Studio\\2022\\Professional"
        )
        msvc.state:set(
            "install_display_name",
            "Visual Studio Professional 2022"
        )
        msvc.state:set("install_version", "17.14.37216.2")
        msvc.state:set("install_product_line_version", "2022")

        local lines = capture_status()
        assert.equals(
            "install  = Visual Studio Professional 2022 (17.14.37216.2)",
            find_line(lines, "install  =")
        )
        assert.equals(
            "path     = C:\\Program Files\\Microsoft Visual Studio\\2022\\Professional",
            find_line(lines, "path     =")
        )
    end)

    it("synthesised composer when displayName missing", function()
        local msvc = require("msvc")
        msvc.state:set("install_path", "C:\\VS\\2022")
        msvc.state:set("install_version", "17.14.37216.2")
        msvc.state:set("install_product_line_version", "2022")

        local lines = capture_status()
        assert.equals(
            "install  = Visual Studio 2022 (17.14.37216.2)",
            find_line(lines, "install  =")
        )
        assert.equals("path     = C:\\VS\\2022", find_line(lines, "path     ="))
    end)

    it(
        "synthesised composer with 'unknown' when version missing too",
        function()
            local msvc = require("msvc")
            msvc.state:set("install_path", "C:\\VS\\2022")
            msvc.state:set("install_product_line_version", "2022")

            local lines = capture_status()
            assert.equals(
                "install  = Visual Studio 2022 (unknown)",
                find_line(lines, "install  =")
            )
        end
    )

    it("path-only fallback when no friendlies", function()
        local msvc = require("msvc")
        msvc.state:set("install_path", "C:\\VS\\Legacy")

        local lines = capture_status()
        assert.equals(
            "install  = C:\\VS\\Legacy",
            find_line(lines, "install  =")
        )
        -- No `path     =` line in the path-only branch.
        assert.is_nil(find_line(lines, "path     ="))
    end)

    it("'<none>' when install_path is empty", function()
        local msvc = require("msvc")
        -- All four are nil by default.
        local lines = capture_status()
        assert.equals("install  = <none>", find_line(lines, "install  ="))
        assert.is_nil(find_line(lines, "path     ="))
    end)
end)
