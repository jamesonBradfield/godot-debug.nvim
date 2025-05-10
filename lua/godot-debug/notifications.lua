-- File: lua/godot-debug/notifications.lua
local M = {}

local active_notifications = {}

-- Verbose logging setup
local log_file = vim.fn.stdpath("cache") .. "/godot_debug_verbose.log"

-- Ensure log file exists
local function ensure_log_file()
	if vim.fn.filereadable(log_file) == 0 then
		vim.fn.writefile({}, log_file)
	end
end

-- Write to log file with timestamp
local function write_to_log(level, message, data)
	ensure_log_file()

	local timestamp = os.date("%Y-%m-%d %H:%M:%S")
	local log_entry = string.format("[%s] %s: %s", timestamp, level, message)

	-- Add data if provided
	if data then
		log_entry = log_entry .. "\nData: " .. vim.inspect(data)
	end

	-- Append to log file
	vim.fn.writefile({ log_entry, "" }, log_file, "a")

	-- Also print to neovim messages for debugging
	if level == "ERROR" or level == "WARNING" then
		print(string.format("[Godot Debug] %s: %s", level, message))
	end
end

-- Original function with logging
function M.show_progress(id, message)
	write_to_log("PROGRESS_START", message, { id = id })

	-- Use the correct snacks.nvim API
	local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

	local notif = require("snacks").notifier(message, "info", {
		id = id,
		title = "Godot Debugger",
		opts = function(notif)
			notif.icon = spinner[math.floor(vim.loop.hrtime() / (1e6 * 80)) % #spinner + 1]
		end,
		timeout = false, -- Keep until manually closed
	})

	active_notifications[id] = notif
	return notif
end

-- Original function with logging
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

	-- Update notification using notifier
	require("snacks").notifier(message, level, {
		id = active_notifications[id],
		title = "Godot Debugger",
		icon = icon,
		timeout = 3000, -- Auto-dismiss after 3 seconds
	})

	active_notifications[id] = nil
end

-- Original function with logging
function M.hide(id)
	write_to_log("HIDE", "Hiding notification", { id = id })

	if active_notifications[id] then
		require("snacks").notifier.hide(active_notifications[id])
		active_notifications[id] = nil
	else
		write_to_log("WARNING", "Tried to hide non-existent notification", { id = id })
	end
end

-- Enhanced info with logging
function M.info(message)
	write_to_log("INFO", message)
	require("snacks").notify.info(message)
end

-- Enhanced warn with logging
function M.warn(message)
	write_to_log("WARNING", message)
	require("snacks").notify.warn(message)
end

-- Enhanced error with logging
function M.error(message)
	write_to_log("ERROR", message)
	require("snacks").notify.error(message)
end

-- New debug function
function M.debug(message, data)
	write_to_log("DEBUG", message, data)

	-- Optionally show debug messages as notifications (commented out by default)
	-- Uncomment the next line if you want to see debug notifications
	-- require("snacks").notify(message, "info", {title = "Debug", timeout = 1500})
end

-- New verbose function for detailed logging without notifications
function M.verbose(message, data)
	write_to_log("VERBOSE", message, data)
end

-- Operation tracking for better debugging
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

	-- Show progress notification
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

	-- Update progress notification
	M.update_progress("operation_" .. operation_id, result_message, success)

	active_operations[operation_id] = nil
end

-- Check for long-running operations
function M.check_operation_timeouts()
	local current_time = os.clock()

	for id, operation in pairs(active_operations) do
		local elapsed = current_time - operation.start_time

		if elapsed > 30 then -- 30 seconds
			write_to_log("WARNING", "Operation taking too long", {
				id = id,
				name = operation.name,
				elapsed_time = elapsed,
			})

			-- Show warning notification
			M.warn(string.format("%s is taking longer than expected (%.1fs)", operation.name, elapsed))
		end
	end
end

-- Start periodic timeout checker
local timeout_timer = vim.loop.new_timer()
timeout_timer:start(
	0,
	5000,
	vim.schedule_wrap(function()
		M.check_operation_timeouts()
	end)
)

-- Clear all active notifications and operations
function M.clear_all()
	write_to_log("CLEAR_ALL", "Clearing all notifications and operations")

	-- Clear notifications
	for id, _ in pairs(active_notifications) do
		M.hide(id)
	end

	-- Clear operations
	for id, _ in pairs(active_operations) do
		M.hide("operation_" .. id)
	end

	active_operations = {}
end

-- Helper to view the log file
function M.view_log()
	if vim.fn.filereadable(log_file) == 1 then
		-- Create a new buffer for the log
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(buf, "Godot Debug Log")

		-- Read log content
		local content = vim.fn.readfile(log_file)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)

		-- Set buffer options
		vim.api.nvim_buf_set_option(buf, "readonly", true)
		vim.api.nvim_buf_set_option(buf, "modifiable", false)
		vim.api.nvim_buf_set_option(buf, "filetype", "log")

		-- Open in a vertical split
		vim.cmd("vsplit")
		vim.api.nvim_win_set_buf(0, buf)

		-- Jump to the end of the log
		vim.cmd("normal! G")

		M.info("Opened debug log in vertical split")
	else
		M.error("Log file not found: " .. log_file)
	end
end

-- Helper to clear the log file
function M.clear_log()
	vim.fn.writefile({}, log_file)
	write_to_log("INFO", "Log file cleared")
	M.info("Debug log cleared")
end

-- Helper to tail the log (follow new entries)
function M.tail_log()
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
				-- Save cursor position
				local cursor_pos = vim.api.nvim_win_get_cursor(0)

				-- Reload buffer
				vim.cmd("edit!")

				-- Restore cursor to bottom for tailing
				vim.cmd("normal! G")
			else
				-- Buffer was closed, stop timer
				timer:stop()
				timer:close()
			end
		end)
	)

	M.info("Tailing debug log (auto-refreshing)")
end

return M
