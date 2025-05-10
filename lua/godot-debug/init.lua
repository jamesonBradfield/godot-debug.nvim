-- File: lua/godot-debug/init.lua
local M = {}

-- Load modules
local config = require("godot-debug.config")
local logger = require("godot-debug.logger")
local notifications = require("godot-debug.notifications")
local godot = require("godot-debug.godot")
local dap_config = require("godot-debug.dap")

-- State tracking
local state = {
	in_progress = false,
}

-- Export state for other modules to access
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
	-- Prevent multiple simultaneous launches
	if state.in_progress then
		logger.warn("Debug session already in progress, ignoring launch request")
		notifications.warn("Debug session already in progress")
		return
	end

	logger.info("Starting debug session...")
	state.in_progress = true

	-- Step 1: Select scene with callback (asynchronous)
	godot.select_scene(function(scene_path)
		logger.info("Scene selection callback received: " .. tostring(scene_path))

		if not scene_path then
			logger.error("No scene selected, aborting")
			state.in_progress = false
			return
		end

		-- Step 2: Build solutions
		local build_success = godot.build_solutions()
		if not build_success then
			logger.error("Build failed, aborting")
			state.in_progress = false
			return
		end

		-- Step 3: Launch Godot
		local pid = godot.launch_scene(scene_path)
		if not pid then
			logger.error("Failed to launch Godot, aborting")
			state.in_progress = false
			return
		end

		-- Step 4: Connect debugger
		local debug_success = godot.connect_debugger(pid)
		state.in_progress = false -- Reset state after debugger connects

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

return M
