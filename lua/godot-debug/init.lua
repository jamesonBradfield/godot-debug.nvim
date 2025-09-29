-- File: lua/godot-debug/init.lua - With enhanced notifications
local M = {}
local dap = require("dap")
local function run_command_wait_for_string(cmd, wait_string, callback, stop_on_match)
	stop_on_match = stop_on_match or false -- Default to false for backwards compatibility
	local output_buffer = ""
	local callback_called = false -- Prevent double callback

	local job_id = vim.fn.jobstart(cmd, {
		on_stdout = function(job_id, data, event)
			for _, line in ipairs(data) do
				if line ~= "" then
					output_buffer = output_buffer .. line .. "\n"
					if string.find(line, wait_string) then
						if not callback_called then
							callback_called = true
							callback(true, output_buffer, job_id)

							if stop_on_match then
								vim.fn.jobstop(job_id)
							end
						end
						return
					end
				end
			end
		end,
		on_exit = function(job_id, exit_code, event)
			if not callback_called and not string.find(output_buffer, wait_string) then
				callback(false, output_buffer, job_id)
			end
		end,
	})

	return job_id -- Return job_id so caller can stop it manually if needed
end
local function parse_csv_line(line)
	local fields = {}
	-- Match quoted fields: "field content"
	for field in line:gmatch('"([^"]*)"') do
		table.insert(fields, field)
	end
	return fields
end

local function get_godot_processes()
	local result = vim.fn.system('tasklist /FI "IMAGENAME eq godot-mono.exe" /FO CSV')
	local processes = {}
	local header = false
	for line in result:gmatch("[^\r\n]+") do
		local fields = parse_csv_line(line)
		if header ~= false then
			table.insert(processes, {
				name = fields[1],
				pid = fields[2],
				memory = fields[5],
			})
		end
		header = true
	end

	return processes
end

local function run()
	run_command_wait_for_string("godot-mono --path .", "Godot Engine", function(found, output)
		if found then
			print("Run Succeeded!")
			local pid = get_godot_processes()
			vim.notify(vim.inspect(pid))
			dap.configurations.cs = {
				{
					type = "coreclr",
					request = "attach",
					name = "attach",
					processId = tonumber(pid[2]["pid"]),
					justMyCode = true,
				},
			}
			dap.continue()
		else
			print("Run Failed!")
		end
	end)
end
-- the function to build our godot-mono project, we should setup callbacks/listeners we can define in our config for tasks to run before/after.
-- FIX: would like to match 'build succeeded' text, although that can end in a lot of ways, and this is non blocking.
local function build()
	run_command_wait_for_string("dotnet build", "Build succeeded in 0.8s", function(found, output)
		if found then
			print("Build Succeeded!")
			run()
		else
			print("Build Failed!")
		end
	end, true)
end

-- NOTE: both check_for_project and get_project_root have similiar code in my mind which means either (we callback and write one function), check if there is already something to get us 90% of the way there, or write our own function containing the "subset" of shared functionality.

-- check if we are in a godot-project sub-folder, (we can setup seperate strategies to find this "git, project.godot,etc")
local function check_for_project() end
-- actually grab the project root, this will be useful for both converting our absolute paths to godot rel format, and scene stuffs.
local function get_project_root() end

M.setup = function() end
-- the actual launching point for our plugin, we should spend some time thinking through how we will handle our pid grabbing for dap.
M.launch = function()
	build()
end
return M
