-- ============================================================
--  BAD (Basic Archive Downloader) - package manager for
--  CC: Tweaked computers
--
--  Repository: https://github.com/hez1ch/bad
--
--  Usage:
--    bad update                 - refresh package index from all repos
--    bad install <pkg> [...]    - install one or more packages
--    bad reinstall <pkg> [...]  - force re-download/reinstall package(s)
--    bad remove  <pkg> [...] [--force]
--                                - remove package(s) (blocks if something
--                                  else depends on it, unless --force)
--    bad list                   - list installed packages
--    bad search  <text>         - search packages by name/description
--    bad info    <pkg>          - show detailed package info
--    bad depends <pkg>          - show a package's deps + reverse deps
--    bad outdated                - list installed packages with a newer
--                                  version available in the index
--    bad upgrade [pkg ...]      - upgrade all packages, or only the
--                                  ones named
--    bad autoremove             - remove auto-installed dependencies
--                                  that nothing needs anymore
--    bad clean                  - clear the cached package index
--    bad repo add <url>         - add a repository (link to packages.json)
--    bad repo remove <url>      - remove a repository
--    bad repo list              - show configured repositories
--    bad gui                    - launch a clickable/tappable menu
--                                  UI, mirrored to any attached
--                                  monitor peripheral(s)
--    bad version                - show BAD's own version
-- ============================================================

local BAD_VERSION     = "2.0.0"

local BAD_DIR         = "/.bad"
local CONFIG_FILE     = BAD_DIR .. "/config.json"
local INDEX_FILE      = BAD_DIR .. "/index.json"
local INSTALLED_FILE  = BAD_DIR .. "/installed.json"
local META_FILE       = BAD_DIR .. "/meta.json"
local BIN_DIR         = "/bin"

-- ---------------------------------------------------------------
-- Optional shared monitor-mirroring library (see /lib/monitor.lua).
-- BAD works perfectly fine without it (e.g. if bad.lua was pasted
-- in manually with no repo set up) - it just won't mirror to
-- monitors or accept monitor touches in that case.
-- ---------------------------------------------------------------

local function loadMonlib()
  local candidates = { "/lib/monitor.lua", "/.bad/lib/monitor.lua" }
  for _, p in ipairs(candidates) do
    if fs.exists(p) then
      local ok, lib = pcall(dofile, p)
      if ok and lib then return lib end
    end
  end
  return nil
end

local monlib = loadMonlib()

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

local function loadMeta()
  return readJSON(META_FILE, {})
end

local function saveMeta(meta)
  writeJSON(META_FILE, meta)
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

local function warnMsg(text)
  printColor("[bad] " .. text, colors and colors.orange or nil)
end

-- ---------------------------------------------------------------
-- HTTP (with a couple of retries - servers/network hiccups happen)
-- ---------------------------------------------------------------

local function httpGet(url, retries)
  if not http then
    errorMsg("HTTP API is disabled on this computer (server config: http.enabled).")
    return nil
  end
  retries = retries or 2
  for attempt = 1, retries do
    local ok, resp = pcall(http.get, url)
    if ok and resp then
      local body = resp.readAll()
      resp.close()
      return body
    end
    if attempt < retries then
      sleep(0.5)
    end
  end
  errorMsg("Failed to download: " .. url)
  return nil
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
    local meta = loadMeta()
    meta.lastUpdate = os.date and os.date("%Y-%m-%d %H:%M:%S") or tostring(os.time())
    saveMeta(meta)
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

-- Returns the names of installed packages that list `name` as a
-- dependency (used to protect against removing something still in use).
local function findDependents(name, installed)
  local dependents = {}
  for pname, entry in pairs(installed) do
    if pname ~= name and entry.depends then
      for _, d in ipairs(entry.depends) do
        if d == name then table.insert(dependents, pname) end
      end
    end
  end
  return dependents
end

-- isManual: true if the user asked for this package directly (as
-- opposed to it being pulled in purely as someone else's dependency).
-- This is tracked so `bad autoremove` knows what's safe to clean up.
local function installOne(name, seen, isManual)
  seen = seen or {}
  if seen[name] then return true end
  seen[name] = true

  local installed = loadInstalled()
  if installed[name] then
    if isManual and installed[name].reason ~= "manual" then
      installed[name].reason = "manual"
      saveInstalled(installed)
      infoMsg("Package '" .. name .. "' is already installed - marked as manually installed.")
    else
      infoMsg("Package '" .. name .. "' is already installed (v" .. tostring(installed[name].version) .. "). Skipping.")
    end
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
      if not installOne(dep, seen, false) then
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
  local total = #files
  for i, f in ipairs(files) do
    infoMsg("  [" .. i .. "/" .. total .. "] downloading " .. f.path)
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

  installed = loadInstalled()
  installed[name] = {
    version = pkg.version,
    files = writtenFiles,
    depends = pkg.depends or {},
    installedAt = os.epoch and os.epoch("utc") or os.time(),
    reason = isManual and "manual" or "auto",
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
    installOne(name, nil, true)
  end
end

local function removeFiles(entry)
  for _, path in ipairs(entry.files) do
    if fs.exists(path) then
      fs.delete(path)
    end
  end
end

local function cmdRemove(args)
  local force = false
  local names = {}
  for _, a in ipairs(args) do
    if a == "--force" or a == "-f" then
      force = true
    else
      table.insert(names, a)
    end
  end

  if #names == 0 then
    errorMsg("Specify a package name: bad remove <pkg> [--force]")
    return
  end

  local installed = loadInstalled()
  for _, name in ipairs(names) do
    local entry = installed[name]
    if not entry then
      errorMsg("Package '" .. name .. "' is not installed.")
    else
      local dependents = findDependents(name, installed)
      if #dependents > 0 and not force then
        errorMsg("Cannot remove '" .. name .. "': required by " ..
          table.concat(dependents, ", ") .. ". Use 'bad remove " .. name .. " --force' to remove anyway.")
      else
        removeFiles(entry)
        installed[name] = nil
        okMsg("Package '" .. name .. "' removed.")
      end
    end
  end
  saveInstalled(installed)
end

local function cmdReinstall(args)
  if #args == 0 then
    errorMsg("Specify a package name: bad reinstall <pkg>")
    return
  end
  for _, name in ipairs(args) do
    local installed = loadInstalled()
    local wasManual = true
    local entry = installed[name]
    if entry then
      wasManual = (entry.reason ~= "auto")
      removeFiles(entry)
      installed[name] = nil
      saveInstalled(installed)
    end
    infoMsg("Reinstalling '" .. name .. "'...")
    installOne(name, nil, wasManual)
  end
end

local function cmdUpgrade(args)
  local installed = loadInstalled()
  local idx = loadIndex()

  local targets = nil
  if args and #args > 0 then
    targets = {}
    for _, n in ipairs(args) do targets[n] = true end
  end

  local any = false
  for name, entry in pairs(installed) do
    if not targets or targets[name] then
      local pkg = idx[name]
      if pkg and pkg.version ~= entry.version then
        infoMsg("Upgrading '" .. name .. "': " .. tostring(entry.version) .. " -> " .. tostring(pkg.version))
        removeFiles(entry)
        local wasManual = (entry.reason ~= "auto")
        installed[name] = nil
        saveInstalled(installed)
        installOne(name, nil, wasManual)
        any = true
      elseif targets and targets[name] then
        okMsg("'" .. name .. "' is already up to date.")
      elseif targets and not pkg then
        errorMsg("'" .. name .. "' is not in the package index. Run: bad update")
      end
    end
  end

  if not any and not targets then
    okMsg("All packages are already up to date.")
  end
end

local function computeNeeded(installed, idx)
  local needed = {}
  local function mark(name)
    if needed[name] then return end
    needed[name] = true
    local pkg = idx[name]
    local deps = (pkg and pkg.depends) or (installed[name] and installed[name].depends)
    if deps then
      for _, d in ipairs(deps) do mark(d) end
    end
  end
  for name, entry in pairs(installed) do
    if entry.reason ~= "auto" then
      mark(name)
    end
  end
  return needed
end

local function cmdAutoremove()
  local installed = loadInstalled()
  local idx = loadIndex()
  local needed = computeNeeded(installed, idx)

  local toRemove = {}
  for name, entry in pairs(installed) do
    if entry.reason == "auto" and not needed[name] then
      table.insert(toRemove, name)
    end
  end

  if #toRemove == 0 then
    okMsg("Nothing to autoremove - no unused auto-installed dependencies.")
    return
  end

  infoMsg("Removing unused auto-installed dependencies:")
  for _, name in ipairs(toRemove) do
    removeFiles(installed[name])
    installed[name] = nil
    print("  - " .. name)
  end
  saveInstalled(installed)
  okMsg("Autoremove complete (" .. #toRemove .. " package(s) removed).")
end

local function cmdClean()
  if fs.exists(INDEX_FILE) then
    fs.delete(INDEX_FILE)
  end
  okMsg("Cached package index cleared. Run 'bad update' to refresh it.")
end

-- ---------------------------------------------------------------
-- list / search / info / outdated / depends
-- ---------------------------------------------------------------

local function cmdList()
  local installed = loadInstalled()
  local count = 0
  for name, entry in pairs(installed) do
    local reason = entry.reason == "auto" and " (auto)" or ""
    print(name .. "  (v" .. tostring(entry.version) .. ")" .. reason)
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
    local reason = installed[name].reason == "auto" and " (auto-installed)" or " (manually installed)"
    print("Status:      installed (v" .. tostring(installed[name].version) .. ")" .. reason)
  else
    print("Status:      not installed")
  end
end

local function cmdOutdated()
  local installed = loadInstalled()
  local idx = loadIndex()
  local any = false
  for name, entry in pairs(installed) do
    local pkg = idx[name]
    if pkg and pkg.version ~= entry.version then
      print(name .. ": " .. tostring(entry.version) .. " -> " .. tostring(pkg.version))
      any = true
    end
  end
  if not any then
    okMsg("Everything is up to date (based on the cached index - run 'bad update' first if unsure).")
  end
end

local function cmdDepends(args)
  local name = args[1]
  if not name then
    errorMsg("Specify a package name: bad depends <pkg>")
    return
  end
  local pkg = resolvePackage(name)
  if pkg and pkg.depends and #pkg.depends > 0 then
    print("'" .. name .. "' depends on: " .. table.concat(pkg.depends, ", "))
  else
    print("'" .. name .. "' has no dependencies.")
  end

  local installed = loadInstalled()
  local dependents = findDependents(name, installed)
  if #dependents > 0 then
    print("Installed packages that require '" .. name .. "': " .. table.concat(dependents, ", "))
  else
    print("No installed packages currently depend on '" .. name .. "'.")
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
-- gui - clickable/tappable menu, mirrored to any attached monitors
-- ---------------------------------------------------------------

local MENU_ITEMS = {
  { id = "update",     label = "Update package index" },
  { id = "list",       label = "List installed packages" },
  { id = "search",     label = "Search packages" },
  { id = "install",    label = "Install a package" },
  { id = "remove",     label = "Remove a package" },
  { id = "upgrade",    label = "Upgrade all packages" },
  { id = "outdated",   label = "Show outdated packages" },
  { id = "autoremove", label = "Autoremove unused deps" },
  { id = "repos",      label = "List repositories" },
  { id = "quit",       label = "Exit" },
}

local function splitWords(line)
  local out = {}
  for w in line:gmatch("%S+") do table.insert(out, w) end
  return out
end

local function cmdGui()
  local rectsByTarget = {}

  local function drawMenu(w, h, targetName)
    if term.setBackgroundColor then term.setBackgroundColor(colors and colors.black or nil) end
    term.clear()
    term.setCursorPos(1, 1)
    if colors then term.setTextColor(colors.yellow) end
    term.write("BAD v" .. BAD_VERSION .. " - Package Manager")
    if colors then term.setTextColor(colors.gray) end
    term.setCursorPos(1, 2)
    term.write(string.rep("-", math.max(1, math.min(w, 40))))

    local rects = {}
    local row = 4
    for i, item in ipairs(MENU_ITEMS) do
      if row < h then
        term.setCursorPos(2, row)
        if colors then term.setTextColor(colors.lightBlue) end
        term.write(tostring(i) .. ". ")
        if colors then term.setTextColor(colors.white) end
        term.write(item.label)
        table.insert(rects, { id = item.id, x1 = 1, y1 = row, x2 = w, y2 = row })
      end
      row = row + 1
    end

    if colors then term.setTextColor(colors.gray) end
    term.setCursorPos(1, h)
    term.write("Click/tap a row, or press 1-" .. #MENU_ITEMS .. ", q to quit")
    if colors then term.setTextColor(colors.white) end

    rectsByTarget[targetName] = rects
  end

  local function runAction(id)
    if term.setBackgroundColor then term.setBackgroundColor(colors and colors.black or nil) end
    term.clear()
    term.setCursorPos(1, 1)

    if id == "update" then
      cmdUpdate()
    elseif id == "list" then
      cmdList()
    elseif id == "search" then
      write("Search text: ")
      cmdSearch(splitWords(read()))
    elseif id == "install" then
      write("Package name(s) to install: ")
      cmdInstall(splitWords(read()))
    elseif id == "remove" then
      write("Package name(s) to remove: ")
      cmdRemove(splitWords(read()))
    elseif id == "upgrade" then
      cmdUpgrade({})
    elseif id == "outdated" then
      cmdOutdated()
    elseif id == "autoremove" then
      cmdAutoremove()
    elseif id == "repos" then
      cmdRepo({ "list" })
    end

    print("")
    print("Press any key or tap to return to the menu...")
    if monlib then
      monlib.pullEvent()
    else
      os.pullEvent("key")
    end
  end

  local function simpleHitTest(rects, x, y)
    for _, r in ipairs(rects) do
      if x >= r.x1 and x <= r.x2 and y >= r.y1 and y <= r.y2 then
        return r.id
      end
    end
    return nil
  end

  local running = true
  while running do
    if monlib then
      monlib.renderAll(drawMenu)
    else
      local w, h = term.getSize()
      drawMenu(w, h, "term")
    end

    local ev
    if monlib then
      ev = monlib.pullEvent()
    else
      local event, p1, p2, p3 = os.pullEvent()
      if event == "mouse_click" then
        ev = { type = "click", x = p2, y = p3, source = "term" }
      elseif event == "key" then
        ev = { type = "key", key = p1 }
      elseif event == "char" then
        ev = { type = "char", char = p1 }
      else
        ev = { type = "other" }
      end
    end

    local chosenId = nil
    if ev.type == "click" then
      local rects = rectsByTarget[ev.source] or rectsByTarget["term"]
      if rects then
        chosenId = simpleHitTest(rects, ev.x, ev.y)
      end
    elseif ev.type == "char" then
      local n = tonumber(ev.char)
      if n and MENU_ITEMS[n] then chosenId = MENU_ITEMS[n].id end
      if ev.char == "q" then chosenId = "quit" end
    elseif ev.type == "key" then
      if ev.key == keys.q then chosenId = "quit" end
    end

    if chosenId == "quit" then
      running = false
    elseif chosenId then
      runAction(chosenId)
    end
  end

  if term.setBackgroundColor then term.setBackgroundColor(colors and colors.black or nil) end
  term.clear()
  term.setCursorPos(1, 1)
  okMsg("Goodbye!")
end

-- ---------------------------------------------------------------
-- help / version
-- ---------------------------------------------------------------

local function cmdHelp()
  print("BAD - Basic Archive Downloader (package manager) v" .. BAD_VERSION)
  print("")
  print("Commands:")
  print("  bad update                 - refresh package index")
  print("  bad install <pkg...>       - install package(s)")
  print("  bad reinstall <pkg...>     - force reinstall package(s)")
  print("  bad remove  <pkg...> [-f]  - remove package(s) (-f/--force skips dep check)")
  print("  bad upgrade [pkg...]       - upgrade all, or only named packages")
  print("  bad outdated               - show installed packages with updates")
  print("  bad autoremove             - remove unused auto-installed deps")
  print("  bad clean                  - clear the cached package index")
  print("  bad list                   - list installed packages")
  print("  bad search  <text>         - search for a package")
  print("  bad info    <pkg>          - show package info")
  print("  bad depends <pkg>          - show deps + reverse deps of a package")
  print("  bad repo add|remove|list [url] - manage repositories")
  print("  bad gui                    - clickable/tappable menu UI")
  print("                               (mirrored to any attached monitor)")
  print("  bad version                - show BAD's version")
  if monlib and monlib.available() then
    infoMsg(#monlib.list() .. " monitor(s) detected - 'bad gui' will mirror to them.")
  end
end

local function cmdVersionOut()
  print("BAD (Basic Archive Downloader) v" .. BAD_VERSION)
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
  elseif cmd == "reinstall" then cmdReinstall(args)
  elseif cmd == "remove" then cmdRemove(args)
  elseif cmd == "upgrade" then cmdUpgrade(args)
  elseif cmd == "outdated" then cmdOutdated()
  elseif cmd == "autoremove" then cmdAutoremove()
  elseif cmd == "clean" then cmdClean()
  elseif cmd == "list" then cmdList()
  elseif cmd == "search" then cmdSearch(args)
  elseif cmd == "info" then cmdInfo(args)
  elseif cmd == "depends" then cmdDepends(args)
  elseif cmd == "repo" then cmdRepo(args)
  elseif cmd == "gui" then cmdGui()
  elseif cmd == "version" or cmd == "--version" then cmdVersionOut()
  else
    errorMsg("Unknown command: " .. cmd)
    cmdHelp()
  end
end

main(...)
