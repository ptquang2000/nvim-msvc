-- Headless smoke test for vs_version completion + status formatting.
-- Driven by a stubbed VsWhere; never spawns vswhere.exe.
local function p(...)
    io.stdout:write(table.concat({ ... }, "\t"), "\n")
end

local TwoInstalls = {
    {
        displayName = "Visual Studio Professional 2017",
        installationVersion = "15.9.37202.19",
        catalog = { productLineVersion = "2017" },
        installationPath = "C:\\VS\\2017\\Pro",
        productId = "Microsoft.VisualStudio.Product.Professional",
        isPrerelease = false,
    },
    {
        displayName = "Visual Studio Professional 2022",
        installationVersion = "17.14.37216.2",
        catalog = { productLineVersion = "2022" },
        installationPath = "C:\\VS\\2022\\Pro",
        productId = "Microsoft.VisualStudio.Product.Professional",
        isPrerelease = false,
    },
}

local VsWhere = require("msvc.vswhere")
VsWhere.list_installations_async = function(opts, cb)
    -- Unfiltered call: no vs_version → return both. Filtered: pick one.
    local v = opts and opts.vs_version
    if v == nil or v == "latest" or v == "any" or v == "" then
        cb(TwoInstalls, nil)
        return
    end
    if v == "2017" or v == "[15.0,16.0)" or v == "15" or v == "15.9.37202.19" then
        cb({ TwoInstalls[1] }, nil)
        return
    end
    if v == "2022" or v == "[17.0,18.0)" or v == "17" or v == "17.14.37216.2" then
        cb({ TwoInstalls[2] }, nil)
        return
    end
    cb({}, nil)
end
VsWhere.find_latest = function(opts)
    local v = opts and opts.vs_version
    if v == "2017" or v == "[15.0,16.0)" or v == "15" or v == "15.9.37202.19" then
        return TwoInstalls[1]
    end
    if v == "2022" or v == "[17.0,18.0)" or v == "17" or v == "17.14.37216.2" then
        return TwoInstalls[2]
    end
    if v == nil or v == "latest" or v == "any" or v == "" then
        return TwoInstalls[2] -- pick_latest equivalent: highest major
    end
    return nil
end
VsWhere.list_installations = function(opts)
    return TwoInstalls
end

-- Setup with a real config so commands.update can write profile_overrides.
local msvc = require("msvc")
msvc:setup({
    settings = { default_profile = "base", log_level = vim.log.levels.INFO },
    profiles = { base = { vs_version = "latest", configuration = "Debug", platform = "x64" } },
})
-- Drive the unfiltered warm directly (setup's warm is on a scheduler).
msvc:_warm_vs_installations()

p("=== STEP A: vs_completion_candidates.vs_version ===")
for _, v in ipairs(msvc.vs_completion_candidates.vs_version) do
    p("  " .. v)
end

p("=== STEP B: simulate :Msvc update vs_version 2017 ===")
local Commands = require("msvc.commands")
Commands.test.subcommands.update.impl({ "vs_version", "2017" })
p("install_path         = " .. tostring(msvc.state.install_path))
p("install_display_name = " .. tostring(msvc.state.install_display_name))
p("install_version      = " .. tostring(msvc.state.install_version))
p("install_product_line = " .. tostring(msvc.state.install_product_line_version))
p("-- candidates after update (should be unchanged) --")
for _, v in ipairs(msvc.vs_completion_candidates.vs_version) do
    p("  " .. v)
end

p("=== STEP C: simulate :Msvc status ===")
local original_notify = vim.notify
local lines = {}
vim.notify = function(msg) lines[#lines + 1] = msg end
msvc:status()
vim.notify = original_notify
for _, l in ipairs(lines) do
    p("  " .. l)
end

p("=== STEP D: simulate :Msvc update vs_version 9999 (no match) ===")
local notify_lines = {}
vim.notify = function(msg) notify_lines[#notify_lines + 1] = msg end
Commands.test.subcommands.update.impl({ "vs_version", "9999" })
vim.notify = original_notify
p("install_path         = " .. tostring(msvc.state.install_path))
p("install_display_name = " .. tostring(msvc.state.install_display_name))
p("install_version      = " .. tostring(msvc.state.install_version))
p("install_product_line = " .. tostring(msvc.state.install_product_line_version))
local warned = false
for _, l in ipairs(notify_lines) do
    if l:find("no Visual Studio installation matches", 1, true) then
        warned = true
        p("warn: " .. l)
    end
end
p("warned: " .. tostring(warned))

p("=== STEP E: simulate :Msvc update vs_version 15.9.37202.19 (full VS 2017) ===")
Commands.test.subcommands.update.impl({ "vs_version", "15.9.37202.19" })
p("install_path         = " .. tostring(msvc.state.install_path))
p("install_display_name = " .. tostring(msvc.state.install_display_name))
p("install_version      = " .. tostring(msvc.state.install_version))
p("install_product_line = " .. tostring(msvc.state.install_product_line_version))
p("translated -version  = " .. tostring(VsWhere.translate_version("15.9.37202.19")))

p("=== STEP F: simulate :Msvc update vs_version 17.14.37216.2 (full VS 2022) ===")
Commands.test.subcommands.update.impl({ "vs_version", "17.14.37216.2" })
p("install_path         = " .. tostring(msvc.state.install_path))
p("install_display_name = " .. tostring(msvc.state.install_display_name))
p("install_version      = " .. tostring(msvc.state.install_version))
p("install_product_line = " .. tostring(msvc.state.install_product_line_version))
p("translated -version  = " .. tostring(VsWhere.translate_version("17.14.37216.2")))

vim.cmd("qa!")
