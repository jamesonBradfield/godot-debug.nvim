-- File: lua/godot-debug/init.lua - Simplified version
local M = {}

-- Load modules
local config = require("godot-debug.config")
local logger = require("godot-debug.logger")
local notifications = require("godot-debug.notifications")
local godot = require("godot-debug.godot")
local dap_config = require("godot-debug.dap")

-- Simple state tracking (like the original)
local state = {
	in_progress = false,
}

-- Export state for other modules
M._state = state

-- Public API
function M.setup(user_config)
	-- Initialize configuration
	config.setup(user_config)

	-- Initialize logger
	logger.setup()

	-- Setup DAP configurations
	dap_config.setup()

	-- Create user commands
	vim.api.nvim_create_user_command("GodotDebug", function()
		M.launch()
	end, {})

	vim.api.nvim_create_user_command("GodotQuit", function()
		godot.kill_processes()
	end, {})

	logger.info("Godot debug plugin initialized")
end

function M.launch()
	-- Simple state check (like the original)
	if state.in_progress then
		notifications.warn("Debug session already in progress")
		return
	end

	logger.info("Starting debug session...")
	state.in_progress = true

	-- Step 1: Select scene
	godot.select_scene(function(scene_path)
		if not scene_path then
			state.in_progress = false
			logger.error("No scene selected, aborting")
			return
		end

		-- Step 2: Build solutions
		local build_success = godot.build_solutions()
		if not build_success then
			state.in_progress = false
			logger.error("Build failed, aborting")
			return
		end

		-- Step 3: Launch Godot
		local pid = godot.launch_scene(scene_path)
		if not pid then
			state.in_progress = false
			logger.error("Failed to launch Godot, aborting")
			return
		end

		-- Step 4: Connect debugger
		local debug_success = godot.connect_debugger(pid)

		-- Reset state after connecting (like the original)
		state.in_progress = false

		if not debug_success then
			logger.error("Failed to connect debugger")
			return
		end

		logger.info("Debug session started successfully")
	end)
end

function M.set_log_level(level)
	logger.set_level(level)
end

-- Simple state reset
function M.reset_state()
	state.in_progress = false
	logger.info("Debug session state reset")
end

return M
