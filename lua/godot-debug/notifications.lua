-- File: lua/godot-debug/notifications.lua
local M = {}

local active_notifications = {}

function M.show_progress(id, message)
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

function M.update_progress(id, message, success)
	if not active_notifications[id] then
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

function M.hide(id)
	if active_notifications[id] then
		require("snacks").notifier.hide(active_notifications[id])
		active_notifications[id] = nil
	end
end

function M.info(message)
	require("snacks").notify.info(message)
end

function M.warn(message)
	require("snacks").notify.warn(message)
end

function M.error(message)
	require("snacks").notify.error(message)
end

return M
