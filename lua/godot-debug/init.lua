local M = {}
-- Using PID to connect to debugger directly

-- Configuration with sensible defaults
local config = {
	godot_binary = vim.fn.has("win32") == 1 and "godot-mono.exe" or "godot-mono",
	exclude_dirs = { "addons/", "src/" },
	scene_cache_file = vim.fn.stdpath("cache") .. "/godot_last_scene.txt",
	debug_mode = false,
	log_level = vim.log.levels.INFO, -- Default log level (kept for compatibility)
	auto_detect = true, -- Automatically detect Godot projects when launching DAP
	ignore_build_errors = { -- Errors that should not prevent launching the scene
		"GdUnit.*Can't establish server.*Already in use",
		"Resource file not found: res://<.*Texture.*>",
	},
	buffer_reuse = true, -- Reuse existing Godot build output buffer if it exists
	build_timeout = 60, -- Timeout for build process (in seconds)
	show_build_output = true, -- Always show build output buffer
}

-- State tracking
local state = {
	in_progress = false,
	notification_ids = {},
	current_buffers = {},
}

-- Directly require Snacks since it's a dependency
local Snacks = require("snacks")

-- Public interface to set log level (kept for API compatibility)
function M.set_log_level(level)
	if type(level) == "number" and level >= 0 and level <= 4 then
		config.log_level = level
		Snacks.notify.info("Godot: Log level set to " .. level)
		return true
	else
		Snacks.notify.error("Godot: Invalid log level. Must be vim.log.levels value (0-4)")
		return false
	end
end

-- Create or reuse a buffer
local function create_or_reuse_buffer(name, lines, filetype)
	filetype = filetype or "log"

	-- Check if buffer already exists
	local buf_id = nil
	if config.buffer_reuse then
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			local buf_name = vim.api.nvim_buf_get_name(buf)
			if buf_name:match(name .. "$") then
				buf_id = buf
				break
			end
		end
	end

	-- Create a new buffer if needed
	if not buf_id then
		buf_id = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(buf_id, name)
		state.current_buffers[name] = buf_id
	end

	-- Set buffer content and options
	vim.api.nvim_buf_set_option(buf_id, "modifiable", true)
	vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, lines or {})
	vim.api.nvim_buf_set_option(buf_id, "modifiable", false)
	vim.api.nvim_buf_set_option(buf_id, "filetype", filetype)

	return buf_id
end

-- Notification management with Snacks.notifier
local function show_notification(message, id)
	-- Define spinner animation
	local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

	-- Show notification with spinner
	state.notification_ids[id] = Snacks.notifier(message, "info", {
		id = id,
		title = "Godot Debugger",
		opts = function(notif)
			notif.icon = spinner[math.floor(vim.loop.hrtime() / (1e6 * 80)) % #spinner + 1]
		end,
		timeout = false, -- Keep until manually closed
	})

	return state.notification_ids[id]
end

local function hide_notification(id)
	if state.notification_ids[id] then
		Snacks.notifier.hide(state.notification_ids[id])
		state.notification_ids[id] = nil
	end
end

local function update_notification(id, message, success)
	if state.notification_ids[id] then
		local level = success and "info" or "error"
		local icon = success and "✓" or "✗"

		-- Update notification with success/failure status
		Snacks.notifier(message, level, {
			id = state.notification_ids[id],
			title = "Godot Debugger",
			icon = icon,
			timeout = 3000, -- Auto-dismiss after 3 seconds
		})

		state.notification_ids[id] = nil
	end
end

-- Execute command with improved debugging
local function execute_command(cmd, opts, callback)
	opts = opts or {}
	local cmd_str = type(cmd) == "table" and table.concat(cmd, " ") or cmd
	Snacks.notify.info("[Godot:CMD] Starting command: " .. cmd_str)

	-- Create a unique execution ID for tracking this command's lifecycle
	local exec_id = tostring(math.random(1000000))

	-- Wrap callback with error handling and logging
	local safe_callback = nil
	if callback then
		safe_callback = vim.schedule_wrap(function(result, success, err)
			-- Log command results
			if success then
				Snacks.notify.info("[Godot:SUCCESS] Command succeeded [" .. exec_id .. "]")
			else
				Snacks.notify.error("[Godot:ERROR] Command failed [" .. exec_id .. "]: " .. (err or "Unknown error"))
			end

			-- Call the original callback inside pcall to catch any errors
			local cb_status, cb_err = pcall(function()
				callback(result, success, err)
			end)

			if not cb_status then
				Snacks.notify.error("[Godot:CB_ERROR] Error in callback [" .. exec_id .. "]: " .. tostring(cb_err))
			end
		end)
	end
	-- Use vim.system when available (Neovim 0.10+)
	if vim.system then
		local cmd_array = type(cmd) == "string"
				and (vim.fn.has("win32") == 1 and { "cmd.exe", "/c", cmd } or { "sh", "-c", cmd })
			or cmd

		-- In the vim.system part of execute_command:
		local system_opts = {
			text = true,
			cwd = opts.cwd,
			detach = opts.detach,
			stderr = opts.stderr_to_stdout and "stdout" or nil,
		}

		local job = vim.system(cmd_array, system_opts, function(result)
			if safe_callback then
				safe_callback(result.stdout, result.code == 0, result.code ~= 0 and result.stderr or nil)
			end
		end)

		return job

	-- Fall back to jobstart for older Neovim versions
	elseif vim.fn.exists("*jobstart") == 1 then
		local output = {}
		local stderr = {}
		local job_cmd = cmd_str

		local job_opts = {
			on_stdout = function(_, data)
				if data and #data > 0 then
					vim.list_extend(output, data)
				end
			end,
			on_stderr = function(_, data)
				if data and #data > 0 then
					vim.list_extend(stderr, data)
				end
			end,
			on_exit = function(_, code)
				if safe_callback then
					safe_callback(
						table.concat(output, "\n"),
						code == 0,
						code ~= 0 and table.concat(stderr, "\n") or nil
					)
				end
			end,
			stdout_buffered = true,
			stderr_buffered = true,
			detach = opts.detach or false,
		}

		if opts.cwd then
			job_opts.cwd = opts.cwd
		end

		local job_id = vim.fn.jobstart(job_cmd, job_opts)

		if job_id <= 0 then
			Snacks.notify.error("[Godot:JOBSTART_FAIL] jobstart failed with code: " .. job_id)

			vim.schedule(function()
				if safe_callback then
					safe_callback(nil, false, "Failed to start job (code: " .. job_id .. ")")
				end
			end)
			return nil
		end

		return {
			id = job_id,
			stop = function()
				vim.fn.jobstop(job_id)
			end,
		}

	-- Last resort: io.popen
	else
		vim.schedule(function()
			local handle = io.popen(cmd_str .. " 2>&1", "r")
			if not handle then
				Snacks.notify.error("[Godot:POPEN_FAIL] io.popen failed to open pipe")

				if safe_callback then
					safe_callback(nil, false, "Failed to open pipe")
				end
				return
			end

			local result = handle:read("*a")
			local success = handle:close()

			if safe_callback then
				safe_callback(result, success or false)
			end
		end)

		return nil
	end
end

-- Find scenes in current project
local function get_filtered_scenes(callback)
	local find_cmd

	if vim.fn.has("win32") == 1 then
		find_cmd =
			'powershell -Command "Get-ChildItem -Path . -Filter *.tscn -Recurse | Select-Object -ExpandProperty FullName"'
	else
		find_cmd = 'find "' .. vim.fn.getcwd() .. '" -name "*.tscn"'
	end

	execute_command(find_cmd, {}, function(result, success, err)
		if not success or not result or result == "" then
			Snacks.notify.error("Failed to find scene files: " .. (err or "No output"))
			callback(nil, "Failed to find scenes")
			return
		end

		local scenes = {}
		-- Split by newlines in a cross-platform way
		for scene in string.gmatch(result, "[^\r\n]+") do
			local should_exclude = false
			for _, dir in ipairs(config.exclude_dirs) do
				if string.find(scene, dir, 1, true) then
					should_exclude = true
					break
				end
			end

			if not should_exclude then
				table.insert(scenes, scene)
			end
		end

		if #scenes == 0 then
			Snacks.notify.error("No scenes found in project")
			callback(nil, "No scenes found")
		else
			callback(scenes)
		end
	end)
end

-- Build Godot solutions with file-based output capture and error handling
local function build_godot_solutions(callback)
	Snacks.notify.info("[Godot:BUILD] Building Godot solutions...")
	show_notification("Building Godot solutions...", "godot_build")

	-- Create a unique output file for this build
	local timestamp = os.time()
	local output_file = vim.fn.stdpath("cache") .. "/godot_build_" .. timestamp .. ".log"

	-- Track if we've already processed the build results
	local already_processed = false

	-- Create commands for different platforms
	local build_cmd, kill_cmd

	if vim.fn.has("win32") == 1 then
		-- Windows commands
		build_cmd = string.format('%s --headless --build-solutions > "%s" 2>&1', config.godot_binary, output_file)
		kill_cmd = string.format("taskkill /F /IM %s", config.godot_binary)
	else
		-- Unix commands
		build_cmd = string.format(
			'%s --headless --build-solutions > "%s" 2>&1 & echo $! > "%s.pid"',
			config.godot_binary,
			output_file,
			output_file
		)
		kill_cmd = string.format('kill $(cat "%s.pid") 2>/dev/null', output_file)
	end

	Snacks.notify.info("[Godot:BUILD] Running build with output to: " .. output_file)

	-- Execute the build command
	execute_command(build_cmd, {
		detach = true, -- Run in background
	}, function(result, success, err)
		Snacks.notify.info("[Godot:BUILD] Build command execution status changed")
	end)

	-- Schedule a check for completion
	local function check_completion()
		-- If already processed, don't do anything
		if already_processed then
			return
		end

		-- Check if the file exists and contains output
		if vim.fn.filereadable(output_file) == 1 then
			local lines = vim.fn.readfile(output_file)

			-- Check for completion marker
			local build_completed = false
			for _, line in ipairs(lines) do
				if line:find("dotnet_build_project: end") then
					build_completed = true
					break
				end
			end

			if build_completed then
				-- We found the marker, so we can process results
				Snacks.notify.info("[Godot:BUILD] Completion marker found, processing results")
				process_build_results(lines, output_file, callback)
				already_processed = true
				return
			end
		end

		-- Schedule another check after a short delay
		vim.defer_fn(check_completion, 1000) -- Check every second
	end

	-- Schedule a timeout check
	vim.defer_fn(function()
		if not already_processed then
			Snacks.notify.info("[Godot:BUILD] Build timeout reached, attempting to kill process")

			-- Try to kill the process
			execute_command(kill_cmd, {}, function()
				Snacks.notify.info("[Godot:BUILD] Kill command executed")

				-- Give a little time for the process to be killed and output to be flushed
				vim.defer_fn(function()
					if not already_processed then
						-- Process the results we have so far
						if vim.fn.filereadable(output_file) == 1 then
							local lines = vim.fn.readfile(output_file)
							process_build_results(lines, output_file, callback)
						else
							Snacks.notify.error("[Godot:BUILD] No output file found after timeout")
							update_notification("godot_build", "Build failed - no output file", false)

							if callback then
								callback(false, "No output file after timeout")
							end
						end
						already_processed = true
					end
				end, 500) -- Wait 500ms after kill before processing
			end)
		end
	end, config.build_timeout * 1000) -- Convert seconds to milliseconds

	-- Start the completion check
	check_completion()

	-- Helper function to process build results
	function process_build_results(lines, output_file, callback)
		local output_buffer = table.concat(lines, "\n")

		-- Log file size for debugging
		Snacks.notify.info(string.format("[Godot:BUILD] Processing %d bytes from output file", #output_buffer))

		-- Check for completion marker
		local build_completed = false
		for _, line in ipairs(lines) do
			if line:find("dotnet_build_project: end") then
				build_completed = true
				Snacks.notify.info("[Godot:BUILD] Build completion marker found in output file")
				break
			end
		end

		-- Create a buffer with the output for inspection
		if config.show_build_output or not build_completed then
			local buf = create_or_reuse_buffer("Godot Build Output", lines)
			if #lines > 0 then
				Snacks.notify.info("[Godot:BUILD] Full output available in buffer 'Godot Build Output'")
			else
				Snacks.notify.warn("[Godot:BUILD] No output captured from build process")
			end
		end

		-- Process success/failure
		local build_errors = false
		local error_msg = "Build failed"
		local ignorable_error = false

		-- Check for common error patterns in the output
		for _, line in ipairs(lines) do
			if line:match("Error:") or line:match("error CS%d+:") then
				-- Check if this is an ignorable error
				local is_ignorable = false
				for _, pattern in ipairs(config.ignore_build_errors) do
					if line:match(pattern) then
						is_ignorable = true
						ignorable_error = true
						break
					end
				end

				if not is_ignorable then
					build_errors = true
					error_msg = error_msg .. ": " .. line
					break
				end
			end
		end

		if build_completed and not build_errors then
			Snacks.notify.info("[Godot:BUILD_OK] Build completed successfully (confirmed by marker)")
			update_notification("godot_build", "Build completed successfully", true)

			if callback then
				callback(true)
			end
		elseif ignorable_error and not build_errors then
			-- We have ignorable errors but no serious errors
			Snacks.notify.info("[Godot:BUILD_OK] Build completed with ignorable errors")
			update_notification("godot_build", "Build completed with ignorable errors", true)

			if callback then
				callback(true)
			end
		elseif #lines > 0 and not build_errors then
			-- We have output but no completion marker - might be ok
			Snacks.notify.info("[Godot:BUILD_OK] Build appears complete (no marker found)")
			update_notification("godot_build", "Build appears complete (terminated by timeout)", true)

			if callback then
				callback(true)
			end
		else
			-- Command failed or errors found
			Snacks.notify.error("[Godot:BUILD_FAIL] " .. error_msg)
			update_notification("godot_build", error_msg, false)

			if callback then
				callback(false, error_msg)
			end
		end

		-- Clean up the files (optional)
		-- vim.fn.delete(output_file)
		-- vim.fn.delete(output_file .. ".pid")
	end
end

-- Kill Godot processes
local function kill_godot_processes(callback)
	local kill_cmd

	if vim.fn.has("win32") == 1 then
		kill_cmd = "taskkill /F /IM " .. config.godot_binary .. " 2>nul"
	else
		kill_cmd = 'pkill -f "' .. config.godot_binary .. '" 2>/dev/null'
	end

	execute_command(kill_cmd, {}, function()
		-- Wait a bit to ensure processes are killed
		vim.defer_fn(function()
			if callback then
				callback()
			end
		end, 300)
	end)
end

-- Scene selection with snacks.nvim
local function pick_godot_scene(callback)
	-- Find scenes and present picker
	get_filtered_scenes(function(scenes, err)
		if not scenes then
			Snacks.notify.error(err or "Failed to get scenes")
			if callback then
				callback(nil, err)
			end
			return
		end

		-- Load cached scene if available
		local last_scene = nil
		local cache_file = config.scene_cache_file

		if vim.fn.filereadable(cache_file) == 1 then
			local cached_scene = vim.fn.readfile(cache_file, "", 1)[1]
			if vim.fn.filereadable(cached_scene) == 1 then
				last_scene = cached_scene
			end
		end

		local items = {}

		-- Add last scene first if available
		if last_scene then
			table.insert(items, {
				text = "↻ Last: " .. vim.fn.fnamemodify(last_scene, ":."),
				file = last_scene,
				is_last = true,
			})
		end

		-- Add all scenes
		for _, scene in ipairs(scenes) do
			if scene ~= last_scene then
				table.insert(items, {
					text = vim.fn.fnamemodify(scene, ":."),
					file = scene,
				})
			end
		end

		-- Sort scenes alphabetically (except the last scene)
		table.sort(items, function(a, b)
			if a.is_last then
				return true
			end
			if b.is_last then
				return false
			end
			return a.text < b.text
		end)

		Snacks.notify.info("Found " .. #items .. " scene(s)")

		-- Show picker
		vim.schedule(function()
			Snacks.picker.pick({
				source = "select",
				title = "Select Godot Scene",
				items = items,
				confirm = function(picker, item)
					picker:close()

					if not item or not item.file then
						Snacks.notify.error("No scene selected")
						if callback then
							callback(nil, "No scene selected")
						end
						return
					end

					-- Save selection for next time
					vim.fn.writefile({ item.file }, config.scene_cache_file)

					Snacks.notify.info("Selected scene: " .. vim.fn.fnamemodify(item.file, ":."))
					if callback then
						callback(item.file)
					end
				end,
			})
		end)
	end)
end

-- Launch Godot with debug server
local function start_godot_with_scene(scene_path, callback)
	Snacks.notify.info("Starting Godot with scene: " .. vim.fn.fnamemodify(scene_path, ":."))

	-- Show launch notification
	show_notification("Launching Godot...", "godot_launch")

	-- Kill any existing Godot processes first
	kill_godot_processes(function()
		-- Get the project directory (we need to find the directory containing project.godot)
		local scene_dir = vim.fn.fnamemodify(scene_path, ":h")
		local project_dir = scene_dir

		-- Start from the scene directory and search upward for project.godot
		while vim.fn.filereadable(project_dir .. "/project.godot") ~= 1 do
			local new_dir = vim.fn.fnamemodify(project_dir, ":h")
			if new_dir == project_dir then
				-- We've reached the root directory without finding project.godot
				Snacks.notify.error("Could not find project.godot in any parent directory")
				update_notification("godot_launch", "Failed to find project.godot", false)

				if callback then
					callback(nil, "Failed to find project.godot")
				end
				return
			end
			project_dir = new_dir
		end

		-- Calculate the relative path from the project root to the scene
		local scene_full_path = vim.fn.fnamemodify(scene_path, ":p")
		local project_full_path = vim.fn.fnamemodify(project_dir, ":p")

		local rel_scene_path
		if scene_full_path:sub(1, #project_full_path) == project_full_path then
			-- Remove the project path prefix to get the relative path
			rel_scene_path = scene_full_path:sub(#project_full_path + 1)
			-- Remove leading slash if present
			if rel_scene_path:sub(1, 1) == "/" or rel_scene_path:sub(1, 1) == "\\" then
				rel_scene_path = rel_scene_path:sub(2)
			end
		else
			-- Fallback if we can't determine the relative path correctly
			rel_scene_path = scene_path
		end

		-- Debug logging
		Snacks.notify.info("Project directory: " .. project_dir)
		Snacks.notify.info("Scene path: " .. scene_path)
		Snacks.notify.info("Relative scene path: " .. rel_scene_path)

		-- Command with debug flags enabled to ensure Mono debugging works
		local cmd
		if vim.fn.has("win32") == 1 then
			-- Windows command
			cmd = string.format(
				'cd "%s" && %s --debug --breakpoints-enabled "%s"',
				project_dir,
				config.godot_binary,
				rel_scene_path
			)
		else
			-- Unix command
			cmd = string.format(
				'cd "%s" && %s --debug --breakpoints-enabled "%s"',
				project_dir,
				config.godot_binary,
				rel_scene_path
			)
		end

		Snacks.notify.info("Starting Godot with command: " .. cmd)

		-- Start Godot with debugging enabled
		local launched_job = execute_command(cmd, {
			detach = true,
		}, function(result, success, err)
			if not success then
				Snacks.notify.error("Failed to start Godot process: " .. (err or ""))
				update_notification("godot_launch", "Failed to start Godot: " .. (err or "unknown error"), false)

				if callback then
					callback(nil, "Launch failed: " .. (err or "unknown error"))
				end
				return
			end

			Snacks.notify.info("Godot launch command completed")
			update_notification("godot_launch", "Godot launched successfully", true)
		end)

		-- Get PID if available
		local pid = nil
		if launched_job and launched_job.pid then
			pid = launched_job.pid
			Snacks.notify.info("Godot process started with PID: " .. pid)
		else
			-- If we can't get the PID, use a dummy value
			pid = -1
			Snacks.notify.warn("Could not determine Godot PID, using dummy value -1")
		end

		-- Immediately proceed with the callback
		if callback then
			callback(pid)
		end
	end)
end

-- Direct connection with PID
local function connect_debugger(pid)
	Snacks.notify.info("Connecting debugger to Godot process with PID: " .. pid)

	-- Show connection notification
	show_notification("Connecting debugger...", "godot_debug")

	-- Store the PID for DAP to use
	M._godot_pid = pid

	-- Get DAP ready
	local dap = require("dap")

	-- Enable verbose logging if in debug mode
	if config.debug_mode then
		dap.set_log_level("TRACE")
	end

	-- Use pcall to handle any errors
	local status, err = pcall(function()
		-- Start debugging session
		dap.continue()
	end)

	if not status then
		Snacks.notify.error("Failed to start debugging: " .. tostring(err))
		update_notification("godot_debug", "Failed to connect debugger: " .. tostring(err), false)
		return false
	else
		Snacks.notify.info("Debug session started successfully")
		update_notification("godot_debug", "Debug session started successfully", true)
		return true
	end
end

-- Check if current file is in a Godot project
local function is_godot_project()
	-- Get the current file directory
	local current_file = vim.fn.expand("%:p")
	if current_file == "" then
		return false
	end

	local current_dir = vim.fn.fnamemodify(current_file, ":h")

	-- Traverse up directories looking for project.godot
	while true do
		if vim.fn.filereadable(current_dir .. "/project.godot") == 1 then
			return true, current_dir
		end

		local new_dir = vim.fn.fnamemodify(current_dir, ":h")
		if new_dir == current_dir then
			-- We've reached the root directory
			break
		end
		current_dir = new_dir
	end

	return false
end

-- Main launch function - Reorganized to show scene picker first
function M.launch()
	if state.in_progress then
		Snacks.notify.warn("Debug session already in progress")
		return
	end

	state.in_progress = true
	Snacks.notify.info("Starting debug session...")

	-- Step 1: Select scene first
	pick_godot_scene(function(scene_path, scene_error)
		if not scene_path then
			state.in_progress = false
			Snacks.notify.error("Debug session aborted: " .. (scene_error or "No scene selected"))
			return
		end

		-- Step 2: Build solutions after scene selection
		build_godot_solutions(function(build_success, build_error)
			if not build_success then
				state.in_progress = false
				Snacks.notify.error("Debug session aborted: " .. (build_error or "Build failed"))
				return
			end

			-- Step 3: Launch Godot
			start_godot_with_scene(scene_path, function(pid, launch_error)
				if not pid or pid <= 0 then
					state.in_progress = false
					Snacks.notify.error("Debug session aborted: " .. (launch_error or "Failed to launch"))
					return
				end

				-- Step 4: Directly connect debugger with PID
				connect_debugger(pid)

				-- Debug session is now active
				state.in_progress = false
			end)
		end)
	end)
end

-- Setup function with additional options
function M.setup(user_config)
	-- Apply user configuration
	if user_config then
		for k, v in pairs(user_config) do
			config[k] = v
		end
	end

	-- Create a place to store the current PID for debugging
	M._godot_pid = nil

	-- Configure DAP adapter
	local dap = require("dap")

	-- Set up netcoredbg adapter for Godot Mono
	dap.adapters.godot_mono = function(callback, adapter_config)
		if adapter_config.request == "attach" then
			callback({
				type = "executable",
				command = "netcoredbg",
				args = { "--interpreter=vscode" },
			})
		else
			Snacks.notify.error("Godot Mono adapter only supports attach mode")
			callback({
				type = "executable",
				error = "Invalid request type",
			})
		end
	end

	-- Register DAP configuration for C# files
	dap.configurations.cs = {
		{
			type = "godot_mono",
			request = "attach",
			name = "Attach to Godot Mono",
			processId = function()
				-- Return the stored PID that we already know
				if M._godot_pid and M._godot_pid > 0 then
					Snacks.notify.info("Using stored Godot PID: " .. M._godot_pid)
					return M._godot_pid
				else
					Snacks.notify.warn("No stored PID, letting user pick a process")
					return require("dap.utils").pick_process()
				end
			end,
			justMyCode = false,
		},
	}

	-- Also register for gdscript files
	dap.configurations.gdscript = dap.configurations.cs

	-- Hook into DAP continue to detect Godot projects automatically
	if config.auto_detect then
		-- Store the original continue function
		local original_continue = dap.continue

		-- Override continue with our version
		dap.continue = function()
			-- Check if we're in a Godot project and no debug session is active
			local is_godot, project_dir = is_godot_project()
			if is_godot and not state.in_progress and not dap.session() then
				-- We're in a Godot project, so launch Godot debug instead
				Snacks.notify.info("Detected Godot project, launching Godot debugger...")
				M.launch()
			else
				-- Use the original continue function otherwise
				original_continue()
			end
		end
	end

	-- Create user commands
	vim.api.nvim_create_user_command("GodotDebug", function()
		M.launch()
	end, {})

	vim.api.nvim_create_user_command("GodotQuit", function()
		kill_godot_processes(function()
			Snacks.notify.info("Godot processes terminated")
		end)
	end, {})
end
return M
