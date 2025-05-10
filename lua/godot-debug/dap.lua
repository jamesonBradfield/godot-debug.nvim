-- File: lua/godot-debug/dap.lua - Enhanced with better error handling
local M = {}

local config = require("godot-debug.config")
local notify = require("godot-debug.notifications")

function M.setup()
	local dap = require("dap")

	-- Enhanced netcoredbg adapter with better error handling
	dap.adapters.godot_mono = function(callback, adapter_config)
		notify.debug("Setting up DAP adapter", { adapter_config = adapter_config })

		if adapter_config.request == "attach" then
			-- Check if netcoredbg is available
			local netcoredbg_path = vim.fn.exepath("netcoredbg")
			if not netcoredbg_path or netcoredbg_path == "" then
				notify.error("netcoredbg not found in PATH. Please install it with: brew install netcoredbg")
				callback(nil, "netcoredbg not found")
				return
			end

			notify.debug("Found netcoredbg", { path = netcoredbg_path })

			callback({
				type = "executable",
				command = netcoredbg_path,
				args = { "--interpreter=vscode" },
				-- Add environment variables to help with debugging
				env = {
					["NET_TRACE"] = "1", -- Enable .NET Core tracing
					["GODOT_MONO_LOG_LEVEL"] = "debug",
				},
			})
		else
			notify.error("Invalid DAP adapter request type", { request = adapter_config.request })
			callback(nil, "Invalid request type")
		end
	end

	-- Enhanced DAP configuration with better parameters
	dap.configurations.cs = {
		{
			type = "godot_mono",
			request = "attach",
			name = "Attach to Godot Mono",
			processId = function()
				local main = require("godot-debug")

				-- Use stored PID if available
				if main._godot_pid and main._godot_pid > 0 then
					notify.info("Using stored Godot PID: " .. main._godot_pid)
					return main._godot_pid
				end

				-- Fallback to process picker with better error handling
				notify.info("No stored PID, using process picker")
				local selected_pid = require("dap.utils").pick_process()

				if selected_pid then
					notify.info("Selected PID from picker: " .. selected_pid)
				else
					notify.warn("No process selected from picker")
				end

				return selected_pid
			end,
			justMyCode = false,
			-- Additional configuration to handle the errors you're seeing
			symbolSearchPath = "${workspaceFolder}",
			program = function()
				-- Try to find the Godot executable
				local godot_path = config.get("godot_binary")
				local full_path = vim.fn.exepath(godot_path)

				if full_path and full_path ~= "" then
					notify.debug("Found Godot executable", { path = full_path })
					return full_path
				else
					notify.warn("Could not find Godot executable", { binary = godot_path })
				end

				return nil
			end,
			-- Add extra parameters to help with symbol resolution
			justMyCodeStepping = false,
			enableStepIntoProp = true,
			enableStepFiltering = false,
			stopAtEntry = false,
			logToOutputPane = true,
			-- This might help with the source mapping issues
			sourceFileMap = {
				["<default>"] = "${workspaceFolder}",
			},
		},
	}

	-- Also register for gdscript
	dap.configurations.gdscript = dap.configurations.cs

	-- Enhanced auto-detection with logging
	if config.get("auto_detect") then
		local original_continue = dap.continue

		dap.continue = function()
			notify.debug("DAP continue called")

			local is_godot = M.is_godot_project()
			local main = require("godot-debug")

			if is_godot and not main._state.in_progress and not dap.session() then
				notify.info("Detected Godot project, launching Godot debugger")
				main.launch()
			else
				notify.debug("Continuing with standard DAP", {
					is_godot = is_godot,
					in_progress = main._state.in_progress,
					has_session = dap.session() ~= nil,
				})
				original_continue()
			end
		end
	end

	-- Enhanced event listeners with detailed logging
	dap.listeners.before.attach.godot_debug = function(session, body)
		notify.debug("DAP before attach", { body = body })
	end

	dap.listeners.after.attach.godot_debug = function(session, body)
		notify.info("DAP attached successfully", { body = body })
	end

	dap.listeners.before.attach.godot_debug = function(session, body)
		notify.debug("DAP before event_initialized", { body = body })
	end

	dap.listeners.after.event_initialized.godot_debug = function(session, body)
		notify.info("DAP session initialized", { body = body })
	end

	dap.listeners.after.event_terminated.godot_debug = function(session, body)
		notify.warn("DAP session terminated", { body = body })
		local main = require("godot-debug")
		main._state.in_progress = false
	end

	dap.listeners.after.event_exited.godot_debug = function(session, body)
		notify.warn("DAP session exited", { exit_code = body and body.exitCode })
		local main = require("godot-debug")
		main._state.in_progress = false
	end

	-- Listen for configuration done to catch the error you're seeing
	dap.listeners.after.configurationDone.godot_debug = function(session, err)
		if err then
			notify.error("DAP configuration failed", {
				error = err,
				cmd = err.command,
				message = err.message,
				body = err.body,
			})

			-- Try to provide specific solutions based on the error
			if err.message and err.message:find("0x80070057") then
				notify.error("Invalid parameter error (0x80070057). This often happens when:")
				notify.info("1. Godot's executable is out of date or doesn't match the debug symbols")
				notify.info("2. The process ID is invalid or the process has exited")
				notify.info("3. There's a mismatch between the Godot engine and its compilation")
				notify.info("Try rebuilding your project and ensuring Godot is up to date")
			end
		else
			notify.info("DAP configuration completed successfully")
		end
	end

	-- Listen for stackTrace responses to catch frame position errors
	dap.listeners.after.stackTrace.godot_debug = function(session, err, body)
		if err then
			notify.error("Stack trace error", { error = err })
		end

		if body and body.stackFrames then
			for _, frame in ipairs(body.stackFrames) do
				-- Check if frame has invalid line/column
				if frame.line and frame.column then
					notify.verbose("Stack frame", {
						file = frame.source and frame.source.path,
						line = frame.line,
						column = frame.column,
					})
				end
			end
		end
	end

	-- Generic error listener
	dap.listeners.after.error.godot_debug = function(session, err)
		notify.error("DAP error", { error = err })
	end

	notify.info("DAP configuration complete with enhanced error handling")
end

-- Simple project detection with logging
function M.is_godot_project()
	local current_file = vim.fn.expand("%:p")
	if current_file == "" then
		notify.debug("No current file, not a Godot project")
		return false
	end

	local current_dir = vim.fn.fnamemodify(current_file, ":h")

	while true do
		if vim.fn.filereadable(current_dir .. "/project.godot") == 1 then
			notify.debug("Found Godot project", { project_dir = current_dir })
			return true
		end

		local new_dir = vim.fn.fnamemodify(current_dir, ":h")
		if new_dir == current_dir then
			break
		end
		current_dir = new_dir
	end

	notify.debug("Not a Godot project")
	return false
end

-- Helper function to rebuild and restart debugging when there are symbol issues
function M.rebuild_and_restart()
	notify.info("Rebuilding and restarting debug session...")

	-- First, stop current session
	local dap = require("dap")
	if dap.session() then
		dap.disconnect()
		vim.wait(1000)
	end

	-- Force rebuild
	local godot = require("godot-debug.godot")
	local build_success = godot.build_solutions()

	if build_success then
		-- Wait a bit for build to settle
		vim.wait(2000)

		-- Kill any existing Godot processes
		godot.kill_processes()
		vim.wait(1000)

		-- Restart the debug session
		local main = require("godot-debug")
		main.launch()
	else
		notify.error("Rebuild failed, cannot restart debugging")
	end
end

return M
