-- Manual verification helper for the dynamic configuration/platform
-- completion. Not auto-run; invoke from a powershell session like:
--
--   nvim --headless -u tests/minimal_init.lua \
--     -c "lua dofile('scripts/verify_completion.lua')(arg[1])" \
--     -c "qa" -- "C:\path\to\repo"
--
-- It cd's into <root>, runs setup with a single profile, waits for the
-- async warms, and prints the discovered configurations / platforms /
-- vs_version / vs_requires sizes. Compare against the expectations
-- recorded in plan §11.

local function pp(label, list)
    local out = {}
    for _, v in ipairs(list or {}) do
        out[#out + 1] = tostring(v)
    end
    print(string.format("%s [%d]: %s", label, #out, table.concat(out, ", ")))
end

return function(root)
    if not root or root == "" then
        io.stderr:write("usage: verify_completion.lua <root>\n")
        os.exit(2)
    end
    vim.fn.execute("lcd " .. vim.fn.fnameescape(root), "silent!")

    local msvc = require("msvc")
    msvc:setup({
        settings = { default_profile = "verify" },
        profiles = { verify = {} },
    })

    -- Wait up to 10s for both the project scan (vim.schedule) and the
    -- async vswhere warm to complete. `vim.wait` keeps the loop pumping.
    local deadline = vim.uv.now() + 10000
    while vim.uv.now() < deadline do
        local pt = msvc.project_targets or {}
        local cc = msvc.vs_completion_candidates or {}
        local has_project = (#(pt.configurations or {}) > 0)
            or (#(pt.platforms or {}) > 0)
        local has_vs = (#(cc.vs_version or {}) > 1) -- "latest" alone doesn't count
        if has_project and has_vs then
            break
        end
        vim.wait(200)
    end

    print("== verify_completion ==")
    print("root: " .. root)
    print("solution: " .. tostring(msvc.state.solution or "<none>"))
    local pt = msvc.project_targets or {}
    pp("configurations", pt.configurations)
    pp("platforms", pt.platforms)
    local cc = msvc.vs_completion_candidates or {}
    pp("vs_version", cc.vs_version)
    print(
        string.format(
            "vs_products: %d   vs_requires: %d",
            #(cc.vs_products or {}),
            #(cc.vs_requires or {})
        )
    )
end
