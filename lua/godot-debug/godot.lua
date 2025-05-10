-- File: lua/godot-debug/godot.lua
local M = {}

local config = require("godot-debug.config")
local logger = require("godot-debug.logger")
local notifications = require("godot-debug.notifications")

-- Check if a process is still running
function M.is_process_running(pid)
	if not pid or pid <= 0 then
		return false
	end

	local check_cmd

	if vim.fn.has("win32") == 1 then
		-- Windows: Use WMIC for more reliable process checking
		check_cmd = string.format('wmic process where "ProcessId=%d" get ProcessId /value 2>nul', pid)
	else
		-- Unix-like systems: Use kill -0
		check_cmd = string.format("kill -0 %d 2>/dev/null", pid)
	end

	local handle = io.popen(check_cmd, "r")
	if not handle then
		return false
	end

	local result = handle:read("*a")
	local success = handle:close()

	if vim.fn.has("win32") == 1 then
		-- Windows: Check if output contains ProcessId=
		return result and result:find("ProcessId=" .. pid) ~= nil
	else
		-- Unix: kill -0 returns 0 if process exists
		return success == true
	end
end

-- Simplified command execution
local function run_command(cmd, options)
	options = options or {}

	logger.debug("Running command: " .. tostring(cmd))

	-- Use vim.system for Neovim 0.10+
	if vim.system then
		local cmd_array = type(cmd) == "string"
				and (vim.fn.has("win32") == 1 and { "cmd.exe", "/c", cmd } or { "sh", "-c", cmd })
			or cmd

		local job = vim.system(cmd_array, {
			text = true,
			cwd = options.cwd,
			detach = options.detach,
		})

		-- Wait for result if not detached
		if not options.detach then
			local result = job:wait()
			return result.stdout, result.code == 0, result.stderr
		end

		return job
	end

	-- Fallback for older versions
	local output = ""
	local success = true
	local handle = io.popen(cmd, "r")

	if handle then
		output = handle:read("*a")
		success = handle:close()
	end

	return output, success
end

-- Find scenes in the project
function M.find_scenes()
	local find_cmd

	if vim.fn.has("win32") == 1 then
		find_cmd =
			'powershell -Command "Get-ChildItem -Path . -Filter *.tscn -Recurse | Select-Object -ExpandProperty FullName"'
	else
		find_cmd = 'find "' .. vim.fn.getcwd() .. '" -name "*.tscn"'
	end

	local output, success = run_command(find_cmd)

	if not success or not output or output == "" then
		logger.error("Failed to find scene files")
		return {}
	end

	local scenes = {}
	for scene in string.gmatch(output, "[^\r\n]+") do
		local should_exclude = false
		for _, dir in ipairs(config.get("exclude_dirs")) do
			if string.find(scene, dir, 1, true) then
				should_exclude = true
				break
			end
		end

		if not should_exclude then
			table.insert(scenes, scene)
		end
	end

	return scenes
end

-- Select a scene using the picker (callback version)
function M.select_scene(callback)
	notifications.show_progress("scene_selection", "Finding scenes...")
	logger.info("Starting scene selection with callback...")

	local scenes = M.find_scenes()
	logger.info("Found " .. #scenes .. " scenes")

	if #scenes == 0 then
		notifications.update_progress("scene_selection", "No scenes found", false)
		logger.error("No scenes found")
		if callback then
			callback(nil)
		end
		return
	end

	notifications.hide("scene_selection")

	-- Load cached scene
	local cache_file = config.get("scene_cache_file")
	local last_scene = nil

	if vim.fn.filereadable(cache_file) == 1 then
		local cached_scenes = vim.fn.readfile(cache_file)
		if #cached_scenes > 0 and vim.fn.filereadable(cached_scenes[1]) == 1 then
			last_scene = cached_scenes[1]
			logger.info("Found cached scene: " .. last_scene)
		end
	end

	-- Prepare picker items - simple string array for vim.ui.select
	local display_items = {}
	local file_map = {}

	if last_scene then
		local display = "↻ Last: " .. vim.fn.fnamemodify(last_scene, ":.")
		table.insert(display_items, display)
		file_map[display] = last_scene
	end

	for _, scene in ipairs(scenes) do
		if scene ~= last_scene then
			local display = vim.fn.fnamemodify(scene, ":.")
			table.insert(display_items, display)
			file_map[display] = scene
		end
	end

	logger.info("Showing picker with " .. #display_items .. " items")

	-- Use vim.ui.select properly (asynchronously)
	vim.ui.select(display_items, {
		prompt = "Select Godot Scene:",
	}, function(choice)
		logger.info("Selection made: " .. tostring(choice))

		if choice and file_map[choice] then
			local selected_scene = file_map[choice]
			logger.info("Selected scene: " .. selected_scene)

			-- Save selection
			vim.fn.writefile({ selected_scene }, cache_file)

			-- Call callback with selected scene
			if callback then
				logger.info("Calling callback with selected scene")
				callback(selected_scene)
			end
		else
			logger.warn("No scene selected or cancelled")
			if callback then
				logger.info("Calling callback with nil")
				callback(nil)
			end
		end
	end)
end

-- Build Godot solutions
function M.build_solutions()
	notifications.show_progress("build", "Building Godot solutions...")
	logger.info("Starting Godot build process")

	local output_file = vim.fn.stdpath("cache") .. "/godot_build.log"
	local godot_binary = config.get("godot_binary")

	local build_cmd
	if vim.fn.has("win32") == 1 then
		build_cmd = string.format('%s --headless --build-solutions > "%s" 2>&1', godot_binary, output_file)
	else
		build_cmd = string.format('%s --headless --build-solutions > "%s" 2>&1', godot_binary, output_file)
	end

	-- Run build command
	local job = run_command(build_cmd, { detach = true })

	-- Wait for completion or timeout
	local timeout = config.get("build_timeout") * 1000
	local start_time = os.clock()
	local build_complete = false

	while (os.clock() - start_time) * 1000 < timeout do
		vim.wait(1000) -- Check every second

		if vim.fn.filereadable(output_file) == 1 then
			local lines = vim.fn.readfile(output_file)

			-- Check for completion marker
			for _, line in ipairs(lines) do
				if line:find("dotnet_build_project: end") then
					build_complete = true
					break
				end
			end

			if build_complete then
				break
			end
		end
	end

	-- Kill the process if it's still running after timeout
	if not build_complete then
		logger.warn("Build process timed out, killing...")

		if vim.fn.has("win32") == 1 then
			run_command("taskkill /F /IM " .. godot_binary)
		else
			run_command('pkill -f "' .. godot_binary .. '"')
		end

		vim.wait(500) -- Give it time to die
	end

	-- Check build results
	if vim.fn.filereadable(output_file) == 1 then
		local lines = vim.fn.readfile(output_file)

		-- Create build output buffer if needed
		if config.get("show_build_output") then
			local buf = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_name(buf, "Godot Build Output")
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			vim.api.nvim_buf_set_option(buf, "filetype", "log")
		end

		-- Check for errors
		local has_errors = false
		for _, line in ipairs(lines) do
			if line:match("Error:") or line:match("error CS%d+:") then
				-- Check if it's an ignorable error
				local ignorable = false
				for _, pattern in ipairs(config.get("ignore_build_errors")) do
					if line:match(pattern) then
						ignorable = true
						break
					end
				end

				if not ignorable then
					has_errors = true
					logger.error("Build error: " .. line)
					break
				end
			end
		end

		if not has_errors then
			notifications.update_progress("build", "Build completed successfully", true)
			return true
		else
			notifications.update_progress("build", "Build failed with errors", false)
			return false
		end
	else
		notifications.update_progress("build", "Build failed - no output", false)
		return false
	end
end

-- Launch Godot with a scene
function M.launch_scene(scene_path)
	notifications.show_progress("launch", "Launching Godot...")
	logger.info("Launching Godot with scene: " .. scene_path)

	-- Kill any existing processes first
	M.kill_processes()
	vim.wait(300) -- Give them time to die

	-- Find project root
	local project_dir = vim.fn.fnamemodify(scene_path, ":h")
	while vim.fn.filereadable(project_dir .. "/project.godot") ~= 1 do
		local new_dir = vim.fn.fnamemodify(project_dir, ":h")
		if new_dir == project_dir then
			logger.error("Could not find project.godot")
			notifications.update_progress("launch", "Failed to find project.godot", false)
			return nil
		end
		project_dir = new_dir
	end

	-- Calculate relative path
	local rel_scene_path = vim.fn.fnamemodify(scene_path, ":.")
	local godot_binary = config.get("godot_binary")

	-- Launch command
	local launch_cmd
	if vim.fn.has("win32") == 1 then
		launch_cmd =
			string.format('cd "%s" && %s --debug --breakpoints-enabled "%s"', project_dir, godot_binary, rel_scene_path)
	else
		launch_cmd = string.format(
			'cd "%s" && %s --debug --breakpoints-enabled "%s" & echo $! > /tmp/godot.pid',
			project_dir,
			godot_binary,
			rel_scene_path
		)
	end

	logger.debug("Launch command: " .. launch_cmd)

	-- Start Godot
	local job = run_command(launch_cmd, { detach = true })

	-- Get PID
	local pid = -1
	if job and job.pid then
		pid = job.pid
	elseif vim.fn.has("unix") == 1 and vim.fn.filereadable("/tmp/godot.pid") == 1 then
		local pid_str = vim.fn.readfile("/tmp/godot.pid", "", 1)[1]
		pid = tonumber(pid_str) or -1
	end

	M._godot_pid = pid

	if pid > 0 then
		notifications.update_progress("launch", "Godot launched (PID: " .. pid .. ")", true)
		return pid
	else
		notifications.update_progress("launch", "Failed to get Godot PID", false)
		return nil
	end
end

-- Connect debugger to Godot
function M.connect_debugger(pid)
	notifications.show_progress("debug", "Connecting debugger...")
	logger.info("Connecting debugger to PID: " .. pid)

	M._godot_pid = pid

	local dap = require("dap")

	-- Start debug session
	local success, err = pcall(function()
		dap.continue()
	end)

	if success then
		notifications.update_progress("debug", "Debug session started", true)
		return true
	else
		logger.error("Failed to start debug session: " .. tostring(err))
		notifications.update_progress("debug", "Failed to connect debugger", false)
		return false
	end
end

-- Kill all Godot processes
function M.kill_processes()
	logger.info("Killing all Godot processes")

	local godot_binary = config.get("godot_binary")
	local kill_cmd

	if vim.fn.has("win32") == 1 then
		kill_cmd = "taskkill /F /IM " .. godot_binary .. " 2>nul"
	else
		kill_cmd = 'pkill -f "' .. godot_binary .. '" 2>/dev/null'
	end

	run_command(kill_cmd)
	notifications.info("Godot processes terminated")
end

return M
