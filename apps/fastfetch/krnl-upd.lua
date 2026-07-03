-- ============================================================
--  krnl-upd - kernel/OS selector
--
--  Lets you pick which "OS" your computer identifies as. This
--  is purely cosmetic (CC: Tweaked only ever runs CraftOS under
--  the hood) but fastfetch reads the choice made here and shows
--  it off. Think of it as reskinning /etc/os-release.
--
--  Repository: https://github.com/hez1ch/bad
-- ============================================================

local CONFIG_DIR  = "/.system"
local CONFIG_FILE = CONFIG_DIR .. "/os.json"

local OPTIONS = {
  {
    id = "3ggrnel",
    name = "3ggrnel",
    tagline = "minimal, fast, a little unstable",
    version = "3.7",
  },
  {
    id = "smallvanya",
    name = "SmallVanya",
    tagline = "lightweight community build",
    version = "1.4",
  },
  {
    id = "hezion",
    name = "Hezion",
    tagline = "the flagship build",
    version = "2.0",
  },
}

local function ensureConfigDir()
  if not fs.exists(CONFIG_DIR) then fs.makeDir(CONFIG_DIR) end
end

local function saveOS(entry)
  ensureConfigDir()
  local h = fs.open(CONFIG_FILE, "w")
  h.write(textutils.serializeJSON({
    id = entry.id,
    name = entry.name,
    version = entry.version,
    build = tostring(math.random(1000, 9999)),
    installedAt = os.date and os.date("%Y-%m-%d %H:%M") or "unknown",
  }))
  h.close()
end

local function loadOS()
  if not fs.exists(CONFIG_FILE) then return nil end
  local h = fs.open(CONFIG_FILE, "r")
  local content = h.readAll()
  h.close()
  local ok, data = pcall(textutils.unserializeJSON, content)
  if ok then return data end
  return nil
end

local function main()
  math.randomseed((os.epoch and os.epoch("utc") or os.time()) % 100000)

  term.clear()
  term.setCursorPos(1, 1)
  print("=== krnl-upd ===")
  print("Choose the OS build for this computer:")
  print("")
  for i, opt in ipairs(OPTIONS) do
    print(i .. ". " .. opt.name .. " (v" .. opt.version .. ") - " .. opt.tagline)
  end

  local current = loadOS()
  if current then
    print("")
    print("Currently installed: " .. current.name .. " v" .. tostring(current.version)
      .. " (build " .. tostring(current.build) .. ")")
  end

  print("")
  write("Choice [1-" .. #OPTIONS .. "]: ")
  local input = read()
  local idx = tonumber(input)

  if not idx or not OPTIONS[idx] then
    print("Invalid choice, nothing changed.")
    return
  end

  local chosen = OPTIONS[idx]
  print("")
  print("Installing " .. chosen.name .. "...")
  for i = 1, 3 do
    write(".")
    sleep(0.3)
  end
  print("")

  saveOS(chosen)
  print("Done. " .. chosen.name .. " v" .. chosen.version .. " is now active.")
  print("Run 'fastfetch' to see it in action.")
end

main()
