# godot-debug.nvim

A Neovim plugin for seamless debugging of Godot Mono/C# projects with integrated scene selection, solution building, and direct process attachment.

## Features

- 🎯 **Direct Scene Debugging**: Select and launch any `.tscn` file directly from Neovim
- 🔨 **Automatic Solution Building**: Builds Godot Mono solutions before launching
- 🔌 **DAP Integration**: Uses Debug Adapter Protocol with netcoredbg for C# debugging
- 💫 **Smart Notifications**: Beautiful notifications using [snacks.nvim](https://github.com/folke/snacks.nvim)
- 🔍 **Auto-detection**: Automatically detects Godot projects when launching DAP
- 📁 **Scene Memory**: Remembers your last selected scene for quick access
- 🛑 **Process Management**: Easily kill Godot processes and manage debug sessions

## Requirements

- Neovim >= 0.9.0
- [nvim-dap](https://github.com/mfussenegger/nvim-dap)
- [snacks.nvim](https://github.com/folke/snacks.nvim)
- [netcoredbg](https://github.com/Samsung/netcoredbg) (for C# debugging)
- Godot Engine with Mono support

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "jamesonBradfield/godot-debug.nvim",
  dependencies = {
    "mfussenegger/nvim-dap",
    "folke/snacks.nvim"
  },
  opts = {
    -- Your configuration options here
  },
  config = true,
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "jamesonBradfield/godot-debug.nvim",
  requires = {
    "mfussenegger/nvim-dap",
    "folke/snacks.nvim"
  },
  config = function()
    require("godot-debug").setup({
      -- Your configuration options here
    })
  end,
}
```

## Configuration

```lua
require("godot-debug").setup({
  -- Godot executable name (godot-mono on Linux/Mac, godot-mono.exe on Windows)
  godot_binary = "godot-mono",
  
  -- Directories to exclude when searching for scenes
  exclude_dirs = { "addons/", "src/" },
  
  -- Path to cache file for storing last selected scene
  scene_cache_file = vim.fn.stdpath("cache") .. "/godot_last_scene.txt",
  
  -- Enable debug mode for more verbose logging
  debug_mode = false,
  
  -- Automatically detect Godot projects when launching DAP
  auto_detect = true,
  
  -- Errors to ignore during build process
  ignore_build_errors = {
    "GdUnit.*Can't establish server.*Already in use",
    "Resource file not found: res://<.*Texture.*>",
  },
  
  -- Reuse existing Godot build output buffer
  buffer_reuse = true,
  
  -- Timeout for build process in seconds
  build_timeout = 60,
  
  -- Always show build output buffer
  show_build_output = true,
})
```

## Usage

### Commands

- `:GodotDebug` - Launch the Godot debug session
- `:GodotQuit` - Kill all Godot processes

### Manual Usage

```lua
-- Launch debug session manually
require("godot-debug").launch()

-- Set log level (0-4, where 0 is most verbose)
require("godot-debug").set_log_level(3)
```

### Workflow

1. Run `:GodotDebug` or call `require("godot-debug").launch()`
2. Select a scene from the picker (shows "Last: " options first)
3. Plugin builds Godot solutions automatically
4. Godot launches with the selected scene
5. Debugger automatically attaches to the Godot process
6. Set breakpoints and debug your C# scripts

### Auto-detection

When `auto_detect` is enabled (default), the plugin will automatically detect if you're in a Godot project and launch the Godot debugger when you run `:lua require('dap').continue()` instead of the standard DAP continue.

## DAP Configuration

The plugin automatically sets up DAP configurations for C# files:

```lua
{
  type = "godot_mono",
  request = "attach",
  name = "Attach to Godot Mono",
  processId = function()
    -- Automatically uses stored Godot PID or falls back to process picker
  end,
  justMyCode = false,
}
```

## Troubleshooting

### Common Issues

1. **"netcoredbg not found"**
   - Install netcoredbg: `brew install netcoredbg` (macOS) or download from releases
   - Ensure it's in your PATH

2. **"Build failed with errors"**
   - Check the "Godot Build Output" buffer for details
   - Some errors can be ignored (see `ignore_build_errors` config)

3. **Scene not launching**
   - Ensure `godot_binary` is correctly set in your configuration
   - Check that the project.godot file exists in your project root

### Debug Logs

Enable debug mode for more verbose logging:

```lua
require("godot-debug").setup({ debug_mode = true })
```

## Contributing

Feel free to open issues or pull requests on [GitHub](https://github.com/jamesonBradfield/godot-debug.nvim).

## License

MIT License - see LICENSE file for details

---

**Note**: This plugin is specifically designed for Godot Mono/C# projects. For GDScript debugging, you may need additional setup or a different plugin.
