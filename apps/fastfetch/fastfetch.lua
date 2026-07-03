-- ============================================================
--  fastfetch - a neofetch/fastfetch-style system info screen
--  for CC: Tweaked computers.
--
--  Shows the "OS" chosen via krnl-upd, whether BAD is installed
--  as the package manager, and basic computer stats.
--
--  Repository: https://github.com/hez1ch/bad
-- ============================================================

local OS_CONFIG_FILE = "/.system/os.json"

local LOGOS = {
  ["3ggrnel"] = {
    "   ______      ",
    "  /  ____\\     ",
    " |  /____\\ |   ",
    " | 3ggrnel |   ",
    " |__________|  ",
    "  \\________/   ",
  },
  ["smallvanya"] = {
    "    ___         ",
    "   /   \\        ",
    "  | o o |       ",
    "  |  ^  |  SV   ",
    "   \\___/        ",
    "    | |         ",
  },
  ["hezion"] = {
    "   /\\  /\\      ",
    "  /  \\/  \\     ",
    " | HEZION  |    ",
    "  \\  /\\  /     ",
    "   \\/  \\/      ",
    "    ||         ",
  },
}

local DEFAULT_LOGO = {
  "   ?????        ",
  "  ???????       ",
  " ??  N/A  ??    ",
  "  ???????       ",
  "   ?????        ",
  "                ",
}

local function loadOS()
  if not fs.exists(OS_CONFIG_FILE) then return nil end
  local h = fs.open(OS_CONFIG_FILE, "r")
  local content = h.readAll()
  h.close()
  local ok, data = pcall(textutils.unserializeJSON, content)
  if ok then return data end
  return nil
end

local function formatUptime()
  local secs = math.floor(os.clock())
  local m = math.floor(secs / 60)
  local s = secs % 60
  return m .. "m " .. s .. "s (this session)"
end

local function packageManagerInfo()
  if fs.exists("/bin/bad") then
    return "BAD"
  end
  return "none (install BAD - see github.com/hez1ch/bad)"
end

local function diskInfo()
  local ok1, free = pcall(fs.getFreeSpace, "/")
  local ok2, cap = pcall(fs.getCapacity, "/")
  if ok1 and ok2 and free and cap then
    return string.format("%.1fKB / %.1fKB", free / 1024, cap / 1024)
  elseif ok1 and free then
    return string.format("%.1fKB free", free / 1024)
  end
  return "unknown"
end

local function main()
  local osData = loadOS()
  local logo = osData and LOGOS[osData.id] or DEFAULT_LOGO
  local colorOk = term.isColor and term.isColor()

  local osName = osData and (osData.name .. " v" .. tostring(osData.version)
    .. " (build " .. tostring(osData.build) .. ")") or "not installed (run krnl-upd)"

  local infoLines = {
    { label = "OS",        value = osName },
    { label = "Kernel",    value = "CraftOS " .. tostring(os.version and os.version() or "?") },
    { label = "Packages",  value = packageManagerInfo() },
    { label = "Computer",  value = "#" .. tostring(os.getComputerID())
                              .. (os.getComputerLabel() and (" (" .. os.getComputerLabel() .. ")") or "") },
    { label = "Uptime",    value = formatUptime() },
    { label = "Disk",      value = diskInfo() },
    { label = "Term",      value = (function() local w, h = term.getSize() return w .. "x" .. h end)() },
    { label = "Color",     value = colorOk and "yes" or "no (basic terminal)" },
  }

  term.clear()
  term.setCursorPos(1, 1)

  local function setFg(c)
    if colorOk then term.setTextColor(c) end
  end

  local logoWidth = 0
  for _, l in ipairs(logo) do
    if #l > logoWidth then logoWidth = #l end
  end

  local totalRows = math.max(#logo, #infoLines + 1)
  for row = 1, totalRows do
    term.setCursorPos(1, row)
    setFg(colors and colors.cyan or nil)
    term.write(logo[row] or string.rep(" ", logoWidth))

    term.setCursorPos(logoWidth + 3, row)
    if row == 1 then
      setFg(colors and colors.yellow or nil)
      term.write((osData and osData.name or "unknown") .. "@computer-" .. tostring(os.getComputerID()))
    elseif infoLines[row - 1] then
      local entry = infoLines[row - 1]
      setFg(colors and colors.lightGray or nil)
      term.write(entry.label .. ": ")
      setFg(colors and colors.white or nil)
      term.write(entry.value)
    end
  end

  setFg(colors and colors.white or nil)
  term.setCursorPos(1, totalRows + 2)
end

main()
