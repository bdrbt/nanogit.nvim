-- lua/nanogit.lua
local M = {}

-- Состояние демона
local state = {
    root = nil,
    branch = nil,
    statuses = {}, -- ключ: относительный путь к файлу, значение: git статус (например, "M", "A", "??")
    subscribers = {},
    fs_event = nil,
}

-- Асинхронный запуск git команд через встроенный vim.system (работает без блокировок UI)
local function run_git(args, callback)
    if not state.root then return end
    vim.system(args, { text = true, cwd = state.root }, function(obj)
        if obj.code == 0 then
            callback(obj.stdout)
        end
    end)
end

-- Обновление кэша (вызывается либо при старте, либо по сигналу от файловой системы)
local function update_git_state()
    if not state.root then return end

    -- 1. Получаем текущую ветку
    run_git({ "git", "branch", "--show-current" }, function(out)
        state.branch = out:gsub("%s+", "")
    end)

    -- 2. Получаем porcelain статус файлов
    run_git({ "git", "status", "--porcelain" }, function(out)
        state.statuses = {}
        for line in out:gmatch("[^\r\n]+") do
            local status = line:sub(1, 2):gsub("%s+", "")
            local file = line:sub(4)
            state.statuses[file] = status
        end

        -- 3. Уведомляем всех подписчиков (безопасно через vim.schedule)
        vim.schedule(function()
            for _, cb in ipairs(state.subscribers) do
                pcall(cb, state)
            end
        end)
    end)
end

-- Инициализация или переключение контекста на новый репозиторий
function M.init()
    -- Быстро проверяем, находимся ли мы в git-репозитории
    local handle = io.popen("git rev-parse --show-toplevel 2>/dev/null")
    if not handle then return end
    local root = handle:read("*a"):gsub("%s+", "")
    handle:close()

    if root == "" then
        state.root = nil
        state.branch = nil
        state.statuses = {}
        return
    end

    -- Если корень поменялся — переподписываем watcher
    if state.root ~= root then
        state.root = root

        -- Останавливаем старый watcher, если он был
        if state.fs_event then
            state.fs_event:stop()
            state.fs_event = nil
        end

        -- Запускаем слежку за .git/index через libuv (реагирует на изменения файлов / коммиты)
        local git_index = root .. "/.git/index"
        local uv = vim.uv or vim.loop
        local fs_event = uv.new_fs_event()

        if fs_event then
            fs_event:start(git_index, {}, function(err, fname, events)
                if not err then
                    -- Дебаунс или прямой вызов обновления при изменении индекса
                    update_git_state()
                end
            end)
            state.fs_event = fs_event
        end
    end

    -- Initialize cache
    update_git_state()
end

-- Changes subscription
function M.on_update(cb)
    table.insert(state.subscribers, cb)
end

-- Мгновенное чтение кэша из памяти без блокировки диска
function M.get_state()
    return state
end

return M
