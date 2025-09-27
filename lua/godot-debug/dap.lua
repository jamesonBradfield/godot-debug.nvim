-- File: lua/godot-debug/dap.lua
local M = {}

local config = require("godot-debug.config")
local notify = require("godot-debug.notifications")

-- Helper to find Godot process more reliably
local function find_godot_process()
	local godot_binary = config.get("godot_binary")

	-- Try to find Godot process by name
	local cmd = string.format('pgrep -f "%s"', godot_binary)
	if vim.fn.has("win32") == 1 then
		-- Windows: Use wmic to find process
		cmd = string.format("wmic process where \"name like '%%%s%%'\" get ProcessId /format:value", godot_binary)
	end

	local handle = io.popen(cmd)
	if not handle then
		return nil
	end

	local output = handle:read("*a")
	handle:close()

	-- Parse PID from output
	local pid = nil
	if vim.fn.has("win32") == 1 then
		-- Windows output format: ProcessId=12345
		pid = output:match("ProcessId=(%d+)")
	else
		-- Unix: pgrep returns PID directly
		pid = output:match("(%d+)")
	end

	return pid and tonumber(pid) or nil
end

function M.setup()
	local dap = require("dap")

	-- Enhanced netcoredbg adapter
	dap.adapters.godot_mono = function(callback, adapter_config)
		notify.debug("Setting up DAP adapter", { adapter_config = adapter_config })

		if adapter_config.request ~= "attach" then
			notify.error("Only 'attach' request type is supported")
			callback(nil, "Invalid request type")
			return
		end

		local netcoredbg_path = vim.fn.exepath("netcoredbg")
		if not netcoredbg_path or netcoredbg_path == "" then
			notify.error("netcoredbg not found in PATH. Please install it.")
			callback(nil, "netcoredbg not found")
			return
		end

		notify.debug("Found netcoredbg", { path = netcoredbg_path })

		callback({
			type = "executable",
			command = netcoredbg_path,
			args = { "--interpreter=vscode" },
			env = {
				["GODOT_MONO_LOG_LEVEL"] = "debug",
				["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1",
			},
		})
	end
	notify.info("Changing dap config to PID")
	-- Enhanced DAP configuration
	dap.configurations.cs = {
		{
			type = "godot_mono",
			request = "attach",
			name = "Attach to Godot Mono",
			processId = function()
				local main = require("godot-debug")

				-- First try stored PID
				if main._godot_pid and main._godot_pid > 0 then
					notify.info("Using stored Godot PID: " .. main._godot_pid)
					return main._godot_pid
				end

				-- Try to find running Godot process
				notify.info("Looking for running Godot process...")
				local found_pid = find_godot_process()

				if found_pid then
					notify.info("Found Godot process with PID: " .. found_pid)
					main._godot_pid = found_pid
					return found_pid
				end

				-- Fallback to manual selection
				notify.info("No Godot process found automatically, using process picker")
				local selected_pid = require("dap.utils").pick_process()

				if selected_pid then
					notify.info("Selected PID from picker: " .. selected_pid)
					main._godot_pid = selected_pid
				else
					notify.error("No process selected")
				end

				return selected_pid
			end,
			-- Critical: These settings help with symbol resolution
			justMyCode = false,
			justMyCodeStepping = false,
			enableStepIntoProp = true,
			enableStepFiltering = false,
			stopAtEntry = false,
			symbolOptions = {
				searchMicrosoftSymbolServer = false,
				searchNuGetOrgSymbolServer = false,
			},
			-- Help locate source files
			sourceFileMap = {
				["<default>"] = "${workspaceFolder}",
			},
			-- Additional paths for symbol resolution
			additionalSOLibSearchPath = vim.fn.getcwd() .. "\\.godot\\mono\\temp\\bin\\Debug",
		},
	}

	-- Also register for gdscript
	dap.configurations.gdscript = dap.configurations.cs

	-- Event listeners for debugging
	dap.listeners.before.attach.godot_debug = function(session, body)
		notify.debug("DAP before attach", { session = session, body = body })
	end

	dap.listeners.after.attach.godot_debug = function(session, body)
		notify.info("DAP attached successfully", { session = session, body = body })
	end

	dap.listeners.after.event_initialized.godot_debug = function(session, body)
		notify.info("DAP session initialized", { session = session, body = body })
	end

	dap.listeners.after.event_terminated.godot_debug = function(session, body)
		notify.warn("DAP session terminated", { session = session, body = body })
		local main = require("godot-debug")
		main._state.in_progress = false
		main._godot_pid = nil
	end

	dap.listeners.after.event_exited.godot_debug = function(session, body)
		notify.warn("DAP session exited", { session = session, exit_code = body and body.exitCode })
		local main = require("godot-debug")
		main._state.in_progress = false
		main._godot_pid = nil
	end

	-- Error handling for configuration issues
	dap.listeners.after.configurationDone.godot_debug = function(session, err)
		if err then
			notify.error("DAP configuration failed", {
				session = session,
				error = err,
				message = err.message,
			})

			if err.message and err.message:find("0x80070057") then
				notify.error("Invalid parameter error detected")
				notify.info("Possible fixes:")
				notify.info("1. Run :GodotDebugRebuild to rebuild the project")
				notify.info("2. Ensure Godot is running with --debug flag")
				notify.info("3. Check that \\.godot\\mono\\temp\\bin\\Debug contains debug symbols")
			end
		else
			notify.info("DAP configuration completed successfully")
		end
	end
	--NOTE: error field not there
	--
	-- dap.listeners.after.error.godot_debug = function(session, err)
	-- 	notify.error("DAP error occurred", { error = err })
	-- end

	notify.info("DAP configuration complete")
end

function M.is_godot_project()
	local current_file = vim.fn.expand("%:p")
	if current_file == "" then
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

	return false
end

return M
