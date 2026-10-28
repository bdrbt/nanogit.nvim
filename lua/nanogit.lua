-- lua/nanogit.lua
local M = {}

local uv = vim.uv or vim.loop

-- Public state. Internal repository paths and async bookkeeping stay private.
local state = { root = nil, branch = nil, detached = false, statuses = {} }

local repo = { git_dir = nil, common_dir = nil }

local subscribers = {}
local watchers = {}
local branch_ref_path = nil

local generation = 0
local refresh_timer = nil
local refresh_process = nil
local refreshing = false
local refresh_queued = false
local autocmds_installed = false

local function get_snapshot()
    local statuses = {}
    for path, status in pairs(state.statuses) do
        statuses[path] = status
    end

    return { root = state.root, branch = state.branch, detached = state.detached, statuses = statuses }
end

local function notify_subscribers()
    -- Treat the snapshot as read-only inside callbacks.
    local snapshot = get_snapshot()
    local callbacks = {}

    for i, callback in ipairs(subscribers) do
        callbacks[i] = callback
    end

    for _, callback in ipairs(callbacks) do
        local ok, err = xpcall(callback, debug.traceback, snapshot)
        if not ok then
            vim.notify("nanogit subscriber failed:\n" .. err, vim.log.levels.ERROR)
        end
    end
end

local function clear_state()
    state.root = nil
    state.branch = nil
    state.detached = false
    state.statuses = {}
end

local function close_handle(handle)
    if not handle or handle:is_closing() then
        return
    end

    pcall(handle.stop, handle)
    pcall(handle.close, handle)
end

local function stop_watchers()
    for path, handle in pairs(watchers) do
        close_handle(handle)
        watchers[path] = nil
    end
    branch_ref_path = nil
end

-- Invalidates every outstanding timer, process, watcher and callback.
local function invalidate_context()
    generation = generation + 1

    if refresh_timer then
        close_handle(refresh_timer)
        refresh_timer = nil
    end

    if refresh_process then
        pcall(refresh_process.kill, refresh_process, 15)
        refresh_process = nil
    end

    refreshing = false
    refresh_queued = false

    stop_watchers()

    return generation
end

local function run_git(args, cwd, callback)
    local ok, process_or_error = pcall(
        vim.system, args,
        {
            cwd = cwd,
            text = true,

            -- Avoid Git writing a refreshed index and retriggering our watcher.
            env = { GIT_OPTIONAL_LOCKS = "0" }
        },
        function (result)
            -- All state changes and subscriber calls happen on the main loop.
            vim.schedule(function ()
                callback(result)
            end)
        end
    )

    if not ok then
        vim.schedule(function ()
            callback({
                code = -1,
                stdout = "",
                stderr = tostring(process_or_error)
            })
        end)
        return nil
    end

    return process_or_error
end

local function report_git_error(result)
    local message = result.stderr

    if not message or message == "" then
        message = "git exited with code " .. tostring(result.code)
    end

    vim.notify("nanogit: " .. vim.trim(message), vim.log.levels.WARN)
end

local function watch_path(path)
    if not path or path == "" then
        return false
    end

    if watchers[path] then
        return true
    end

    local handle = uv.new_fs_event()
    if not handle then
        return false
    end

    local watcher_generation = generation

    local ok, started = pcall(handle.start, handle, path, {}, function (err)
        if err then
            return
        end

        vim.schedule(function ()
            if watcher_generation == generation and state.root then
                M.refresh()
            end
        end)
    end)

    if not ok or started == nil then
        close_handle(handle)
        return false
    end

    watchers[path] = handle
    return true
end

-- Watching the actual ref also handles nested branch names such as feature/foo.
local function update_branch_watcher(branch)
    local path = nil

    if branch and repo.common_dir then
        path = repo.common_dir .. "/refs/heads/" .. branch
    end

    if path == branch_ref_path and (not path or watchers[path]) then
        return
    end

    if branch_ref_path and watchers[branch_ref_path] then
        close_handle(watchers[branch_ref_path])
        watchers[branch_ref_path] = nil
    end

    branch_ref_path = nil

    if path and watch_path(path) then
        branch_ref_path = path
    end
end

local function split_nul(output)
    local records = {}
    local start = 1

    while start <= #output do
        local finish = output:find("\0", start, true)

        if not finish then
            records[#records + 1] = output:sub(start)
            break
        end

        records[#records + 1] = output:sub(start, finish - 1)
        start = finish + 1
    end

    return records
end

-- Convert porcelain-v2 XY codes to approximately the old module's format:
-- ".M" -> "M", "M." -> "M", "MM" -> "MM".
local function compact_status(xy)
    return (xy:gsub("%.", ""))
end

local function parse_status(output)
    local result = { branch = nil, detached = false, statuses = {} }

    local records = split_nul(output)
    local index = 1

    while index <= #records do
        local record = records[index]

        local head = record:match("^# branch%.head (.+)$")
        if head then
            if head == "(detached)" then
                result.branch = nil
                result.detached = true
            else
                result.branch = head
                result.detached = false
            end
        elseif record:sub(1, 2) == "1 " then
            -- 1 XY sub mH mI mW hH hI path
            local xy, path = record:match("^1 (%S+) %S+ %S+ %S+ %S+ %S+ %S+ (.+)$")

            if xy and path then
                result.statuses[path] = compact_status(xy)
            end
        elseif record:sub(1, 2) == "2 " then
            -- 2 XY sub mH mI mW hH hI Xscore path NUL origPath
            local xy, path = record:match("^2 (%S+) %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.+)$")

            if xy and path then
                result.statuses[path] = compact_status(xy)
            end

            -- With -z, the original pathname is the following NUL record.
            index = index + 1
        elseif record:sub(1, 2) == "u " then
            -- u XY sub m1 m2 m3 mW h1 h2 h3 path
            local xy, path = record:match("^u (%S+) %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.+)$")

            if xy and path then
                result.statuses[path] = compact_status(xy)
            end
        elseif record:sub(1, 2) == "? " then
            result.statuses[record:sub(3)] = "??"
        end

        index = index + 1
    end

    return result
end

local refresh_now

function M.refresh()
    if not state.root then
        return
    end

    if not refresh_timer then
        refresh_timer = uv.new_timer()
    end

    if not refresh_timer then
        return
    end

    local request_generation = generation

    refresh_timer:stop()
    refresh_timer:start(50, 0, function ()
        vim.schedule(function ()
            if request_generation == generation then
                refresh_now()
            end
        end)
    end)
end

refresh_now = function ()
    if not state.root then
        return
    end

    if refreshing then
        refresh_queued = true
        return
    end

    refreshing = true

    local request_generation = generation
    local request_root = state.root

    refresh_process = run_git({
        "git",
        "status",
        "--porcelain=v2",
        "-z",
        "--branch",
        "--untracked-files=all"
    },
        request_root, function (result)
            -- A response from an older repository/context must not be published.
            if request_generation ~= generation or request_root ~= state.root then
                return
            end

            refreshing = false
            refresh_process = nil

            if result.code ~= 0 then
                refresh_queued = false
                report_git_error(result)
                return
            end

            local parsed = parse_status(result.stdout or "")

            -- Replace the complete cache before notifying anyone.
            state.branch = parsed.branch
            state.detached = parsed.detached
            state.statuses = parsed.statuses

            update_branch_watcher(parsed.branch)
            notify_subscribers()

            if refresh_queued then
                refresh_queued = false
                M.refresh()
            end
        end)
end

local function absolute_path(path, cwd)
    path = vim.fs.normalize(path)

    if path:match("^/") or path:match("^%a:/") then
        return path
    end

    return vim.fs.normalize(cwd .. "/" .. path)
end

local function path_in_repo(path)
    if not state.root or not path or path == "" then
        return false
    end

    path = vim.fs.normalize(path)
    local root = vim.fs.normalize(state.root)
    local prefix = root:sub(-1) == "/" and root or root .. "/"

    return path == root or path:sub(1, #prefix) == prefix
end

local function install_autocmds()
    if autocmds_installed then
        return
    end

    autocmds_installed = true
    local group = vim.api.nvim_create_augroup("NanoGit", { clear = true })

    vim.api.nvim_create_autocmd("DirChanged", {
        group = group,
        callback = function ()
            M.init()
        end
    })

    vim.api.nvim_create_autocmd("BufWritePost", {
        group = group,
        callback = function (args)
            if path_in_repo(args.file) then
                M.refresh()
            end
        end
    })

    -- FocusGained catches many changes made outside Neovim.
    -- TermLeave catches Git commands run in an embedded terminal.
    vim.api.nvim_create_autocmd({ "FocusGained", "TermLeave" }, {
        group = group,
        callback = function ()
            if state.root then
                M.refresh()
            end
        end
    })
end

function M.init()
    install_autocmds()

    local request_generation = invalidate_context()
    local had_previous_state = state.root ~= nil

    repo.git_dir = nil
    repo.common_dir = nil
    clear_state()

    if had_previous_state then
        notify_subscribers()
    end

    local cwd = vim.fn.getcwd()

    run_git({
        "git",
        "rev-parse",
        "--show-toplevel",
        "--absolute-git-dir",
        "--git-common-dir"
    },
        cwd, function (result)
            if request_generation ~= generation then
                return
            end

            -- Usually means "not inside a Git repository".
            if result.code ~= 0 then
                return
            end

            local lines = {}
            for line in ((result.stdout or "") .. "\n"):gmatch("(.-)\r?\n") do
                lines[#lines + 1] = line
            end

            local root = lines[1]
            local git_dir = lines[2]
            local common_dir = lines[3]

            if not root or root == "" or not git_dir or git_dir == "" then
                return
            end

            root = vim.fs.normalize(root)
            git_dir = absolute_path(git_dir, cwd)
            common_dir = common_dir and common_dir ~= "" and absolute_path(common_dir, cwd) or git_dir

            state.root = root
            repo.git_dir = git_dir
            repo.common_dir = common_dir

            -- The Git directory catches index, HEAD and packed-refs changes.
            watch_path(git_dir)
            watch_path(common_dir)

            M.refresh()
        end)
end

function M.setup()
    M.init()
end

function M.on_update(callback)
    assert(type(callback) == "function", "callback must be a function")

    table.insert(subscribers, callback)

    return function ()
        for i, subscriber in ipairs(subscribers) do
            if subscriber == callback then
                table.remove(subscribers, i)
                return
            end
        end
    end
end

function M.get_state()
    return get_snapshot()
end

function M.stop()
    invalidate_context()

    repo.git_dir = nil
    repo.common_dir = nil

    local had_previous_state = state.root ~= nil
    clear_state()

    if had_previous_state then
        notify_subscribers()
    end
end

return M
