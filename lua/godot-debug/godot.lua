-- File: lua/godot-debug/godot.lua - Async version without blocking prints
local M = {}

local config = require("godot-debug.config")
local logger = require("godot-debug.logger")

-- Store the current Godot PID
M._godot_pid = nil

-- Async logging function
local function async_log(message)
	vim.schedule(function()
		logger.info(message)
	end)
end

-- Launch Godot with a scene
function M.launch_scene(scene_path)
	async_log("Launching Godot with scene: " .. scene_path)

	local godot_binary = config.get("godot_binary")

	-- Kill any existing processes first
	M.kill_processes()
	vim.wait(300)

	-- Find project root
	local project_dir = vim.fn.fnamemodify(scene_path, ":h")
	while vim.fn.filereadable(project_dir .. "/project.godot") ~= 1 do
		local new_dir = vim.fn.fnamemodify(project_dir, ":h")
		if new_dir == project_dir then
			async_log("ERROR: Could not find project.godot")
			return nil
		end
		project_dir = new_dir
	end

	-- Calculate relative path
	local rel_scene_path = vim.fn.fnamemodify(scene_path, ":.")

	-- Use vim.system if available (Neovim 0.10+)
	local pid = nil
	if vim.system then
		local cmd_array = { godot_binary, "--debug", "--debug-mono", "--verbose", rel_scene_path }

		local job = vim.system(cmd_array, {
			cwd = project_dir,
			detach = true,
		})

		if job and job.pid then
			pid = job.pid
			M._godot_pid = pid
			async_log("Godot launched with PID: " .. pid)
		end
	else
		-- Fallback for older Neovim versions
		local launch_cmd = string.format(
			'cd "%s" && %s --debug --debug-mono --verbose "%s" &',
			project_dir,
			godot_binary,
			rel_scene_path
		)

		-- Use jobstart for async execution
		local job_id = vim.fn.jobstart(launch_cmd, {
			detach = true,
			on_exit = function(_, code)
				async_log("Godot process exited with code: " .. code)
			end,
		})

		if job_id > 0 then
			-- Give Godot time to start, then find its PID
			vim.defer_fn(function()
				local find_cmd = 'pgrep -f "' .. godot_binary .. ".*" .. rel_scene_path .. '"'
				local handle = io.popen(find_cmd)
				if handle then
					local pid_str = handle:read("*line")
					handle:close()

					if pid_str then
						pid = tonumber(pid_str)
						M._godot_pid = pid
						async_log("Found Godot PID: " .. pid)
					end
				end
			end, 1000)
		end
	end

	return pid
end

-- Connect debugger to Godot
function M.connect_debugger(pid)
	async_log("Connecting debugger to PID: " .. pid)

	M._godot_pid = pid

	-- Wait for Godot to be ready
	vim.defer_fn(function()
		local dap = require("dap")

		-- Start debug session
		local success, err = pcall(function()
			dap.continue()
		end)

		if not success then
			async_log("Failed to start debug session: " .. tostring(err))
		end
	end, 2000)

	return true
end

-- Kill Godot processes
function M.kill_processes()
	local godot_binary = config.get("godot_binary")
	local kill_cmd

	if vim.fn.has("win32") == 1 then
		kill_cmd = "taskkill /F /IM " .. godot_binary .. " 2>nul"
	else
		kill_cmd = 'pkill -f "' .. godot_binary .. '" 2>/dev/null'
	end

	vim.fn.system(kill_cmd)
end

-- Select a scene using the picker
function M.select_scene(callback)
	async_log("Starting scene selection...")

	local scenes = M.find_scenes()

	if #scenes == 0 then
		async_log("No scenes found")
		if callback then
			callback(nil)
		end
		return
	end

	-- Load cached scene
	local cache_file = config.get("scene_cache_file")
	local last_scene = nil

	if vim.fn.filereadable(cache_file) == 1 then
		local cached_scenes = vim.fn.readfile(cache_file)
		if #cached_scenes > 0 and vim.fn.filereadable(cached_scenes[1]) == 1 then
			last_scene = cached_scenes[1]
		end
	end

	-- Prepare picker items
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

	-- Use vim.ui.select properly
	vim.ui.select(display_items, {
		prompt = "Select Godot Scene:",
	}, function(choice)
		if choice and file_map[choice] then
			local selected_scene = file_map[choice]

			-- Save selection
			vim.fn.writefile({ selected_scene }, cache_file)

			if callback then
				callback(selected_scene)
			end
		else
			if callback then
				callback(nil)
			end
		end
	end)
end

-- Find scenes in current project
function M.find_scenes()
	local find_cmd

	if vim.fn.has("win32") == 1 then
		find_cmd =
			'powershell -Command "Get-ChildItem -Path . -Filter *.tscn -Recurse | Select-Object -ExpandProperty FullName"'
	else
		find_cmd = 'find "' .. vim.fn.getcwd() .. '" -name "*.tscn"'
	end

	local handle = io.popen(find_cmd)
	if not handle then
		return {}
	end

	local output = handle:read("*all")
	handle:close()

	if not output or output == "" then
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

-- Build Godot solutions
function M.build_solutions()
	async_log("Starting Godot build process")

	local output_file = vim.fn.stdpath("cache") .. "/godot_build.log"
	local godot_binary = config.get("godot_binary")

	local build_cmd
	if vim.fn.has("win32") == 1 then
		build_cmd = string.format('%s --headless --build-solutions > "%s" 2>&1', godot_binary, output_file)
	else
		build_cmd = string.format('%s --headless --build-solutions > "%s" 2>&1', godot_binary, output_file)
	end

	-- Run build command using jobstart for async execution
	local job_id = vim.fn.jobstart(build_cmd, {
		on_exit = function(_, code)
			async_log("Build process completed with code: " .. code)
		end,
	})

	if job_id <= 0 then
		async_log("Failed to start build process")
		return false
	end

	-- Wait for completion or timeout
	local timeout = config.get("build_timeout") * 1000
	local start_time = os.clock()
	local build_complete = false

	while (os.clock() - start_time) * 1000 < timeout do
		vim.wait(1000)

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
		vim.fn.jobstop(job_id)
		vim.wait(500)
	end

	-- Check build results
	if vim.fn.filereadable(output_file) == 1 then
		local lines = vim.fn.readfile(output_file)

		-- Create build output buffer if needed
		if config.get("show_build_output") then
			local buf_name = "Godot Build Output"
			local buf_id = nil

			-- Check if buffer already exists
			for _, buf in ipairs(vim.api.nvim_list_bufs()) do
				local name = vim.api.nvim_buf_get_name(buf)
				if name:match(buf_name .. "$") then
					buf_id = buf
					break
				end
			end

			-- Create new buffer if needed
			if not buf_id then
				buf_id = vim.api.nvim_create_buf(false, true)
				vim.api.nvim_buf_set_name(buf_id, buf_name)
			end

			-- Set buffer content
			vim.api.nvim_buf_set_option(buf_id, "modifiable", true)
			vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, lines)
			vim.api.nvim_buf_set_option(buf_id, "modifiable", false)
			vim.api.nvim_buf_set_option(buf_id, "filetype", "log")
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
					break
				end
			end
		end

		return not has_errors
	else
		return false
	end
end

return M
