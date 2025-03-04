local M = {}

-- Configuration with sensible defaults
local config = {
  debug_port = 23685,
  debug_host = '127.0.0.1',
  godot_binary = vim.fn.has 'win32' == 1 and 'godot-mono.exe' or 'godot-mono',
  exclude_dirs = { 'addons/', 'src/' },
  scene_cache_file = vim.fn.stdpath 'cache' .. '/godot_last_scene.txt',
  debug_mode = false,
}

-- State tracking
local state = {
  in_progress = false,
}

-- Improved Logging function
local function log(msg, level, tag)
  level = level or vim.log.levels.INFO
  tag = tag or ''
  vim.notify('[Godot' .. tag .. '] ' .. msg, level)
end
-- Execute command with improved debugging
local function execute_command(cmd, opts, callback)
  opts = opts or {}
  local cmd_str = type(cmd) == 'table' and table.concat(cmd, ' ') or cmd
  log('Starting command: ' .. cmd_str, vim.log.levels.INFO, ':CMD')

  -- Create a unique execution ID for tracking this command's lifecycle
  local exec_id = tostring(math.random(1000000))

  -- Wrap callback with error handling and logging
  local safe_callback = nil
  if callback then
    safe_callback = vim.schedule_wrap(function(result, success, err)
      log('Callback triggered for cmd [' .. exec_id .. ']', vim.log.levels.INFO, ':CALLBACK')

      -- Log command results
      if success then
        log('Command succeeded [' .. exec_id .. ']', vim.log.levels.INFO, ':SUCCESS')
      else
        log('Command failed [' .. exec_id .. ']: ' .. (err or 'Unknown error'), vim.log.levels.ERROR, ':ERROR')
      end

      -- Call the original callback inside pcall to catch any errors
      local cb_status, cb_err = pcall(function()
        callback(result, success, err)
      end)

      if not cb_status then
        log('Error in callback [' .. exec_id .. ']: ' .. tostring(cb_err), vim.log.levels.ERROR, ':CB_ERROR')
      end
    end)
  end

  -- Use vim.system when available (Neovim 0.10+)
  if vim.system then
    log('Using vim.system [' .. exec_id .. ']', vim.log.levels.INFO, ':SYS')
    local cmd_array = type(cmd) == 'string' and (vim.fn.has 'win32' == 1 and { 'cmd.exe', '/c', cmd } or { 'sh', '-c', cmd }) or cmd

    local system_opts = {
      text = true,
      cwd = opts.cwd,
      detach = opts.detach,
    }

    local job = vim.system(cmd_array, system_opts, function(result)
      log('vim.system callback triggered [' .. exec_id .. ']', vim.log.levels.INFO, ':SYS_CB')

      if safe_callback then
        log('Calling safe_callback from vim.system [' .. exec_id .. ']', vim.log.levels.INFO, ':SYS_CB_CALL')
        safe_callback(result.stdout, result.code == 0, result.code ~= 0 and result.stderr or nil)
      end
    end)

    log('Job started [' .. exec_id .. ']: ' .. vim.inspect(job), vim.log.levels.INFO, ':JOB')
    return job

    -- Fall back to jobstart for older Neovim versions
  elseif vim.fn.exists '*jobstart' == 1 then
    log('Using jobstart [' .. exec_id .. ']', vim.log.levels.INFO, ':JOBSTART')
    local output = {}
    local stderr = {}
    local job_cmd = cmd_str

    local job_opts = {
      on_stdout = function(_, data)
        if data and #data > 0 then
          vim.list_extend(output, data)
        end
      end,
      on_stderr = function(_, data)
        if data and #data > 0 then
          vim.list_extend(stderr, data)
        end
      end,
      on_exit = function(_, code)
        log('jobstart on_exit triggered [' .. exec_id .. '] with code: ' .. code, vim.log.levels.INFO, ':JOBSTART_EXIT')

        if safe_callback then
          log('Calling safe_callback from jobstart [' .. exec_id .. ']', vim.log.levels.INFO, ':JOBSTART_CB_CALL')
          safe_callback(table.concat(output, '\n'), code == 0, code ~= 0 and table.concat(stderr, '\n') or nil)
        end
      end,
      stdout_buffered = true,
      stderr_buffered = true,
      detach = opts.detach or false,
    }

    if opts.cwd then
      job_opts.cwd = opts.cwd
    end

    local job_id = vim.fn.jobstart(job_cmd, job_opts)

    if job_id <= 0 then
      log('jobstart failed with code: ' .. job_id .. ' [' .. exec_id .. ']', vim.log.levels.ERROR, ':JOBSTART_FAIL')

      vim.schedule(function()
        if safe_callback then
          safe_callback(nil, false, 'Failed to start job (code: ' .. job_id .. ')')
        end
      end)
      return nil
    end

    log('jobstart succeeded with job_id: ' .. job_id .. ' [' .. exec_id .. ']', vim.log.levels.INFO, ':JOBSTART_SUCCESS')

    return {
      id = job_id,
      stop = function()
        vim.fn.jobstop(job_id)
      end,
    }

    -- Last resort: io.popen
  else
    log('Using io.popen [' .. exec_id .. ']', vim.log.levels.INFO, ':POPEN')

    vim.schedule(function()
      local handle = io.popen(cmd_str .. ' 2>&1', 'r')
      if not handle then
        log('io.popen failed to open pipe [' .. exec_id .. ']', vim.log.levels.ERROR, ':POPEN_FAIL')

        if safe_callback then
          safe_callback(nil, false, 'Failed to open pipe')
        end
        return
      end

      local result = handle:read '*a'
      local success = handle:close()

      log('io.popen completed [' .. exec_id .. ']', vim.log.levels.INFO, ':POPEN_DONE')

      if safe_callback then
        safe_callback(result, success or false)
      end
    end)

    return nil
  end
end

-- Find scenes in current project
local function get_filtered_scenes(callback)
  local find_cmd

  if vim.fn.has 'win32' == 1 then
    find_cmd = 'powershell -Command "Get-ChildItem -Path . -Filter *.tscn -Recurse | Select-Object -ExpandProperty FullName"'
  else
    find_cmd = 'find "' .. vim.fn.getcwd() .. '" -name "*.tscn"'
  end

  execute_command(find_cmd, {}, function(result, success, err)
    if not success or not result or result == '' then
      log('Failed to find scene files: ' .. (err or 'No output'), vim.log.levels.ERROR)
      callback(nil, 'Failed to find scenes')
      return
    end

    local scenes = {}
    -- Split by newlines in a cross-platform way
    for scene in string.gmatch(result, '[^\r\n]+') do
      local should_exclude = false
      for _, dir in ipairs(config.exclude_dirs) do
        if string.find(scene, dir, 1, true) then
          should_exclude = true
          break
        end
      end

      if not should_exclude then
        table.insert(scenes, scene)
      end
    end

    if #scenes == 0 then
      log('No scenes found in project', vim.log.levels.ERROR)
      callback(nil, 'No scenes found')
    else
      callback(scenes)
    end
  end)
end

-- Build Godot solutions with improved logging
local function build_godot_solutions(callback)
  log('Building Godot solutions...', vim.log.levels.INFO, ':BUILD')

  local cmd = { config.godot_binary, '--headless', '--build-solutions' }

  log('Calling execute_command for build', vim.log.levels.INFO, ':BUILD_CMD')

  execute_command(cmd, {}, function(result, success, err)
    log('Build command completed callback received', vim.log.levels.INFO, ':BUILD_CB')

    -- Debug output
    log('Result: ' .. (result and #result or 'nil') .. ' chars', vim.log.levels.INFO, ':BUILD_RESULT')
    log('Success: ' .. tostring(success), vim.log.levels.INFO, ':BUILD_SUCCESS')
    log('Error: ' .. tostring(err or 'none'), vim.log.levels.INFO, ':BUILD_ERROR')

    if success then
      log('Build completed successfully', vim.log.levels.INFO, ':BUILD_OK')
      if callback then
        log('Calling success callback from build', vim.log.levels.INFO, ':BUILD_CB_OK')
        callback(true)
      end
    else
      -- Extract error message if possible
      local error_msg = 'Build failed'

      if result then
        -- Look for common error patterns
        for line in result:gmatch '[^\r\n]+' do
          if line:match 'Error:' or line:match 'error CS%d+:' then
            error_msg = error_msg .. ': ' .. line
            break
          end
        end
      end

      log(error_msg, vim.log.levels.ERROR, ':BUILD_FAIL')
      if callback then
        log('Calling fail callback from build', vim.log.levels.INFO, ':BUILD_CB_FAIL')
        callback(false, error_msg)
      end
    end
  end)

  log('build_godot_solutions function completed (async operation started)', vim.log.levels.INFO, ':BUILD_FUNC_END')
end

-- Kill Godot processes
local function kill_godot_processes(callback)
  local kill_cmd

  if vim.fn.has 'win32' == 1 then
    kill_cmd = 'taskkill /F /IM ' .. config.godot_binary .. ' 2>nul'
  else
    kill_cmd = 'pkill -f "' .. config.godot_binary .. '" 2>/dev/null'
  end

  execute_command(kill_cmd, {}, function()
    -- Wait a bit to ensure processes are killed
    vim.defer_fn(function()
      if callback then
        callback()
      end
    end, 300)
  end)
end

-- Scene selection with snacks.nvim
local function pick_godot_scene(callback)
  -- Check if snacks.nvim is available
  local has_snacks = package.loaded['snacks'] ~= nil or pcall(require, 'snacks')

  if not has_snacks then
    log('snacks.nvim is not available. Please install it.', vim.log.levels.ERROR)
    if callback then
      callback(nil, 'Snacks plugin not available')
    end
    return
  end

  -- Find scenes and present picker
  get_filtered_scenes(function(scenes, err)
    if not scenes then
      log(err or 'Failed to get scenes', vim.log.levels.ERROR)
      if callback then
        callback(nil, err)
      end
      return
    end

    -- Load cached scene if available
    local last_scene = nil
    local cache_file = config.scene_cache_file

    if vim.fn.filereadable(cache_file) == 1 then
      local cached_scene = vim.fn.readfile(cache_file, '', 1)[1]
      if vim.fn.filereadable(cached_scene) == 1 then
        last_scene = cached_scene
      end
    end

    local items = {}

    -- Add last scene first if available
    if last_scene then
      table.insert(items, {
        text = '↻ Last: ' .. vim.fn.fnamemodify(last_scene, ':.'),
        file = last_scene,
        is_last = true,
      })
    end

    -- Add all scenes
    for _, scene in ipairs(scenes) do
      if scene ~= last_scene then
        table.insert(items, {
          text = vim.fn.fnamemodify(scene, ':.'),
          file = scene,
        })
      end
    end

    -- Sort scenes alphabetically (except the last scene)
    table.sort(items, function(a, b)
      if a.is_last then
        return true
      end
      if b.is_last then
        return false
      end
      return a.text < b.text
    end)

    log('Found ' .. #items .. ' scene(s)')

    -- Show picker
    vim.schedule(function()
      local Snacks = require 'snacks'

      Snacks.picker.pick {
        source = 'select',
        title = 'Select Godot Scene',
        items = items,
        confirm = function(picker, item)
          picker:close()

          if not item or not item.file then
            log('No scene selected', vim.log.levels.ERROR)
            if callback then
              callback(nil, 'No scene selected')
            end
            return
          end

          -- Save selection for next time
          vim.fn.writefile({ item.file }, config.scene_cache_file)

          log('Selected scene: ' .. vim.fn.fnamemodify(item.file, ':.'))
          if callback then
            callback(item.file)
          end
        end,
      }
    end)
  end)
end

-- Launch Godot with debug server
local function start_godot_with_scene(scene_path, callback)
  log('Starting Godot with scene: ' .. vim.fn.fnamemodify(scene_path, ':.'))

  -- Kill any existing Godot processes first
  kill_godot_processes(function()
    local cwd = vim.fn.fnamemodify(scene_path, ':h')
    local debug_uri = 'tcp://' .. config.debug_host .. ':' .. config.debug_port

    local cmd = {
      config.godot_binary,
      '--path',
      cwd,
      '--debug-server',
      debug_uri,
      scene_path,
    }

    -- Start Godot with debug server
    local launched_job = execute_command(cmd, {
      detach = true,
      cwd = cwd,
    }, function(_, success, err)
      if not success then
        log('Failed to start Godot process: ' .. (err or ''), vim.log.levels.ERROR)
        if callback then
          callback(nil, 'Launch failed')
        end
        return
      end
    end)

    -- Get PID if available
    local pid = nil
    if launched_job and launched_job.pid then
      pid = launched_job.pid
    else
      -- If we can't get the PID, use a dummy value
      pid = -1
    end

    -- Wait a moment for debug server to initialize
    vim.defer_fn(function()
      log 'Godot process started, connecting debugger'
      if callback then
        callback(pid)
      end
    end, 1000)
  end)
end

-- Main launch function
function M.launch()
  if state.in_progress then
    log('Debug session already in progress', vim.log.levels.WARN)
    return
  end

  state.in_progress = true

  log 'Starting debug session...'

  -- Step 1: Build Godot solutions
  build_godot_solutions(function(build_success, build_error)
    if not build_success then
      state.in_progress = false
      log('Debug session aborted: ' .. (build_error or 'Build failed'), vim.log.levels.ERROR)
      return
    end

    -- Step 2: Select scene
    pick_godot_scene(function(scene_path, scene_error)
      if not scene_path then
        state.in_progress = false
        log('Debug session aborted: ' .. (scene_error or 'No scene selected'), vim.log.levels.ERROR)
        return
      end

      -- Step 3: Launch Godot
      start_godot_with_scene(scene_path, function(pid, launch_error)
        if not pid then
          state.in_progress = false
          log('Debug session aborted: ' .. (launch_error or 'Failed to launch'), vim.log.levels.ERROR)
          return
        end

        -- Step 4: Connect debugger and continue
        log('Attaching debugger to PID: ' .. pid)

        local dap = require 'dap'

        dap.run {
          type = 'godot_mono',
          request = 'attach',
          name = 'Attach to Godot Mono',
          processId = pid,
          address = config.debug_host,
          port = config.debug_port,
          justMyCode = false,
        }

        -- Automatically continue after attaching
        vim.defer_fn(function()
          dap.continue()
          state.in_progress = false
          log 'Debug session started'
        end, 500)
      end)
    end)
  end)
end

-- Setup function
function M.setup(user_config)
  -- Apply user configuration
  if user_config then
    for k, v in pairs(user_config) do
      config[k] = v
    end
  end

  -- Configure DAP adapter
  local dap = require 'dap'

  dap.adapters.godot_mono = function(callback, adapter_config)
    if adapter_config.request == 'attach' then
      callback {
        type = 'server',
        host = adapter_config.address or config.debug_host,
        port = adapter_config.port or config.debug_port,
      }
    else
      log('Godot Mono adapter only supports attach mode', vim.log.levels.ERROR)
      callback {
        type = 'server',
        host = config.debug_host,
        port = 0,
        error = 'Invalid request type',
      }
    end
  end

  -- Register DAP configuration
  dap.configurations.gdscript = {
    {
      type = 'godot_mono',
      request = 'attach',
      name = 'Attach to Godot Mono',
      address = config.debug_host,
      port = config.debug_port,
      justMyCode = false,
    },
  }

  -- Also register for C# files
  dap.configurations.cs = dap.configurations.gdscript

  return M
end

return M
