-- ============================================================
--  Minegram Client
--  A Telegram-like chat client for CC: Tweaked players.
--  Talk in groups, follow channels, send direct messages.
--
--  Requires: a Minegram server running somewhere reachable over
--  rednet (see minegram-server.lua), and a modem attached to
--  this computer.
--
--  Repository: https://github.com/hez1ch/bad
-- ============================================================

local PROTOCOL   = "minegram"
local HOSTNAME   = "minegram-server"
local CONFIG_DIR = "/.minegram"
local USER_FILE  = CONFIG_DIR .. "/username.txt"

local serverId = nil
local username = nil
local running = true

-- per-channel local scrollback cache: { [channelName] = { {from,text,time}, ... } }
local cache = {}
-- unread notification counters
local unread = {}

-- ---------------------------------------------------------------
-- Utilities
-- ---------------------------------------------------------------

local function ensureConfigDir()
  if not fs.exists(CONFIG_DIR) then fs.makeDir(CONFIG_DIR) end
end

local function openModem()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      rednet.open(name)
      return true
    end
  end
  return false
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

local function sysMsg(text)
  printColor("* " .. text, colors and colors.yellow or nil)
end

local function errMsg(text)
  printColor("! " .. text, colors and colors.red or nil)
end

local function loadUsername()
  if fs.exists(USER_FILE) then
    local h = fs.open(USER_FILE, "r")
    local name = h.readAll()
    h.close()
    if name and name ~= "" then return name end
  end
  return nil
end

local function saveUsername(name)
  ensureConfigDir()
  local h = fs.open(USER_FILE, "w")
  h.write(name)
  h.close()
end

local function send(message)
  rednet.send(serverId, message, PROTOCOL)
end

-- waits for a specific response type (with timeout), while any other
-- incoming message is routed to the normal handler
local function waitFor(expectedTypes, timeout)
  local deadline = os.clock() + (timeout or 5)
  while os.clock() < deadline do
    local id, msg = rednet.receive(PROTOCOL, deadline - os.clock())
    if msg and type(msg) == "table" then
      if expectedTypes[msg.type] then
        return msg
      else
        handleIncoming(msg)
      end
    end
  end
  return nil
end

-- ---------------------------------------------------------------
-- Incoming message handling (forward declared above via upvalue)
-- ---------------------------------------------------------------

function handleIncoming(msg)
  if msg.type == "message" then
    local list = cache[msg.channel] or {}
    table.insert(list, { from = msg.from, text = msg.text, time = msg.time })
    cache[msg.channel] = list
    unread[msg.channel] = (unread[msg.channel] or 0) + 1
    sysMsg("[#" .. msg.channel .. "] " .. msg.from .. ": " .. msg.text)
  elseif msg.type == "dm_message" then
    local key = "@" .. msg.from
    local list = cache[key] or {}
    table.insert(list, { from = msg.from, text = msg.text, time = msg.time })
    cache[key] = list
    unread[key] = (unread[key] or 0) + 1
    sysMsg("[DM from " .. msg.from .. "] " .. msg.text)
  elseif msg.type == "error" then
    errMsg(msg.message)
  end
end

-- ---------------------------------------------------------------
-- Connection / registration
-- ---------------------------------------------------------------

local function connect()
  sysMsg("Looking up Minegram server...")
  serverId = rednet.lookup(PROTOCOL, HOSTNAME)
  if not serverId then
    errMsg("No Minegram server found (protocol '" .. PROTOCOL .. "').")
    errMsg("Make sure minegram-server is running on a reachable computer.")
    return false
  end
  sysMsg("Server found (id " .. serverId .. ").")
  return true
end

local function register()
  local name = loadUsername()
  if not name then
    write("Choose a username: ")
    name = read()
  end
  send({ type = "register", username = name })
  local resp = waitFor({ register_ok = true, register_fail = true }, 5)
  if not resp then
    errMsg("No response from server.")
    return false
  end
  if resp.type == "register_fail" then
    errMsg("Registration failed: " .. tostring(resp.reason))
    return false
  end
  username = resp.username
  saveUsername(username)
  sysMsg("Logged in as " .. username)
  return true
end

-- ---------------------------------------------------------------
-- Screens
-- ---------------------------------------------------------------

local function pause()
  print("")
  write("Press Enter to continue...")
  read()
end

local function listChannels()
  send({ type = "list_channels" })
  local resp = waitFor({ channel_list = true }, 5)
  if not resp then errMsg("Timed out.") return {} end
  return resp.channels
end

local function showChannelsMenu()
  local channels = listChannels()
  term.clear() term.setCursorPos(1,1)
  print("=== Channels & Groups ===")
  if #channels == 0 then
    print("(none yet - create one!)")
  else
    for i, ch in ipairs(channels) do
      local mark = ch.joined and "*" or " "
      print(string.format("%d.%s [%s] #%s (%d members) - %s",
        i, mark, ch.ctype, ch.name, ch.members, ch.description))
    end
  end
  print("")
  print("Enter number to open, 'c' to create new, or empty to go back:")
  write("> ")
  local input = read()
  if input == "" then return end
  if input == "c" then
    createChannel()
    return
  end
  local idx = tonumber(input)
  if idx and channels[idx] then
    openChannel(channels[idx].name, channels[idx].joined)
  end
end

function createChannel()
  write("Name (letters/digits/_/-): ")
  local name = read()
  if name == "" then return end
  write("Type - (c)hannel [owner-only posts] or (g)roup [everyone posts]: ")
  local t = read()
  local ctype = (t == "c" or t == "channel") and "channel" or "group"
  write("Description: ")
  local desc = read()
  send({ type = "create_channel", name = name, ctype = ctype, description = desc })
  local resp = waitFor({ channel_created = true, channel_create_fail = true }, 5)
  if not resp then errMsg("Timed out.") return end
  if resp.type == "channel_create_fail" then
    errMsg("Could not create: " .. tostring(resp.reason))
  else
    sysMsg("Created " .. resp.ctype .. " '" .. resp.name .. "'")
    openChannel(resp.name, true)
  end
end

function openChannel(name, alreadyJoined)
  if not alreadyJoined then
    send({ type = "join_channel", name = name })
    local resp = waitFor({ joined = true, join_fail = true }, 5)
    if not resp or resp.type == "join_fail" then
      errMsg("Could not join: " .. tostring(resp and resp.reason or "timeout"))
      return
    end
  end

  send({ type = "get_history", channel = name })
  local hist = waitFor({ history = true }, 5)
  if hist then
    cache[name] = hist.messages
  end
  unread[name] = 0

  chatLoop("#" .. name, name, false)
end

-- ---------------------------------------------------------------
-- Direct messages
-- ---------------------------------------------------------------

local function showUsersMenu()
  send({ type = "list_users" })
  local resp = waitFor({ user_list = true }, 5)
  term.clear() term.setCursorPos(1,1)
  print("=== Users ===")
  if not resp or #resp.users == 0 then
    print("(no users yet)")
    pause()
    return
  end
  for i, u in ipairs(resp.users) do
    print(string.format("%d. %s %s", i, u.username, u.online and "(online)" or "(offline)"))
  end
  print("")
  print("Enter number to message, or empty to go back:")
  write("> ")
  local input = read()
  if input == "" then return end
  local idx = tonumber(input)
  if idx and resp.users[idx] then
    local target = resp.users[idx].username
    unread["@" .. target] = 0
    chatLoop("DM with " .. target, target, true)
  end
end

-- ---------------------------------------------------------------
-- Chat loop (shared by channels and DMs)
-- ---------------------------------------------------------------

function chatLoop(title, target, isDM)
  local key = isDM and ("@" .. target) or target
  local exit = false

  local function redraw()
    term.clear() term.setCursorPos(1,1)
    print("=== " .. title .. " ===")
    print("(type a message, /back to return, /who to list members - not on DMs)")
    print("----------------------------------------")
    local list = cache[key] or {}
    local w, h = term.getSize()
    local startIdx = math.max(1, #list - (h - 6))
    for i = startIdx, #list do
      local m = list[i]
      print(string.format("[%s] %s: %s", m.time or "--:--", m.from, m.text))
    end
    print("----------------------------------------")
  end

  local function inputLoop()
    while not exit do
      redraw()
      write("> ")
      local text = read()
      if text == "/back" then
        exit = true
      elseif text ~= "" then
        if isDM then
          send({ type = "dm", to = target, text = text })
          local list = cache[key] or {}
          table.insert(list, { from = username, text = text, time = os.date and os.date("%H:%M") or "" })
          cache[key] = list
        else
          send({ type = "send_message", channel = target, text = text })
        end
      end
    end
  end

  local function listenLoop()
    while not exit do
      local id, msg = rednet.receive(PROTOCOL, 1)
      if msg and type(msg) == "table" then
        handleIncoming(msg)
      end
    end
  end

  parallel.waitForAny(inputLoop, listenLoop)
end

-- ---------------------------------------------------------------
-- Background listener for the main menu (so notifications still
-- pop up while browsing menus)
-- ---------------------------------------------------------------

local function backgroundListener()
  while running do
    local id, msg = rednet.receive(PROTOCOL, 1)
    if msg and type(msg) == "table" then
      handleIncoming(msg)
    end
  end
end

-- ---------------------------------------------------------------
-- Main menu
-- ---------------------------------------------------------------

local function unreadTotal()
  local total = 0
  for _, n in pairs(unread) do total = total + n end
  return total
end

local function mainMenu()
  while running do
    term.clear() term.setCursorPos(1,1)
    print("=====================================")
    print("   MINEGRAM  -  logged in as " .. username)
    print("=====================================")
    if unreadTotal() > 0 then
      printColor("You have " .. unreadTotal() .. " unread message(s)", colors and colors.orange or nil)
    end
    print("")
    print("1. Channels & Groups")
    print("2. Direct Messages / Users")
    print("q. Quit")
    write("> ")
    local choice = read()
    if choice == "1" then
      showChannelsMenu()
    elseif choice == "2" then
      showUsersMenu()
    elseif choice == "q" then
      running = false
    end
  end
end

-- ---------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------

local function main()
  ensureConfigDir()
  if not openModem() then
    errMsg("No modem attached. Attach a wireless or ender modem and rerun.")
    return
  end
  if not connect() then return end
  if not register() then return end
  mainMenu()
  sysMsg("Goodbye!")
end

main()
