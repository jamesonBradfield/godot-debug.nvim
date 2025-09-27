-- File: lua/godot-debug/godot.lua - Improved launch process
local M = {}

local config = require("godot-debug.config")
local logger = require("godot-debug.logger")
local notify = require("godot-debug.notifications")

M._godot_pid = nil
M._godot_job = nil

local function async_log(message)
	vim.schedule(function()
		logger.info(message)
	end)
end

function M.launch_scene(scene_path)
	async_log("Launching Godot with scene: " .. scene_path)

	local godot_binary = config.get("godot_binary")

	-- Kill existing processes
	M.kill_processes()
	vim.wait(500)

	-- Find project root
	local project_dir = vim.fn.getcwd()
	local project_file = vim.fn.findfile("project.godot", ".;")

	if project_file == "" then
		notify.error("Could not find project.godot")
		return nil
	end

	if project_file ~= "project.godot" then
		project_dir = vim.fn.fnamemodify(project_file, ":h")
	end

	-- Make scene path relative to project
	local rel_scene_path = vim.fn.fnamemodify(scene_path, ":.")

	-- Build command with proper debug flags
	local cmd_args = {
		godot_binary,
		"--path",
		project_dir, -- Specify project path
		rel_scene_path, -- Scene to run
	}

	-- Launch using jobstart for better control
	local job_opts = {
		cwd = project_dir,
		detach = false, -- Keep attached to get output
		on_stdout = function(job_id, data, event)
			for _, line in ipairs(data) do
				if line ~= "" then
					notify.verbose("Godot stdout", { line = line })
				end
			end
		end,
		on_stderr = function(job_id, data, event)
			for _, line in ipairs(data) do
				if line ~= "" then
					notify.verbose("Godot stderr", { line = line })
				end
			end
		end,
		on_exit = function(job_id, exit_code, event)
			notify.info("Godot process exited", { code = exit_code })
			M._godot_pid = nil
			M._godot_job = nil
		end,
	}

	M._godot_job = vim.fn.jobstart(cmd_args, job_opts)

	if M._godot_job <= 0 then
		notify.error("Failed to start Godot process")
		return nil
	end

	-- Get the actual PID
	vim.defer_fn(function()
		-- Find PID of the launched process
		local find_cmd
		if vim.fn.has("win32") == 1 then
			find_cmd =
				string.format("wmic process where \"name like '%%%s%%'\" get ProcessId /format:value", godot_binary)
		else
			find_cmd = string.format('pgrep -f "%s.*%s"', godot_binary, rel_scene_path)
		end

		local handle = io.popen(find_cmd)
		if handle then
			local output = handle:read("*a")
			handle:close()

			local pid
			if vim.fn.has("win32") == 1 then
				pid = output:match("ProcessId=(%d+)")
			else
				pid = output:match("(%d+)")
			end

			if pid then
				M._godot_pid = tonumber(pid)
				notify.info("Godot launched with PID: " .. M._godot_pid)
			end
		end
	end, 500)

	return M._godot_job
end

function M.kill_processes()
	-- Kill job if we have one
	if M._godot_job and M._godot_job > 0 then
		vim.fn.jobstop(M._godot_job)
		M._godot_job = nil
	end

	-- Kill by binary name
	local godot_binary = config.get("godot_binary")
	local kill_cmd

	if vim.fn.has("win32") == 1 then
		kill_cmd = string.format("taskkill /F /IM %s.exe 2>nul", godot_binary)
	else
		kill_cmd = string.format('pkill -f "%s" 2>/dev/null', godot_binary)
	end

	vim.fn.system(kill_cmd)
	M._godot_pid = nil
end

function M.select_scene(callback)
	async_log("Starting scene selection...")

	local scenes = M.find_scenes()

	if #scenes == 0 then
		notify.error("No scenes found in project")
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

	vim.ui.select(display_items, {
		prompt = "Select Godot Scene:",
		format_item = function(item)
			return item
		end,
	}, function(choice)
		if choice and file_map[choice] then
			local selected_scene = file_map[choice]
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

function M.find_scenes()
	local find_cmd

	if vim.fn.has("win32") == 1 then
		find_cmd = "where /r . *.tscn 2>nul"
	else
		find_cmd = 'find "' .. vim.fn.getcwd() .. '" -name "*.tscn" 2>/dev/null'
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

function M.build_solutions(force_clean)
	if force_clean then
		M.clean_build()
		vim.wait(1000)
	end

	notify.info("Building Godot solutions...")

	local output_file = vim.fn.stdpath("cache") .. "/godot_build.log"
	local godot_binary = config.get("godot_binary")

	-- Build command with proper flags
	local build_cmd = string.format('%s --headless --build-solutions --verbose > "%s" 2>&1', godot_binary, output_file)

	notify.debug("Running build command", { cmd = build_cmd })

	-- Run build synchronously to ensure it completes
	vim.fn.system(build_cmd)

	-- Check build results
	if vim.fn.filereadable(output_file) == 1 then
		local lines = vim.fn.readfile(output_file)

		-- Show build output if configured
		if config.get("show_build_output") then
			local buf_name = "Godot Build Output"
			local buf_id = vim.fn.bufnr(buf_name)

			if buf_id == -1 then
				buf_id = vim.api.nvim_create_buf(false, true)
				vim.api.nvim_buf_set_name(buf_id, buf_name)
			end

			vim.bo[buf_id].modifiable = true
			vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, lines)
			vim.bo[buf_id].modifiable = false
			vim.bo[buf_id].filetype = "log"
		end

		-- Check for errors
		local has_errors = false
		local error_count = 0

		for _, line in ipairs(lines) do
			if line:match("Error:") or line:match("error CS%d+:") then
				local ignorable = false
				for _, pattern in ipairs(config.get("ignore_build_errors")) do
					if line:match(pattern) then
						ignorable = true
						break
					end
				end

				if not ignorable then
					has_errors = true
					error_count = error_count + 1
					notify.error("Build error: " .. line)
				end
			end
		end

		if has_errors then
			notify.error(string.format("Build failed with %d errors", error_count))
		else
			notify.info("Build completed successfully")
		end

		return not has_errors
	else
		notify.error("Build output file not found")
		return false
	end
end

return M
