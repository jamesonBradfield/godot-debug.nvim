-- File: lua/godot-debug/dap.lua
local M = {}

local config = require("godot-debug.config")
local logger = require("godot-debug.logger")

function M.setup()
	local dap = require("dap")

	-- Set up netcoredbg adapter
	dap.adapters.godot_mono = function(callback, adapter_config)
		if adapter_config.request == "attach" then
			callback({
				type = "executable",
				command = "netcoredbg",
				args = { "--interpreter=vscode" },
			})
		else
			callback(nil, "Godot Mono adapter only supports attach mode")
		end
	end

	-- Configure C# debugging
	dap.configurations.cs = {
		{
			type = "godot_mono",
			request = "attach",
			name = "Attach to Godot Mono",
			processId = function()
				local godot = require("godot-debug.godot")

				-- Use stored PID if available
				if godot._godot_pid and godot._godot_pid > 0 then
					logger.info("Using stored Godot PID: " .. godot._godot_pid)
					return godot._godot_pid
				end

				-- Fallback to process picker
				logger.warn("No stored PID, using process picker")
				return require("dap.utils").pick_process()
			end,
			justMyCode = false,
		},
	}

	-- Also register for gdscript
	dap.configurations.gdscript = dap.configurations.cs

	-- Auto-detection hook
	if config.get("auto_detect") then
		local original_continue = dap.continue

		dap.continue = function()
			-- Check if we're in a Godot project
			local is_godot, project_dir = M.is_godot_project()

			-- Get the main module to check state
			local main = require("godot-debug")

			if is_godot and not dap.session() and not main._state.in_progress then
				logger.info("Detected Godot project, launching Godot debugger")
				main.launch()
			else
				if main._state.in_progress then
					logger.info("Debug launch already in progress, using original continue")
				else
					logger.info("Not a Godot project or debug session active, using original continue")
				end
				original_continue()
			end
		end
	end

	-- Add DAP event listeners for session management
	dap.listeners.after.event_initialized["godot_debug"] = function()
		logger.info("DAP session initialized")

		-- Start monitoring Godot process
		start_godot_process_monitor()
	end

	dap.listeners.before.event_terminated["godot_debug"] = function()
		logger.info("DAP session terminated")

		-- Clean up when session terminates
		cleanup_godot_debug_session()
	end

	dap.listeners.before.event_exited["godot_debug"] = function()
		logger.info("DAP session exited")

		-- Clean up when session exits
		cleanup_godot_debug_session()
	end

	logger.info("DAP configuration complete")
end

-- Monitor Godot process and clean up if it exits
function start_godot_process_monitor()
	local godot = require("godot-debug.godot")
	local dap = require("dap")

	if not godot._godot_pid or godot._godot_pid <= 0 then
		return
	end

	logger.info("Starting Godot process monitor for PID: " .. godot._godot_pid)

	-- Create a timer to periodically check if Godot is still running
	local timer = vim.loop.new_timer()
	if not timer then
		logger.error("Failed to create timer for process monitoring")
		return
	end

	-- Store timer for cleanup
	godot._process_monitor_timer = timer

	-- Check every second
	timer:start(
		1000,
		1000,
		vim.schedule_wrap(function()
			if godot._godot_pid and godot._godot_pid > 0 then
				-- Check if process is still running
				local is_running = false

				if vim.fn.has("win32") == 1 then
					-- Windows
					local cmd =
						string.format('tasklist /FI "PID eq %d" | find "%d"', godot._godot_pid, godot._godot_pid)
					local output = vim.fn.system(cmd)
					is_running = output:find(tostring(godot._godot_pid)) ~= nil
				else
					-- Unix-like systems
					local cmd = string.format("kill -0 %d 2>/dev/null", godot._godot_pid)
					is_running = vim.fn.system(cmd) == ""
				end

				if not is_running then
					logger.info("Godot process terminated, cleaning up debug session")

					-- Stop the timer
					timer:stop()
					timer:close()
					godot._process_monitor_timer = nil

					-- Terminate DAP session
					if dap.session() then
						logger.info("Terminating DAP session")
						dap.terminate()
					end

					-- Reset Godot PID
					godot._godot_pid = nil

					-- Reset launch state
					local main = require("godot-debug")
					main._state.in_progress = false
				end
			else
				-- No PID to monitor, stop timer
				timer:stop()
				timer:close()
				godot._process_monitor_timer = nil
			end
		end)
	)
end

-- Clean up resources when debug session ends
function cleanup_godot_debug_session()
	local godot = require("godot-debug.godot")
	local main = require("godot-debug")

	-- Stop process monitor if it exists
	if godot._process_monitor_timer then
		godot._process_monitor_timer:stop()
		godot._process_monitor_timer:close()
		godot._process_monitor_timer = nil
	end

	-- Reset PID
	godot._godot_pid = nil

	-- Reset launch state
	main._state.in_progress = false

	logger.info("Debug session cleaned up")
end

-- Check if current directory is a Godot project
function M.is_godot_project()
	local current_file = vim.fn.expand("%:p")
	if current_file == "" then
		return false
	end

	local current_dir = vim.fn.fnamemodify(current_file, ":h")

	while true do
		if vim.fn.filereadable(current_dir .. "/project.godot") == 1 then
			return true, current_dir
		end

		local new_dir = vim.fn.fnamemodify(current_dir, ":h")
		if new_dir == current_dir then
			break
		end
		current_dir = new_dir
	end

	return false
end

return M
