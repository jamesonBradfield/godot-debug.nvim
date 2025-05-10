-- File: lua/godot-debug/dap.lua - Async version without blocking prints
local M = {}

local config = require("godot-debug.config")
local logger = require("godot-debug.logger")

-- Async logging function
local function async_log(message)
	vim.schedule(function()
		logger.info(message)
	end)
end

function M.setup()
	local dap = require("dap")

	-- Simple netcoredbg adapter without blocking
	dap.adapters.godot_mono = function(callback, adapter_config)
		if adapter_config.request == "attach" then
			callback({
				type = "executable",
				command = "netcoredbg",
				args = { "--interpreter=vscode" },
			})
		else
			callback(nil, "Invalid request type")
		end
	end

	-- Minimal DAP configuration
	dap.configurations.cs = {
		{
			type = "godot_mono",
			request = "attach",
			name = "Attach to Godot Mono",
			processId = function()
				local main = require("godot-debug")

				-- Use stored PID if available
				if main._godot_pid and main._godot_pid > 0 then
					async_log("Using stored Godot PID: " .. main._godot_pid)
					return main._godot_pid
				end

				-- Fallback to process picker
				async_log("No stored PID, using process picker")
				return require("dap.utils").pick_process()
			end,
			justMyCode = false,
		},
	}

	-- Also register for gdscript
	dap.configurations.gdscript = dap.configurations.cs

	-- Minimal auto-detection
	if config.get("auto_detect") then
		local original_continue = dap.continue

		dap.continue = function()
			local is_godot = M.is_godot_project()
			local main = require("godot-debug")

			if is_godot and not main._state.in_progress and not dap.session() then
				async_log("Detected Godot project, launching Godot debugger")
				main.launch()
			else
				original_continue()
			end
		end
	end

	-- Essential event listeners only
	dap.listeners.after.event_terminated["godot_debug"] = function()
		async_log("DAP session terminated")
		local main = require("godot-debug")
		main._state.in_progress = false
	end

	dap.listeners.after.event_exited["godot_debug"] = function()
		async_log("DAP session exited")
		local main = require("godot-debug")
		main._state.in_progress = false
	end

	async_log("DAP configuration complete")
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
