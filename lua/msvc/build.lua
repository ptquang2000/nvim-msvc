-- msvc.build — orchestrate `MSBuild.exe` invocations. Streams output
-- through the extension bus and produces a quickfix list at exit.

local Util = require("msvc.util")
local Log = require("msvc.log")
local DevEnv = require("msvc.devenv")
local QuickFix = require("msvc.quickfix")
local Ext = require("msvc.extensions")

local M = {}

---@class MsvcBuildJob
---@field pid integer|nil
---@field handle table|nil          vim.system handle
---@field lines string[]            captured output for quickfix parsing
---@field cancelled boolean

local current_job = nil

function M.is_running()
    return current_job ~= nil
end

local function emit_output(line)
    Ext.extensions:emit(Ext.event_names.BUILD_OUTPUT, line)
end

--- Construct argv for MSBuild given a build context.
---@param ctx { msbuild: string, target_path: string, configuration: string,
---             platform: string, jobs: integer|nil, msbuild_args: string[]|nil,
---             target: string|nil }
---@return string[]
local function build_argv(ctx)
    local argv = { ctx.msbuild, ctx.target_path }
    -- /nr:false stops orphan MSBuild worker processes after cancellation.
    argv[#argv + 1] = "/nr:false"
    argv[#argv + 1] = "/p:Configuration=" .. ctx.configuration
    argv[#argv + 1] = "/p:Platform=" .. ctx.platform
    if ctx.jobs and ctx.jobs > 0 then
        argv[#argv + 1] = "/m:" .. tostring(ctx.jobs)
    end
    if ctx.target and ctx.target ~= "" then
        argv[#argv + 1] = "/t:" .. ctx.target
    end
    for _, a in ipairs(ctx.msbuild_args or {}) do
        argv[#argv + 1] = a
    end
    return argv
end
M._build_argv = build_argv

--- Cancel an in-flight build. Uses `taskkill /T /F /PID <pid>` to terminate
--- the MSBuild process tree (msbuild spawns child workers).
function M.cancel()
    local job = current_job
    if not job then
        Log:warn("build: nothing to cancel")
        return false
    end
    job.cancelled = true
    if job.pid then
        vim.system({ "taskkill", "/T", "/F", "/PID", tostring(job.pid) }):wait()
    end
    Ext.extensions:emit(Ext.event_names.BUILD_CANCEL)
    return true
end

--- Spawn MSBuild for a given target.
---@param opts { msbuild: string, target_path: string, configuration: string,
---              platform: string, jobs: integer|nil, msbuild_args: string[]|nil,
---              target: string|nil, env: table|nil, on_done: fun(ok, code) }
function M.spawn(opts)
    if current_job then
        Log:warn("build: another build is in progress; cancel first")
        return false
    end
    if not opts.msbuild or not Util.is_file(opts.msbuild) then
        Log:error("build: MSBuild.exe not found")
        return false
    end
    if not opts.target_path or not Util.is_file(opts.target_path) then
        Log:error(
            "build: target file does not exist: %s",
            tostring(opts.target_path)
        )
        return false
    end

    local argv = build_argv(opts)
    Log:debug("build: argv = %s", vim.inspect(argv))

    local started_at = vim.uv.hrtime()
    local job = { lines = {}, cancelled = false }
    current_job = job

    local function on_stdout(_, data)
        if not data then
            return
        end
        for line in data:gmatch("[^\r\n]+") do
            job.lines[#job.lines + 1] = line
            vim.schedule(function()
                emit_output(line)
            end)
        end
    end

    Ext.extensions:emit(Ext.event_names.BUILD_START, {
        target_path = opts.target_path,
        configuration = opts.configuration,
        platform = opts.platform,
        target = opts.target,
    })

    local sys_opts = {
        text = true,
        stdout = on_stdout,
        stderr = on_stdout,
    }
    if type(opts.env) == "table" and next(opts.env) ~= nil then
        sys_opts.env = opts.env
    end

    local ok, handle_or_err = pcall(vim.system, argv, sys_opts, function(res)
        vim.schedule(function()
            current_job = nil
            local elapsed_ms = math.floor((vim.uv.hrtime() - started_at) / 1e6)
            local code = res and res.code or -1
            local success = (not job.cancelled) and code == 0
            local _ = QuickFix.from_build_output(job.lines, {
                title = ("MSBuild [%s|%s]"):format(
                    opts.configuration,
                    opts.platform
                ),
                open = true,
            })
            -- if n > 0 then
            --     Log:info("build: %d quickfix entries", n)
            -- end
            Ext.extensions:emit(
                Ext.event_names.BUILD_DONE,
                success,
                elapsed_ms,
                code
            )
            if type(opts.on_done) == "function" then
                pcall(opts.on_done, success, code)
            end
        end)
    end)
    if not ok then
        current_job = nil
        Log:error("build: failed to spawn MSBuild: %s", tostring(handle_or_err))
        return false
    end
    job.handle = handle_or_err
    job.pid = handle_or_err and handle_or_err.pid or nil
    return true
end

-- expose for tests
M._current_job = function()
    return current_job
end

return M
