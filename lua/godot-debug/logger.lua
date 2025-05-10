-- File: lua/godot-debug/logger.lua
local M = {}

local log_file = vim.fn.stdpath("cache") .. "/godot_debug.log"
local log_level = vim.log.levels.INFO
local debug_buffer = nil

function M.setup()
	-- Create log file if it doesn't exist
	if vim.fn.filereadable(log_file) == 0 then
		vim.fn.writefile({}, log_file)
	end

	-- Create debug buffer
	debug_buffer = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(debug_buffer, "Godot Debug Log")
	vim.api.nvim_buf_set_option(debug_buffer, "filetype", "log")
end

function M.set_level(level)
	if type(level) == "number" and level >= 0 and level <= 4 then
		log_level = level
		M.info("Log level set to " .. level)
	else
		M.error("Invalid log level: " .. tostring(level))
	end
end

local function write_log(level, message, data)
	if level < log_level then
		return
	end

	local timestamp = os.date("%Y-%m-%d %H:%M:%S")
	local level_name = vim.log.levels[level] or "UNKNOWN"
	local log_entry = string.format("[%s] %s: %s", timestamp, level_name, message)

	if data then
		log_entry = log_entry .. "\nData: " .. vim.inspect(data)
	end

	-- Write to file
	vim.fn.writefile({ log_entry }, log_file, "a")

	-- Write to buffer
	if debug_buffer then
		vim.schedule(function()
			vim.api.nvim_buf_set_lines(debug_buffer, -1, -1, false, { log_entry, "" })
		end)
	end

	-- Also show in notifications for warnings and errors
	if level >= vim.log.levels.WARN then
		local snacks = require("snacks")
		if level == vim.log.levels.ERROR then
			snacks.notify.error(message)
		else
			snacks.notify.warn(message)
		end
	end
end

function M.trace(message, data)
	write_log(vim.log.levels.TRACE, message, data)
end

function M.debug(message, data)
	write_log(vim.log.levels.DEBUG, message, data)
end

function M.info(message, data)
	write_log(vim.log.levels.INFO, message, data)
end

function M.warn(message, data)
	write_log(vim.log.levels.WARN, message, data)
end

function M.error(message, data)
	write_log(vim.log.levels.ERROR, message, data)
end

return M
