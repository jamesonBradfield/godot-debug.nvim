-- File: lua/godot-debug/notifications.lua
local M = {}

local active_notifications = {}

-- Fix: Add the missing slash in the log file path
local log_file = vim.fn.stdpath("cache") .. "/godot_debug_verbose.log"

local function ensure_log_file()
	if vim.fn.filereadable(log_file) == 0 then
		vim.fn.writefile({}, log_file)
	end
end

local function write_to_log(level, message, data)
	ensure_log_file()

	local timestamp = os.date("%Y-%m-%d %H:%M:%S")
	local log_entry = string.format("[%s] %s: %s", timestamp, level, message)

	if data then
		log_entry = log_entry .. "\nData: " .. vim.inspect(data)
	end

	vim.fn.writefile({ log_entry, "" }, log_file, "a")

	if level == "ERROR" or level == "WARNING" then
		print(string.format("[Godot Debug] %s: %s", level, message))
	end
end

function M.show_progress(id, message)
	write_to_log("PROGRESS_START", message, { id = id })

	local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

	-- Fix: Use correct Snacks API - notify instead of notifier
	local notif = require("snacks").notify(message, {
		level = "info",
		id = id,
		title = "Godot Debugger",
		-- Use a simple spinner animation
		icon = spinner[1],
		timeout = false,
	})

	active_notifications[id] = notif
	return notif
end

function M.update_progress(id, message, success)
	write_to_log("PROGRESS_UPDATE", message, {
		id = id,
		success = success,
	})

	if not active_notifications[id] then
		write_to_log("WARNING", "Tried to update non-existent notification", { id = id })
		return
	end

	local level = success and "info" or "error"
	local icon = success and "✓" or "✗"

	-- Fix: Update notification properly
	require("snacks").notify(message, {
		level = level,
		id = id,
		title = "Godot Debugger",
		icon = icon,
		timeout = 3000,
	})

	active_notifications[id] = nil
end

function M.hide(id)
	write_to_log("HIDE", "Hiding notification", { id = id })

	if active_notifications[id] then
		-- Snacks doesn't have a direct hide method, so we update with minimal timeout
		require("snacks").notify("", {
			id = id,
			timeout = 1,
		})
		active_notifications[id] = nil
	else
		write_to_log("WARNING", "Tried to hide non-existent notification", { id = id })
	end
end

function M.info(message)
	write_to_log("INFO", message)
	require("snacks").notify.info(message)
end

function M.warn(message)
	write_to_log("WARNING", message)
	require("snacks").notify.warn(message)
end

function M.error(message)
	write_to_log("ERROR", message)
	require("snacks").notify.error(message)
end

function M.debug(message, data)
	write_to_log("DEBUG", message, data)
end

function M.verbose(message, data)
	write_to_log("VERBOSE", message, data)
end

local active_operations = {}

function M.start_operation(operation_name, description)
	local operation_id = tostring(math.random(1000000))

	active_operations[operation_id] = {
		name = operation_name,
		description = description,
		start_time = os.clock(),
		start_timestamp = os.date("%Y-%m-%d %H:%M:%S"),
	}

	write_to_log("OPERATION_START", operation_name, {
		id = operation_id,
		description = description,
	})

	M.show_progress("operation_" .. operation_id, description)

	return operation_id
end

function M.complete_operation(operation_id, success, result_message)
	if not active_operations[operation_id] then
		write_to_log("WARNING", "Tried to complete unknown operation", { id = operation_id })
		return
	end

	local operation = active_operations[operation_id]
	local elapsed_time = os.clock() - operation.start_time

	write_to_log("OPERATION_COMPLETE", operation.name, {
		id = operation_id,
		success = success,
		elapsed_time = elapsed_time,
		result_message = result_message,
	})

	M.update_progress("operation_" .. operation_id, result_message, success)

	active_operations[operation_id] = nil
end

function M.check_operation_timeouts()
	local current_time = os.clock()

	for id, operation in pairs(active_operations) do
		local elapsed = current_time - operation.start_time

		if elapsed > 30 then
			write_to_log("WARNING", "Operation taking too long", {
				id = id,
				name = operation.name,
				elapsed_time = elapsed,
			})

			M.warn(string.format("%s is taking longer than expected (%.1fs)", operation.name, elapsed))
		end
	end
end

local timeout_timer = vim.loop.new_timer()
timeout_timer:start(
	0,
	5000,
	vim.schedule_wrap(function()
		M.check_operation_timeouts()
	end)
)

function M.clear_all()
	write_to_log("CLEAR_ALL", "Clearing all notifications and operations")

	for id, _ in pairs(active_notifications) do
		M.hide(id)
	end

	for id, _ in pairs(active_operations) do
		M.hide("operation_" .. id)
	end

	active_operations = {}
end

function M.view_log()
	ensure_log_file()

	if vim.fn.filereadable(log_file) == 0 then
		M.error("Log file not found: " .. log_file)
		return
	end

	-- Create a new buffer for the log
	local buf = vim.api.nvim_create_buf(false, true)

	-- Read log content
	local content = vim.fn.readfile(log_file)
	local cleaned_content = vim.tbl_map(function(line)
		return string.gsub(line, "\n", "")
	end, content)
	-- Set content before setting name
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, cleaned_content)

	-- Set buffer properties
	vim.api.nvim_buf_set_name(buf, "Godot Debug Log")
	vim.bo[buf].readonly = true
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "log"

	-- Open in a vertical split
	vim.cmd("vsplit")
	vim.api.nvim_win_set_buf(0, buf)

	-- Jump to the end of the log
	vim.cmd("normal! G")

	M.info("Opened debug log in vertical split")
end

function M.clear_log()
	vim.fn.writefile({}, log_file)
	write_to_log("INFO", "Log file cleared")
	M.info("Debug log cleared")
end

function M.tail_log()
	ensure_log_file()

	if vim.fn.filereadable(log_file) == 0 then
		M.error("Log file not found: " .. log_file)
		return
	end

	-- Open log file
	vim.cmd("tabnew " .. log_file)
	vim.bo.readonly = true
	vim.bo.filetype = "log"

	-- Set up auto-refresh
	local buf = vim.api.nvim_get_current_buf()
	local timer = vim.loop.new_timer()

	timer:start(
		0,
		1000,
		vim.schedule_wrap(function()
			if vim.api.nvim_buf_is_valid(buf) then
				local cursor_pos = vim.api.nvim_win_get_cursor(0)
				vim.cmd("edit!")
				vim.cmd("normal! G")
			else
				timer:stop()
				timer:close()
			end
		end)
	)

	M.info("Tailing debug log (auto-refreshing)")
end

return M
