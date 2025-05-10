-- File: lua/godot-debug/dap.lua - Simplified version
local M = {}

local config = require("godot-debug.config")
local logger = require("godot-debug.logger")

function M.setup()
	local dap = require("dap")

	-- Simple netcoredbg adapter (minimal configuration)
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

	-- Configure C# debugging (minimal configuration)
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

	-- Simple auto-detection (like the original)
	if config.get("auto_detect") then
		local original_continue = dap.continue

		dap.continue = function()
			local is_godot = M.is_godot_project()
			local main = require("godot-debug")

			-- Simple check like the original
			if is_godot and not main._state.in_progress and not dap.session() then
				logger.info("Detected Godot project, launching Godot debugger")
				main.launch()
			else
				logger.info("Using original continue function")
				original_continue()
			end
		end
	end

	-- Minimal event listeners (no breakpoint handling)
	dap.listeners.before.event_terminated["godot_debug"] = function()
		logger.info("DAP session terminated")
		local main = require("godot-debug")
		main.reset_state()
	end

	dap.listeners.before.event_exited["godot_debug"] = function()
		logger.info("DAP session exited")
		local main = require("godot-debug")
		main.reset_state()
	end

	logger.info("DAP configuration complete")
end

-- Simple project detection
function M.is_godot_project()
	local current_file = vim.fn.expand("%:p")
	if current_file == "" then
		return false
	end

	local current_dir = vim.fn.fnamemodify(current_file, ":h")

	while true do
		if vim.fn.filereadable(current_dir .. "/project.godot") == 1 then
			return true
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
