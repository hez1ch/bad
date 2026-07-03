-- ============================================================
--  BAD (Basic Archive Downloader) - пакетный менеджер для
--  компьютеров CC: Tweaked
--
--  Установка (на компьютере в игре):
--    pastebin get <код> bad         -- если вы выложите файл на pastebin
--  или просто скопируйте этот файл через дискету/HTTP.
--
--  Использование:
--    bad update              - обновить индекс пакетов со всех репозиториев
--    bad install <pkg> [...] - установить один или несколько пакетов
--    bad remove  <pkg> [...] - удалить пакет(ы)
--    bad list                - список установленных пакетов
--    bad search  <текст>     - поиск пакета по имени/описанию
--    bad info    <pkg>       - подробная информация о пакете
--    bad repo add <url>      - добавить репозиторий (ссылка на packages.json)
--    bad repo remove <url>   - удалить репозиторий
--    bad repo list           - показать репозитории
--    bad upgrade             - обновить все установленные пакеты
-- ============================================================

local BAD_DIR      = "/.bad"
local CONFIG_FILE  = BAD_DIR .. "/config.json"
local INDEX_FILE   = BAD_DIR .. "/index.json"
local INSTALLED_FILE = BAD_DIR .. "/installed.json"
local BIN_DIR      = "/bin"

-- ---------------------------------------------------------------
-- Утилиты
-- ---------------------------------------------------------------

local function ensureDirs()
  if not fs.exists(BAD_DIR) then fs.makeDir(BAD_DIR) end
  if not fs.exists(BIN_DIR) then fs.makeDir(BIN_DIR) end
end

local function readJSON(path, default)
  if not fs.exists(path) then return default end
  local h = fs.open(path, "r")
  local content = h.readAll()
  h.close()
  if content == nil or content == "" then return default end
  local ok, data = pcall(textutils.unserializeJSON, content)
  if not ok or data == nil then return default end
  return data
end

local function writeJSON(path, data)
  local h = fs.open(path, "w")
  h.write(textutils.serializeJSON(data))
  h.close()
end

local function defaultConfig()
  return {
    repos = {
      -- Замените на свой репозиторий (см. README) или добавьте свой
      -- командой: bad repo add <url_к_packages.json>
      "https://raw.githubusercontent.com/hez1ch/bad/main/packages.json"
    }
  }
end

local function loadConfig()
  return readJSON(CONFIG_FILE, defaultConfig())
end

local function saveConfig(cfg)
  writeJSON(CONFIG_FILE, cfg)
end

local function loadIndex()
  return readJSON(INDEX_FILE, {})
end

local function saveIndex(idx)
  writeJSON(INDEX_FILE, idx)
end

local function loadInstalled()
  return readJSON(INSTALLED_FILE, {})
end

local function saveInstalled(list)
  writeJSON(INSTALLED_FILE, list)
end

local function printColor(text, color)
  if term.isColor and term.isColor() then
    local old = term.getTextColor()
    term.setTextColor(color)
    print(text)
    term.setTextColor(old)
  else
    print(text)
  end
end

local function errorMsg(text)
  printColor("[bad] Ошибка: " .. text, colors and colors.red or nil)
end

local function infoMsg(text)
  printColor("[bad] " .. text, colors and colors.lightBlue or nil)
end

local function okMsg(text)
  printColor("[bad] " .. text, colors and colors.lime or nil)
end

-- ---------------------------------------------------------------
-- HTTP
-- ---------------------------------------------------------------

local function httpGet(url)
  if not http then
    errorMsg("HTTP API отключён на этом компьютере (ConfigCraft: http.enabled).")
    return nil
  end
  local ok, resp = pcall(http.get, url)
  if not ok or resp == nil then
    errorMsg("Не удалось загрузить: " .. url)
    return nil
  end
  local body = resp.readAll()
  resp.close()
  return body
end

-- ---------------------------------------------------------------
-- Работа с индексом (update)
-- ---------------------------------------------------------------

local function cmdUpdate()
  local cfg = loadConfig()
  if #cfg.repos == 0 then
    errorMsg("Нет ни одного репозитория. Добавьте: bad repo add <url>")
    return
  end

  local merged = {}
  local okAny = false

  for _, repoUrl in ipairs(cfg.repos) do
    infoMsg("Загрузка индекса: " .. repoUrl)
    local body = httpGet(repoUrl)
    if body then
      local ok, data = pcall(textutils.unserializeJSON, body)
      if ok and data and data.packages then
        local count = 0
        for name, pkg in pairs(data.packages) do
          pkg.repo = repoUrl
          merged[name] = pkg
          count = count + 1
        end
        okAny = true
        okMsg("Найдено пакетов: " .. count)
      else
        errorMsg("Некорректный формат индекса: " .. repoUrl)
      end
    end
  end

  if okAny then
    saveIndex(merged)
    okMsg("Индекс пакетов обновлён.")
  else
    errorMsg("Не удалось обновить ни один индекс.")
  end
end

-- ---------------------------------------------------------------
-- install / remove
-- ---------------------------------------------------------------

local function resolvePackage(name)
  local idx = loadIndex()
  return idx[name]
end

local function installOne(name, seen)
  seen = seen or {}
  if seen[name] then return true end
  seen[name] = true

  local installed = loadInstalled()
  if installed[name] then
    infoMsg("Пакет '" .. name .. "' уже установлен (v" .. tostring(installed[name].version) .. "). Пропуск.")
    return true
  end

  local pkg = resolvePackage(name)
  if not pkg then
    errorMsg("Пакет '" .. name .. "' не найден в индексе. Выполните: bad update")
    return false
  end

  -- зависимости
  if pkg.depends then
    for _, dep in ipairs(pkg.depends) do
      infoMsg("Требуется зависимость: " .. dep)
      if not installOne(dep, seen) then
        errorMsg("Не удалось установить зависимость '" .. dep .. "' для '" .. name .. "'")
        return false
      end
    end
  end

  infoMsg("Установка '" .. name .. "' (v" .. tostring(pkg.version) .. ")...")

  local files = pkg.files
  if not files or #files == 0 then
    errorMsg("У пакета '" .. name .. "' не указаны файлы.")
    return false
  end

  local writtenFiles = {}
  for _, f in ipairs(files) do
    local body = httpGet(f.url)
    if not body then
      -- откат уже записанных файлов
      for _, wf in ipairs(writtenFiles) do
        if fs.exists(wf) then fs.delete(wf) end
      end
      return false
    end
    local path = f.path
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then
      fs.makeDir(dir)
    end
    local h = fs.open(path, "w")
    h.write(body)
    h.close()
    table.insert(writtenFiles, path)
  end

  installed[name] = {
    version = pkg.version,
    files = writtenFiles,
    installedAt = os.epoch and os.epoch("utc") or os.time()
  }
  saveInstalled(installed)
  okMsg("Пакет '" .. name .. "' установлен.")
  return true
end

local function cmdInstall(args)
  if #args == 0 then
    errorMsg("Укажите имя пакета: bad install <pkg>")
    return
  end
  for _, name in ipairs(args) do
    installOne(name)
  end
end

local function cmdRemove(args)
  if #args == 0 then
    errorMsg("Укажите имя пакета: bad remove <pkg>")
    return
  end
  local installed = loadInstalled()
  for _, name in ipairs(args) do
    local entry = installed[name]
    if not entry then
      errorMsg("Пакет '" .. name .. "' не установлен.")
    else
      for _, path in ipairs(entry.files) do
        if fs.exists(path) then
          fs.delete(path)
        end
      end
      installed[name] = nil
      okMsg("Пакет '" .. name .. "' удалён.")
    end
  end
  saveInstalled(installed)
end

local function cmdUpgrade()
  local installed = loadInstalled()
  local idx = loadIndex()
  local any = false
  for name, entry in pairs(installed) do
    local pkg = idx[name]
    if pkg and pkg.version ~= entry.version then
      infoMsg("Обновление '" .. name .. "': " .. tostring(entry.version) .. " -> " .. tostring(pkg.version))
      -- удаляем старые файлы и ставим заново
      for _, path in ipairs(entry.files) do
        if fs.exists(path) then fs.delete(path) end
      end
      installed[name] = nil
      saveInstalled(installed)
      installOne(name)
      any = true
    end
  end
  if not any then
    okMsg("Все пакеты уже последних версий.")
  end
end

-- ---------------------------------------------------------------
-- list / search / info
-- ---------------------------------------------------------------

local function cmdList()
  local installed = loadInstalled()
  local count = 0
  for name, entry in pairs(installed) do
    print(name .. "  (v" .. tostring(entry.version) .. ")")
    count = count + 1
  end
  if count == 0 then
    infoMsg("Установленных пакетов нет.")
  end
end

local function cmdSearch(args)
  local query = table.concat(args, " "):lower()
  if query == "" then
    errorMsg("Укажите текст для поиска: bad search <текст>")
    return
  end
  local idx = loadIndex()
  local found = 0
  for name, pkg in pairs(idx) do
    local desc = pkg.description or ""
    if name:lower():find(query, 1, true) or desc:lower():find(query, 1, true) then
      print(name .. " (v" .. tostring(pkg.version) .. ") - " .. desc)
      found = found + 1
    end
  end
  if found == 0 then
    infoMsg("Ничего не найдено.")
  end
end

local function cmdInfo(args)
  local name = args[1]
  if not name then
    errorMsg("Укажите имя пакета: bad info <pkg>")
    return
  end
  local pkg = resolvePackage(name)
  if not pkg then
    errorMsg("Пакет '" .. name .. "' не найден в индексе.")
    return
  end
  print("Имя:        " .. name)
  print("Версия:     " .. tostring(pkg.version))
  print("Описание:   " .. tostring(pkg.description))
  print("Автор:      " .. tostring(pkg.author))
  if pkg.depends and #pkg.depends > 0 then
    print("Зависимости: " .. table.concat(pkg.depends, ", "))
  end
  local installed = loadInstalled()
  if installed[name] then
    print("Статус:     установлен (v" .. tostring(installed[name].version) .. ")")
  else
    print("Статус:     не установлен")
  end
end

-- ---------------------------------------------------------------
-- repo
-- ---------------------------------------------------------------

local function cmdRepo(args)
  local sub = args[1]
  local cfg = loadConfig()

  if sub == "add" then
    local url = args[2]
    if not url then
      errorMsg("Укажите URL: bad repo add <url>")
      return
    end
    for _, r in ipairs(cfg.repos) do
      if r == url then
        infoMsg("Репозиторий уже добавлен.")
        return
      end
    end
    table.insert(cfg.repos, url)
    saveConfig(cfg)
    okMsg("Репозиторий добавлен: " .. url)

  elseif sub == "remove" then
    local url = args[2]
    if not url then
      errorMsg("Укажите URL: bad repo remove <url>")
      return
    end
    local newRepos = {}
    local removed = false
    for _, r in ipairs(cfg.repos) do
      if r ~= url then
        table.insert(newRepos, r)
      else
        removed = true
      end
    end
    cfg.repos = newRepos
    saveConfig(cfg)
    if removed then
      okMsg("Репозиторий удалён.")
    else
      errorMsg("Такой репозиторий не найден.")
    end

  elseif sub == "list" then
    if #cfg.repos == 0 then
      infoMsg("Репозитории не настроены.")
    end
    for _, r in ipairs(cfg.repos) do
      print(r)
    end

  else
    errorMsg("Использование: bad repo <add|remove|list> [url]")
  end
end

-- ---------------------------------------------------------------
-- help
-- ---------------------------------------------------------------

local function cmdHelp()
  print("BAD - Basic Archive Downloader (пакетный менеджер)")
  print("")
  print("Команды:")
  print("  bad update              - обновить индекс пакетов")
  print("  bad install <pkg...>    - установить пакет(ы)")
  print("  bad remove  <pkg...>    - удалить пакет(ы)")
  print("  bad upgrade             - обновить установленные пакеты")
  print("  bad list                - список установленных пакетов")
  print("  bad search  <текст>     - поиск пакета")
  print("  bad info    <pkg>       - информация о пакете")
  print("  bad repo add|remove|list [url] - управление репозиториями")
end

-- ---------------------------------------------------------------
-- main
-- ---------------------------------------------------------------

local function main(...)
  ensureDirs()
  local args = {...}
  local cmd = args[1]

  if not cmd or cmd == "help" then
    cmdHelp()
    return
  end

  table.remove(args, 1)

  if cmd == "update" then cmdUpdate()
  elseif cmd == "install" then cmdInstall(args)
  elseif cmd == "remove" then cmdRemove(args)
  elseif cmd == "upgrade" then cmdUpgrade()
  elseif cmd == "list" then cmdList()
  elseif cmd == "search" then cmdSearch(args)
  elseif cmd == "info" then cmdInfo(args)
  elseif cmd == "repo" then cmdRepo(args)
  else
    errorMsg("Неизвестная команда: " .. cmd)
    cmdHelp()
  end
end

main(...)
