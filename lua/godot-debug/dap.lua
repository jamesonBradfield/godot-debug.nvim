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

				-- Check if we're in a Godot project and should launch instead
				local is_godot = M.is_godot_project()
				if is_godot then
					logger.info(
						"Godot project detected but no PID, using process picker (might need to launch Godot first)"
					)
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

			-- Get the main module
			local main = require("godot-debug")

			-- Check if the module is properly initialized with _state
			if not main._state then
				logger.warn("Main module state not initialized, using original continue")
				original_continue()
				return
			end

			if is_godot and not dap.session() and not main._state.in_progress then
				logger.info("Detected Godot project, launching Godot debugger")
				main.launch()
			else
				if main._state.in_progress then
					logger.info("Debug launch already in progress, using stored PID")
				elseif dap.session() then
					logger.info("DAP session active, continuing normally")
				else
					logger.info("Not a Godot project, using original continue")
				end
				original_continue()
			end
		end
	end

	-- Add DAP event listeners for session management
	dap.listeners.after.event_initialized["godot_debug"] = function(session)
		logger.info("DAP session initialized")

		-- Start monitoring Godot process after a short delay to ensure everything is set up
		vim.defer_fn(function()
			start_godot_process_monitor()
		end, 1000)
	end

	dap.listeners.before.event_terminated["godot_debug"] = function()
		logger.info("DAP session terminated")
		cleanup_godot_debug_session()
	end

	dap.listeners.before.event_exited["godot_debug"] = function()
		logger.info("DAP session exited")
		cleanup_godot_debug_session()
	end

	-- Also listen for disconnect
	dap.listeners.after.disconnect["godot_debug"] = function()
		logger.info("DAP session disconnected")
		cleanup_godot_debug_session()
	end

	logger.info("DAP configuration complete")
end

-- Monitor Godot process and clean up if it exits
function start_godot_process_monitor()
	local godot = require("godot-debug.godot")
	local dap = require("dap")

	if not godot._godot_pid or godot._godot_pid <= 0 then
		logger.warn("No Godot PID to monitor")
		return
	end

	logger.info("Starting Godot process monitor for PID: " .. godot._godot_pid)

	-- Stop existing timer if any
	if godot._process_monitor_timer then
		godot._process_monitor_timer:stop()
		godot._process_monitor_timer:close()
	end

	-- Create a timer to periodically check if Godot is still running
	local timer = vim.loop.new_timer()
	if not timer then
		logger.error("Failed to create timer for process monitoring")
		return
	end

	-- Store timer for cleanup
	godot._process_monitor_timer = timer

	-- Track consecutive failed checks
	local failed_checks = 0

	-- Check every 300ms for more responsive detection
	timer:start(
		300,
		300,
		vim.schedule_wrap(function()
			if not godot._godot_pid or godot._godot_pid <= 0 then
				logger.debug("No PID to monitor, stopping timer")
				timer:stop()
				timer:close()
				godot._process_monitor_timer = nil
				return
			end

			-- Use the dedicated process check function
			local is_running = godot.is_process_running(godot._godot_pid)

			if not is_running then
				failed_checks = failed_checks + 1
				logger.debug("Process check failed (attempt " .. failed_checks .. ")")

				-- Confirm process is really gone after 2 failed checks
				if failed_checks >= 2 then
					logger.info("Godot process definitely terminated, forcing debug session close")

					-- Stop the timer
					timer:stop()
					timer:close()
					godot._process_monitor_timer = nil

					-- Force close the DAP session
					terminate_dap_session()

					-- Reset Godot PID
					godot._godot_pid = nil

					-- Reset launch state
					local main = require("godot-debug")
					main._state.in_progress = false
				end
			else
				-- Reset failed checks if process is running
				failed_checks = 0
			end
		end)
	)

	logger.info("Process monitor started successfully")
end

-- Force terminate DAP session with multiple approaches
function terminate_dap_session()
	local dap = require("dap")

	-- Method 1: Try terminate
	local session = dap.session()
	if session then
		logger.info("Attempting to terminate DAP session...")
		dap.terminate()

		-- Method 2: Force disconnect after short delay
		vim.defer_fn(function()
			if dap.session() then
				logger.info("Session still active, forcing disconnect...")
				dap.disconnect()

				-- Method 3: Close DAP UI windows after another delay
				vim.defer_fn(function()
					if dap.session() then
						logger.warn("Session still exists, force closing DAP UI")

						-- Close DAP UI windows
						local dapui = require("dapui")
						if dapui then
							dapui.close()
						end

						-- Close any remaining DAP-related windows
						for _, win in ipairs(vim.api.nvim_list_wins()) do
							local buf = vim.api.nvim_win_get_buf(win)
							local buf_name = vim.api.nvim_buf_get_name(buf)

							-- Check if this is a DAP window
							if buf_name:match("dap%-") or buf_name:match("debugpy") then
								pcall(vim.api.nvim_win_close, win, true)
							end
						end

						-- Final attempt to clear session
						if dap.session() then
							logger.error("Forcing DAP session reset")
							dap.session().close()
						end
					else
						logger.info("DAP session successfully closed")
					end
				end, 1000)
			else
				logger.info("DAP session closed successfully")
			end
		end, 500)
	else
		logger.info("No DAP session to terminate")
	end
end

-- Clean up resources when debug session ends
function cleanup_godot_debug_session()
	local godot = require("godot-debug.godot")
	local main = require("godot-debug")

	-- Stop process monitor if it exists
	if godot._process_monitor_timer then
		logger.info("Stopping process monitor")
		godot._process_monitor_timer:stop()
		godot._process_monitor_timer:close()
		godot._process_monitor_timer = nil
	end

	-- Force terminate the DAP session to ensure UI is closed
	terminate_dap_session()

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
