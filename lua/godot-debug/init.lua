-- File: lua/godot-debug/init.lua - With enhanced notifications
local M = {}

local notify = require("godot-debug.notifications")

local state = {
	in_progress = false,
}

M._state = state

-- Setup function
function M.setup(user_config)
	local config = require("godot-debug.config")
	local dap_config = require("godot-debug.dap")

	config.setup(user_config)
	dap_config.setup()

	-- Store PID for DAP
	M._godot_pid = nil

	-- Create user commands
	vim.api.nvim_create_user_command("GodotDebug", function()
		notify.info("GodotDebug command triggered")
		M.launch()
	end, {})

	vim.api.nvim_create_user_command("GodotQuit", function()
		notify.info("GodotQuit command triggered")
		local godot = require("godot-debug.godot")
		godot.kill_processes()
	end, {})

	-- Add commands for log management
	vim.api.nvim_create_user_command("GodotDebugLog", function()
		notify.view_log()
	end, { desc = "View Godot debug log in split" })

	vim.api.nvim_create_user_command("GodotDebugClearLog", function()
		notify.clear_log()
	end, { desc = "Clear Godot debug log" })

	vim.api.nvim_create_user_command("GodotDebugTail", function()
		notify.tail_log()
	end, { desc = "Tail Godot debug log (auto-refresh)" })

	-- Add command to rebuild and restart debugging when symbol issues occur
	vim.api.nvim_create_user_command("GodotDebugRebuild", function()
		notify.info("Rebuilding and restarting debug session...")
		dap_config.rebuild_and_restart()
	end, { desc = "Rebuild and restart Godot debug session" })

	notify.info("Godot Debug plugin initialized")
end

-- Launch function with detailed logging
function M.launch()
	notify.verbose("=== Starting Godot debug launch ===")

	if state.in_progress then
		notify.warn("Debug session already in progress")
		return
	end

	state.in_progress = true

	-- Start the main operation
	local launch_operation = notify.start_operation("GODOT_LAUNCH", "Launching Godot debug session")

	local godot = require("godot-debug.godot")

	-- Step 1: Select scene
	notify.debug("Step 1: Starting scene selection")
	godot.select_scene(function(scene_path)
		if not scene_path then
			state.in_progress = false
			notify.complete_operation(launch_operation, false, "No scene selected")
			notify.error("No scene selected")
			return
		end

		notify.debug("Scene selected", { scene_path = scene_path })

		-- Step 2: Build solutions
		notify.debug("Step 2: Building solutions")
		local build_operation = notify.start_operation("BUILD_SOLUTIONS", "Building Godot solutions")

		local build_success = godot.build_solutions()

		notify.complete_operation(
			build_operation,
			build_success,
			build_success and "Build successful" or "Build failed"
		)

		if not build_success then
			state.in_progress = false
			notify.complete_operation(launch_operation, false, "Build failed")
			notify.error("Build failed - check build output")
			return
		end

		-- Step 3: Launch Godot
		notify.debug("Step 3: Launching Godot process")
		local launch_process_operation = notify.start_operation("LAUNCH_GODOT", "Launching Godot with scene")

		local pid = godot.launch_scene(scene_path)

		if not pid or pid <= 0 then
			state.in_progress = false
			notify.complete_operation(launch_process_operation, false, "Failed to launch Godot")
			notify.complete_operation(launch_operation, false, "Failed to launch Godot process")
			notify.error("Failed to launch Godot")
			return
		end

		notify.complete_operation(launch_process_operation, true, "Godot launched with PID: " .. pid)
		notify.debug("Godot launched", { pid = pid })

		-- Step 4: Connect debugger
		notify.debug("Step 4: Connecting debugger")
		M._godot_pid = pid
		local dap = require("dap")

		-- Wait a moment for Godot to start
		vim.defer_fn(function()
			local connect_operation = notify.start_operation("CONNECT_DEBUGGER", "Connecting DAP debugger")

			-- Use pcall to catch any DAP errors
			local success, err = pcall(function()
				dap.continue()
			end)

			if success then
				notify.complete_operation(connect_operation, true, "Debugger connected successfully")
				notify.complete_operation(launch_operation, true, "Godot debug session launched successfully")
				notify.info("Godot debug session started successfully")
			else
				notify.complete_operation(connect_operation, false, "Error: " .. tostring(err))
				notify.complete_operation(launch_operation, false, "Debugger connection failed")
				notify.error("Failed to connect debugger: " .. tostring(err))
			end

			state.in_progress = false
			notify.verbose("=== Godot debug launch complete ===")
		end, 1000)
	end)
end

-- Set log level function
function M.set_log_level(level)
	notify.debug("Setting log level", { level = level })
	notify.info("Log level set to: " .. tostring(level))
end

-- Get debug status
function M.get_debug_status()
	local status = {
		in_progress = state.in_progress,
		godot_pid = M._godot_pid,
		has_dap_session = require("dap").session() ~= nil,
	}

	notify.debug("Debug status requested", status)

	return status
end

-- Cleanup function
function M.cleanup()
	notify.info("Cleaning up Godot debug session")

	-- Clear notifications
	notify.clear_all()

	-- Reset state
	state.in_progress = false
	M._godot_pid = nil

	notify.info("Cleanup complete")
end

return M
