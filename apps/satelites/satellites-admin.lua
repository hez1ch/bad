-- ============================================================
--  satellites-admin - add/edit/remove satellites tracked by the
--  `satellites` viewer (real-3D Earth + orbiting satellite markers).
--
--  Usage:
--    satellites-admin add <id> <name> <period_min> <inclination_deg>
--                      <orbit_radius> <signal_pct> [description...]
--    satellites-admin edit <id> <field> <value>
--                      (field: name, description, signal, period,
--                       inclination, orbitRadius, angle)
--    satellites-admin remove <id>
--    satellites-admin list
--    satellites-admin info <id>
--    satellites-admin computer add <id> <computerId> <computerName>
--    satellites-admin computer remove <id> <computerId>
--
--  Running with no arguments opens a small interactive menu instead
--  (mirrored to any attached monitor for oversight - actual
--  keyboard input is still read from the terminal).
--
--  Repository: https://github.com/hez1ch/bad
-- ============================================================

local DATA_DIR  = "/.satellites"
local DATA_FILE = DATA_DIR .. "/satellites.json"

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
-- Storage
-- ---------------------------------------------------------------

local function ensureDir()
  if not fs.exists(DATA_DIR) then fs.makeDir(DATA_DIR) end
end

local function loadData()
  ensureDir()
  if not fs.exists(DATA_FILE) then return {} end
  local h = fs.open(DATA_FILE, "r")
  local content = h.readAll()
  h.close()
  if content == nil or content == "" then return {} end
  local ok, data = pcall(textutils.unserializeJSON, content)
  if not ok or data == nil then return {} end
  return data
end

local function saveData(data)
  ensureDir()
  local h = fs.open(DATA_FILE, "w")
  h.write(textutils.serializeJSON(data))
  h.close()
end

local function now()
  return os.epoch and os.epoch("utc") or (os.time() * 1000)
end

-- ---------------------------------------------------------------
-- Validation helpers
-- ---------------------------------------------------------------

local function toNumber(v, fieldName)
  local n = tonumber(v)
  if not n then
    error("'" .. fieldName .. "' must be a number, got: " .. tostring(v))
  end
  return n
end

local function clampNum(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- ---------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------

local function cmdAdd(args)
  local id = args[1]
  local name = args[2]
  local period = args[3]
  local inclination = args[4]
  local orbitRadius = args[5]
  local signal = args[6]
  local description = table.concat(args, " ", 7)

  if not (id and name and period and inclination and orbitRadius and signal) then
    print("Usage: satellites-admin add <id> <name> <period_min> <inclination_deg>")
    print("                          <orbit_radius> <signal_pct> [description...]")
    return
  end

  local data = loadData()
  if data[id] then
    print("Error: a satellite with id '" .. id .. "' already exists. Use 'edit' or pick another id.")
    return
  end

  data[id] = {
    name = name,
    description = description or "",
    signal = clampNum(toNumber(signal, "signal_pct"), 0, 100),
    period = math.max(1, toNumber(period, "period_min")),
    inclination = toNumber(inclination, "inclination_deg"),
    orbitRadius = math.max(1.1, toNumber(orbitRadius, "orbit_radius")),
    angle = 0,
    lastTick = now(),
    computers = {},
    addedAt = now(),
  }
  saveData(data)
  print("Satellite '" .. id .. "' (" .. name .. ") added.")
end

local EDITABLE_FIELDS = {
  name = "string",
  description = "string",
  signal = "number",
  period = "number",
  inclination = "number",
  orbitRadius = "number",
  angle = "number",
}

local function cmdEdit(args)
  local id, field, value = args[1], args[2], args[3]
  if not (id and field and value ~= nil) then
    print("Usage: satellites-admin edit <id> <field> <value>")
    print("Fields: name, description, signal, period, inclination, orbitRadius, angle")
    return
  end

  local data = loadData()
  local sat = data[id]
  if not sat then
    print("Error: no satellite with id '" .. id .. "'")
    return
  end

  local kind = EDITABLE_FIELDS[field]
  if not kind then
    print("Error: unknown field '" .. field .. "'. Editable fields: name, description,")
    print("signal, period, inclination, orbitRadius, angle")
    return
  end

  if kind == "number" then
    sat[field] = toNumber(value, field)
    if field == "signal" then sat[field] = clampNum(sat[field], 0, 100) end
    if field == "period" then sat[field] = math.max(1, sat[field]) end
    if field == "orbitRadius" then sat[field] = math.max(1.1, sat[field]) end
  else
    -- string fields: allow the remaining args to be the full value
    -- (e.g. a multi-word description)
    sat[field] = table.concat(args, " ", 3)
  end

  saveData(data)
  print("Satellite '" .. id .. "' updated: " .. field .. " = " .. tostring(sat[field]))
end

local function cmdRemove(args)
  local id = args[1]
  if not id then
    print("Usage: satellites-admin remove <id>")
    return
  end
  local data = loadData()
  if not data[id] then
    print("Error: no satellite with id '" .. id .. "'")
    return
  end
  data[id] = nil
  saveData(data)
  print("Satellite '" .. id .. "' removed.")
end

local function formatSatOneLine(id, sat)
  return id .. ": " .. tostring(sat.name) .. " (signal " .. tostring(sat.signal)
    .. "%, period " .. tostring(sat.period) .. "min, incl " .. tostring(sat.inclination) .. "deg)"
end

local function cmdList()
  local data = loadData()
  local count = 0
  for id, sat in pairs(data) do
    print(formatSatOneLine(id, sat))
    count = count + 1
  end
  if count == 0 then
    print("No satellites configured yet. Add one with: satellites-admin add ...")
  end
end

local function cmdInfo(args)
  local id = args[1]
  if not id then
    print("Usage: satellites-admin info <id>")
    return
  end
  local data = loadData()
  local sat = data[id]
  if not sat then
    print("Error: no satellite with id '" .. id .. "'")
    return
  end
  print("Id:          " .. id)
  print("Name:        " .. tostring(sat.name))
  print("Description: " .. tostring(sat.description))
  print("Signal:      " .. tostring(sat.signal) .. "%")
  print("Period:      " .. tostring(sat.period) .. " minutes/orbit")
  print("Inclination: " .. tostring(sat.inclination) .. " deg")
  print("Orbit r:     " .. tostring(sat.orbitRadius) .. " (Earth radii)")
  print("Angle now:   " .. tostring(sat.angle) .. " deg")
  print("Computers:")
  if sat.computers and #sat.computers > 0 then
    for _, c in ipairs(sat.computers) do
      print("  #" .. tostring(c.id) .. " - " .. tostring(c.name))
    end
  else
    print("  (none connected)")
  end
end

local function cmdComputer(args)
  local sub = args[1]
  local id = args[2]
  if not (sub and id) then
    print("Usage: satellites-admin computer <add|remove> <id> <computerId> [computerName]")
    return
  end
  local data = loadData()
  local sat = data[id]
  if not sat then
    print("Error: no satellite with id '" .. id .. "'")
    return
  end
  sat.computers = sat.computers or {}

  if sub == "add" then
    local compId = args[3]
    local compName = args[4] or ("Computer #" .. tostring(compId))
    if not compId then
      print("Usage: satellites-admin computer add <id> <computerId> [computerName]")
      return
    end
    for _, c in ipairs(sat.computers) do
      if tostring(c.id) == tostring(compId) then
        print("Computer #" .. tostring(compId) .. " is already linked to '" .. id .. "'.")
        return
      end
    end
    table.insert(sat.computers, { id = compId, name = compName })
    saveData(data)
    print("Linked computer #" .. tostring(compId) .. " (" .. compName .. ") to '" .. id .. "'.")

  elseif sub == "remove" then
    local compId = args[3]
    if not compId then
      print("Usage: satellites-admin computer remove <id> <computerId>")
      return
    end
    local newList = {}
    local removed = false
    for _, c in ipairs(sat.computers) do
      if tostring(c.id) ~= tostring(compId) then
        table.insert(newList, c)
      else
        removed = true
      end
    end
    sat.computers = newList
    saveData(data)
    if removed then
      print("Unlinked computer #" .. tostring(compId) .. " from '" .. id .. "'.")
    else
      print("Computer #" .. tostring(compId) .. " was not linked to '" .. id .. "'.")
    end
  else
    print("Usage: satellites-admin computer <add|remove> <id> <computerId> [computerName]")
  end
end

local function cmdHelp()
  print("satellites-admin - manage satellites for the `satellites` viewer")
  print("")
  print("  satellites-admin add <id> <name> <period_min> <inclination_deg>")
  print("                        <orbit_radius> <signal_pct> [description...]")
  print("  satellites-admin edit <id> <field> <value>")
  print("  satellites-admin remove <id>")
  print("  satellites-admin list")
  print("  satellites-admin info <id>")
  print("  satellites-admin computer add|remove <id> <computerId> [computerName]")
  print("")
  print("Run with no arguments for an interactive menu.")
end

-- ---------------------------------------------------------------
-- Interactive menu (no args) - mirrors the satellite list to any
-- attached monitor; input itself is read on the terminal.
-- ---------------------------------------------------------------

local function splitWords(line)
  local out = {}
  for w in line:gmatch("%S+") do table.insert(out, w) end
  return out
end

local function drawOverview(w, h, targetName)
  term.clear()
  term.setCursorPos(1, 1)
  if colors then term.setTextColor(colors.yellow) end
  term.write("Satellites - admin overview")
  if colors then term.setTextColor(colors.white) end
  term.setCursorPos(1, 2)
  term.write(string.rep("-", math.max(1, math.min(w, 40))))

  local data = loadData()
  local row = 3
  local any = false
  for id, sat in pairs(data) do
    if row < h then
      term.setCursorPos(1, row)
      term.write(formatSatOneLine(id, sat))
      row = row + 1
      any = true
    end
  end
  if not any then
    term.setCursorPos(1, row)
    term.write("No satellites configured yet.")
  end
end

local function interactiveMenu()
  while true do
    if monlib then
      monlib.renderAll(drawOverview)
    else
      local w, h = term.getSize()
      drawOverview(w, h, "term")
    end

    print("")
    print("[a]dd  [e]dit  [r]emove  [i]nfo  [c]omputer link  [q]uit")
    write("> ")
    local choice = read()

    if choice == "q" then
      break
    elseif choice == "a" then
      write("id name period_min inclination_deg orbit_radius signal_pct [description...]: ")
      cmdAdd(splitWords(read()))
    elseif choice == "e" then
      write("id field value: ")
      cmdEdit(splitWords(read()))
    elseif choice == "r" then
      write("id: ")
      cmdRemove(splitWords(read()))
    elseif choice == "i" then
      write("id: ")
      cmdInfo(splitWords(read()))
    elseif choice == "c" then
      write("add|remove id computerId [computerName]: ")
      cmdComputer(splitWords(read()))
    end

    print("")
    print("(press enter to continue)")
    read()
  end
end

-- ---------------------------------------------------------------
-- main
-- ---------------------------------------------------------------

local function main(...)
  local args = { ... }
  local cmd = args[1]

  if not cmd then
    interactiveMenu()
    return
  end

  table.remove(args, 1)

  if cmd == "add" then cmdAdd(args)
  elseif cmd == "edit" then cmdEdit(args)
  elseif cmd == "remove" then cmdRemove(args)
  elseif cmd == "list" then cmdList()
  elseif cmd == "info" then cmdInfo(args)
  elseif cmd == "computer" then cmdComputer(args)
  elseif cmd == "help" then cmdHelp()
  else
    print("Unknown command: " .. tostring(cmd))
    cmdHelp()
  end
end

main(...)
