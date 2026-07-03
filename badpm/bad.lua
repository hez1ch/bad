-- ============================================================
--  BAD (Basic Archive Downloader) - package manager for
--  CC: Tweaked computers
--
--  Repository: https://github.com/hez1ch/bad
--
--  Usage:
--    bad update              - refresh package index from all repos
--    bad install <pkg> [...] - install one or more packages
--    bad remove  <pkg> [...] - remove package(s)
--    bad list                - list installed packages
--    bad search  <text>      - search packages by name/description
--    bad info    <pkg>       - show detailed package info
--    bad repo add <url>      - add a repository (link to packages.json)
--    bad repo remove <url>   - remove a repository
--    bad repo list           - show configured repositories
--    bad upgrade             - upgrade all installed packages
-- ============================================================

local BAD_DIR         = "/.bad"
local CONFIG_FILE     = BAD_DIR .. "/config.json"
local INDEX_FILE      = BAD_DIR .. "/index.json"
local INSTALLED_FILE  = BAD_DIR .. "/installed.json"
local BIN_DIR         = "/bin"

-- ---------------------------------------------------------------
-- Utilities
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
      "https://raw.githubusercontent.com/hez1ch/bad/main/repo/packages.json"
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
  printColor("[bad] Error: " .. text, colors and colors.red or nil)
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
    errorMsg("HTTP API is disabled on this computer (server config: http.enabled).")
    return nil
  end
  local ok, resp = pcall(http.get, url)
  if not ok or resp == nil then
    errorMsg("Failed to download: " .. url)
    return nil
  end
  local body = resp.readAll()
  resp.close()
  return body
end

-- ---------------------------------------------------------------
-- Index handling (update)
-- ---------------------------------------------------------------

local function cacheBust(url)
  local sep = url:find("?", 1, true) and "&" or "?"
  return url .. sep .. "_=" .. tostring(os.epoch and os.epoch("utc") or os.time())
end

local function cmdUpdate()
  local cfg = loadConfig()
  if #cfg.repos == 0 then
    errorMsg("No repositories configured. Add one with: bad repo add <url>")
    return
  end

  local merged = {}
  local okAny = false

  for _, repoUrl in ipairs(cfg.repos) do
    infoMsg("Fetching index: " .. repoUrl)
    local body = httpGet(cacheBust(repoUrl))
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
        okMsg("Found packages: " .. count)
      else
        errorMsg("Invalid index format: " .. repoUrl)
      end
    end
  end

  if okAny then
    saveIndex(merged)
    okMsg("Package index updated.")
  else
    errorMsg("Could not update any index.")
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
    infoMsg("Package '" .. name .. "' is already installed (v" .. tostring(installed[name].version) .. "). Skipping.")
    return true
  end

  local pkg = resolvePackage(name)
  if not pkg then
    errorMsg("Package '" .. name .. "' not found in index. Run: bad update")
    return false
  end

  -- dependencies
  if pkg.depends then
    for _, dep in ipairs(pkg.depends) do
      infoMsg("Dependency required: " .. dep)
      if not installOne(dep, seen) then
        errorMsg("Failed to install dependency '" .. dep .. "' for '" .. name .. "'")
        return false
      end
    end
  end

  infoMsg("Installing '" .. name .. "' (v" .. tostring(pkg.version) .. ")...")

  local files = pkg.files
  if not files or #files == 0 then
    errorMsg("Package '" .. name .. "' has no files listed.")
    return false
  end

  local writtenFiles = {}
  for _, f in ipairs(files) do
    local body = httpGet(f.url)
    if not body then
      -- roll back already written files
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
  okMsg("Package '" .. name .. "' installed.")
  return true
end

local function cmdInstall(args)
  if #args == 0 then
    errorMsg("Specify a package name: bad install <pkg>")
    return
  end
  for _, name in ipairs(args) do
    installOne(name)
  end
end

local function cmdRemove(args)
  if #args == 0 then
    errorMsg("Specify a package name: bad remove <pkg>")
    return
  end
  local installed = loadInstalled()
  for _, name in ipairs(args) do
    local entry = installed[name]
    if not entry then
      errorMsg("Package '" .. name .. "' is not installed.")
    else
      for _, path in ipairs(entry.files) do
        if fs.exists(path) then
          fs.delete(path)
        end
      end
      installed[name] = nil
      okMsg("Package '" .. name .. "' removed.")
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
      infoMsg("Upgrading '" .. name .. "': " .. tostring(entry.version) .. " -> " .. tostring(pkg.version))
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
    okMsg("All packages are already up to date.")
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
    infoMsg("No packages installed.")
  end
end

local function cmdSearch(args)
  local query = table.concat(args, " "):lower()
  if query == "" then
    errorMsg("Specify search text: bad search <text>")
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
    infoMsg("No matches found.")
  end
end

local function cmdInfo(args)
  local name = args[1]
  if not name then
    errorMsg("Specify a package name: bad info <pkg>")
    return
  end
  local pkg = resolvePackage(name)
  if not pkg then
    errorMsg("Package '" .. name .. "' not found in index.")
    return
  end
  print("Name:        " .. name)
  print("Version:     " .. tostring(pkg.version))
  print("Description: " .. tostring(pkg.description))
  print("Author:      " .. tostring(pkg.author))
  if pkg.depends and #pkg.depends > 0 then
    print("Depends:     " .. table.concat(pkg.depends, ", "))
  end
  local installed = loadInstalled()
  if installed[name] then
    print("Status:      installed (v" .. tostring(installed[name].version) .. ")")
  else
    print("Status:      not installed")
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
      errorMsg("Specify a URL: bad repo add <url>")
      return
    end
    for _, r in ipairs(cfg.repos) do
      if r == url then
        infoMsg("Repository already added.")
        return
      end
    end
    table.insert(cfg.repos, url)
    saveConfig(cfg)
    okMsg("Repository added: " .. url)

  elseif sub == "remove" then
    local url = args[2]
    if not url then
      errorMsg("Specify a URL: bad repo remove <url>")
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
      okMsg("Repository removed.")
    else
      errorMsg("Repository not found.")
    end

  elseif sub == "list" then
    if #cfg.repos == 0 then
      infoMsg("No repositories configured.")
    end
    for _, r in ipairs(cfg.repos) do
      print(r)
    end

  else
    errorMsg("Usage: bad repo <add|remove|list> [url]")
  end
end

-- ---------------------------------------------------------------
-- help
-- ---------------------------------------------------------------

local function cmdHelp()
  print("BAD - Basic Archive Downloader (package manager)")
  print("")
  print("Commands:")
  print("  bad update              - refresh package index")
  print("  bad install <pkg...>    - install package(s)")
  print("  bad remove  <pkg...>    - remove package(s)")
  print("  bad upgrade             - upgrade installed packages")
  print("  bad list                - list installed packages")
  print("  bad search  <text>      - search for a package")
  print("  bad info    <pkg>       - show package info")
  print("  bad repo add|remove|list [url] - manage repositories")
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
    errorMsg("Unknown command: " .. cmd)
    cmdHelp()
  end
end

main(...)
