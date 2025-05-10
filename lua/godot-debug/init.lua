-- File: lua/godot-debug/init.lua - Minimal version
local M = {}

local state = {
	in_progress = false,
}

M._state = state

-- Minimal setup
function M.setup(user_config)
	local config = require("godot-debug.config")
	local dap_config = require("godot-debug.dap")

	config.setup(user_config)
	dap_config.setup()

	-- Store PID for DAP
	M._godot_pid = nil

	-- Create user commands
	vim.api.nvim_create_user_command("GodotDebug", function()
		M.launch()
	end, {})

	vim.api.nvim_create_user_command("GodotQuit", function()
		local godot = require("godot-debug.godot")
		godot.kill_processes()
	end, {})
end

-- Minimal launch function (exactly like the original)
function M.launch()
	if state.in_progress then
		print("Debug session already in progress")
		return
	end

	state.in_progress = true

	local godot = require("godot-debug.godot")

	-- Step 1: Select scene
	godot.select_scene(function(scene_path)
		if not scene_path then
			state.in_progress = false
			print("No scene selected")
			return
		end

		-- Step 2: Build solutions
		local build_success = godot.build_solutions()
		if not build_success then
			state.in_progress = false
			print("Build failed")
			return
		end

		-- Step 3: Launch Godot
		local pid = godot.launch_scene(scene_path)
		if not pid or pid <= 0 then
			state.in_progress = false
			print("Failed to launch")
			return
		end

		-- Step 4: Connect debugger
		M._godot_pid = pid
		local dap = require("dap")

		-- Wait a moment for Godot to start
		vim.defer_fn(function()
			dap.continue()
			state.in_progress = false
		end, 1000)
	end)
end

function M.set_log_level(level)
	-- Empty for now
end

return M
