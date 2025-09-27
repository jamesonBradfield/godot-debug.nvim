-- File: lua/godot-debug/config.lua
local M = {}

-- Default configuration
local defaults = {
	godot_binary = vim.fn.has("win32") == 1 and "godot-mono.exe" or "godot-mono",
	exclude_dirs = { "addons/", "src/" },
	scene_cache_file = vim.fn.stdpath("cache") .. "/godot_last_scene.txt",
	debug_mode = true,
	auto_detect = true,
	ignore_build_errors = {
		"GdUnit.*Can't establish server.*Already in use",
		"Resource file not found: res://<.*Texture.*>",
	},
	buffer_reuse = true,
	build_timeout = 60,
	show_build_output = true,
}

-- Current configuration
local config = {}

function M.setup(user_config)
	-- Merge user config with defaults
	config = vim.tbl_deep_extend("force", defaults, user_config or {})
end

function M.get(key)
	return config[key]
end

function M.get_all()
	return config
end

return M
