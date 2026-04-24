local Util = require("msvc.util")
local Log = require("msvc.log")
local Ext = require("msvc.extensions")
local DevEnv = require("msvc.devenv")
local QuickFix = require("msvc.quickfix")

---@class MsvcBuildContext
---@field project string
---@field configuration string
---@field platform string
---@field target string|nil
---@field verbosity string
---@field max_cpu_count integer
---@field no_logo boolean
---@field extra_args string[]
---@field env table
---@field msbuild_path string
---@field cwd string|nil

---@class MsvcBuildCallbacks
---@field on_done fun(self: MsvcBuild, ok: boolean, elapsed_ms: number)|nil

---@class MsvcBuild
---@field ctx MsvcBuildContext
---@field opts table
---@field job_id integer|nil
---@field pid integer|nil
---@field running boolean
---@field start_time number|nil
---@field stdout_buffer string[]
---@field stderr_buffer string[]
---@field cancelled boolean
---@field _callbacks MsvcBuildCallbacks
local MsvcBuild = {}
MsvcBuild.__index = MsvcBuild

local VALID_VERBOSITY = {
    quiet = true,
    minimal = true,
    normal = true,
    detailed = true,
    diagnostic = true,
}

---Construct a new build invocation.
---@param ctx MsvcBuildContext
---@param opts table|nil
---@return MsvcBuild
function MsvcBuild:new(ctx, opts)
    if type(ctx) ~= "table" then
        error("MsvcBuild:new requires a context table")
    end
    if type(ctx.project) ~= "string" or ctx.project == "" then
        error("MsvcBuild:new ctx.project is required")
    end
    if type(ctx.msbuild_path) ~= "string" or ctx.msbuild_path == "" then
        error("MsvcBuild:new ctx.msbuild_path is required")
    end
    if ctx.env ~= nil and type(ctx.env) ~= "table" then
        error("MsvcBuild:new ctx.env must be a table or nil")
    end
    if type(ctx.configuration) ~= "string" or ctx.configuration == "" then
        error("MsvcBuild:new ctx.configuration is required")
    end
    if type(ctx.platform) ~= "string" or ctx.platform == "" then
        error("MsvcBuild:new ctx.platform is required")
    end
    if
        type(ctx.verbosity) ~= "string"
        or not VALID_VERBOSITY[ctx.verbosity]
    then
        error(
            "MsvcBuild:new ctx.verbosity invalid: " .. tostring(ctx.verbosity)
        )
    end
    if type(ctx.max_cpu_count) ~= "number" then
        error("MsvcBuild:new ctx.max_cpu_count must be a number")
    end
    if type(ctx.no_logo) ~= "boolean" then
        error("MsvcBuild:new ctx.no_logo must be a boolean")
    end
    if ctx.extra_args ~= nil and type(ctx.extra_args) ~= "table" then
        error("MsvcBuild:new ctx.extra_args must be a table")
    end
    if ctx.target ~= nil and type(ctx.target) ~= "string" then
        error("MsvcBuild:new ctx.target must be a string or nil")
    end

    local self_ = setmetatable({
        ctx = ctx,
        opts = opts or {},
        job_id = nil,
        pid = nil,
        running = false,
        start_time = nil,
        stdout_buffer = {},
        stderr_buffer = {},
        cancelled = false,
        _callbacks = {},
    }, MsvcBuild)
    if ctx.extra_args == nil then
        ctx.extra_args = {}
    end
    return self_
end

---Compose the MSBuild argv.
---@return string[]
function MsvcBuild:_argv()
    local ctx = self.ctx
    local argv = { ctx.msbuild_path, ctx.project }
    if ctx.no_logo then
        argv[#argv + 1] = "/nologo"
    end
    argv[#argv + 1] = "/v:" .. ctx.verbosity
    if ctx.max_cpu_count and ctx.max_cpu_count > 0 then
        argv[#argv + 1] = "/m:" .. tostring(ctx.max_cpu_count)
    else
        argv[#argv + 1] = "/m"
    end
    argv[#argv + 1] = "/p:Configuration=" .. ctx.configuration
    argv[#argv + 1] = "/p:Platform=" .. ctx.platform
    if ctx.target ~= nil and ctx.target ~= "" then
        argv[#argv + 1] = "/t:" .. ctx.target
    end
    for _, a in ipairs(ctx.extra_args or {}) do
        argv[#argv + 1] = a
    end
    return argv
end

---Append non-empty lines from a jobstart data chunk into a buffer.
---@param buffer string[]
---@param data string[]
---@param stream "stdout"|"stderr"
function MsvcBuild:_consume(buffer, data, stream)
    if type(data) ~= "table" then
        return
    end
    for _, line in ipairs(data) do
        if type(line) == "string" and line ~= "" then
            local clean = line:gsub("\r$", "")
            if clean ~= "" then
                buffer[#buffer + 1] = clean
                Log:append_build_output(clean)
                Ext.extensions:emit(
                    Ext.event_names.BUILD_OUTPUT,
                    self,
                    clean,
                    stream
                )
            end
        end
    end
end

---Begin the MSBuild job. Emits BUILD_START before spawning.
---@param callbacks MsvcBuildCallbacks|nil
---@return MsvcBuild
function MsvcBuild:start(callbacks)
    if self.running then
        error("MsvcBuild:start called while already running")
    end
    self._callbacks = callbacks or {}
    self.stdout_buffer = {}
    self.stderr_buffer = {}
    self.cancelled = false

    local argv = self:_argv()

    Ext.extensions:emit(Ext.event_names.BUILD_START, self)

    self.start_time = os.clock()
    self.running = true

    local job_id = vim.fn.jobstart(argv, {
        env = self.ctx.env,
        cwd = self.ctx.cwd,
        stdout_buffered = false,
        stderr_buffered = false,
        on_stdout = function(_, data, _)
            self:_consume(self.stdout_buffer, data, "stdout")
        end,
        on_stderr = function(_, data, _)
            self:_consume(self.stderr_buffer, data, "stderr")
        end,
        on_exit = function(_, code, _)
            self:_finish(code)
        end,
    })

    if not job_id or job_id <= 0 then
        self.running = false
        error(
            "MsvcBuild:start failed to spawn jobstart (id="
                .. tostring(job_id)
                .. ")"
        )
    end

    self.job_id = job_id
    local ok_pid, pid = pcall(vim.fn.jobpid, job_id)
    if ok_pid then
        self.pid = pid
    end
    return self
end

---Internal completion handler invoked from on_exit.
---@param code integer
function MsvcBuild:_finish(code)
    if not self.running and self.start_time == nil then
        return
    end
    self.running = false
    local elapsed_ms = 0
    if self.start_time then
        elapsed_ms = (os.clock() - self.start_time) * 1000
    end
    local ok = (code == 0) and not self.cancelled

    local combined = {}
    for _, l in ipairs(self.stdout_buffer) do
        combined[#combined + 1] = l
    end
    for _, l in ipairs(self.stderr_buffer) do
        combined[#combined + 1] = l
    end
    local pub_ok, count = pcall(
        QuickFix.from_build_output,
        combined,
        { open = false, title = "MSBuild" }
    )
    if pub_ok and type(count) == "number" and count > 0 then
        pcall(
            QuickFix.from_build_output,
            combined,
            { open = true, title = "MSBuild" }
        )
    end

    Ext.extensions:emit(Ext.event_names.BUILD_DONE, self, ok, elapsed_ms)

    local cb = self._callbacks and self._callbacks.on_done
    if type(cb) == "function" then
        pcall(cb, self, ok, elapsed_ms)
    end
end

---Cancel a running build by killing the MSBuild process tree.
function MsvcBuild:cancel()
    if not self.running then
        return
    end
    self.cancelled = true

    if self.pid and Util.is_windows() then
        pcall(vim.fn.system, {
            "taskkill",
            "/T",
            "/F",
            "/PID",
            tostring(self.pid),
        })
    end
    if self.job_id then
        pcall(vim.fn.jobstop, self.job_id)
    end

    Ext.extensions:emit(Ext.event_names.BUILD_CANCEL, self)
end

---@return boolean
function MsvcBuild:is_running()
    return self.running == true
end

-- Touch unused requires so static analyzers don't complain; these are
-- part of the documented dependency surface for this module.
local _ = DevEnv

return { MsvcBuild = MsvcBuild }
