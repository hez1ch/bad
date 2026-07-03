-- ============================================================
--  Minegram Server
--  A Telegram-like chat hub for CC: Tweaked players.
--
--  Run this on a computer with a wireless/ender modem attached.
--  It hosts channels, groups and relays direct messages between
--  players' Minegram clients over rednet.
--
--  Repository: https://github.com/hez1ch/bad
-- ============================================================

local DATA_DIR      = "/minegram-data"
local USERS_FILE     = DATA_DIR .. "/users.json"
local CHANNELS_FILE  = DATA_DIR .. "/channels.json"
local PROTOCOL       = "minegram"
local HOSTNAME       = "minegram-server"
local HISTORY_LIMIT  = 50

-- ---------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------

local function ensureDataDir()
  if not fs.exists(DATA_DIR) then fs.makeDir(DATA_DIR) end
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

-- users: { username = { registeredAt = n } }
-- channels: { name = { ctype = "channel"|"group", owner = username,
--                       description = str, members = {username=true,...},
--                       history = { {from,text,time}, ... } } }

local users = {}
local channels = {}

-- runtime-only: username -> computer id (online map), reset on reboot
local onlineMap = {}

local function loadAll()
  ensureDataDir()
  users = readJSON(USERS_FILE, {})
  channels = readJSON(CHANNELS_FILE, {})
end

local function saveUsers()
  writeJSON(USERS_FILE, users)
end

local function saveChannels()
  writeJSON(CHANNELS_FILE, channels)
end

-- ---------------------------------------------------------------
-- Networking helpers
-- ---------------------------------------------------------------

local function openModem()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      rednet.open(name)
      return true
    end
  end
  return false
end

local function idOf(username)
  return onlineMap[username]
end

local function send(username, message)
  local id = idOf(username)
  if id then
    rednet.send(id, message, PROTOCOL)
  end
end

local function log(text)
  print("[minegram-server] " .. text)
end

-- ---------------------------------------------------------------
-- Channel helpers
-- ---------------------------------------------------------------

local function pushHistory(channel, entry)
  table.insert(channel.history, entry)
  while #channel.history > HISTORY_LIMIT do
    table.remove(channel.history, 1)
  end
end

local function broadcast(channel, entry, exceptUsername)
  for member, _ in pairs(channel.members) do
    if member ~= exceptUsername then
      send(member, {
        type = "message",
        channel = entry.channel,
        from = entry.from,
        text = entry.text,
        time = entry.time,
      })
    end
  end
end

-- ---------------------------------------------------------------
-- Handlers
-- ---------------------------------------------------------------

local function handleRegister(id, msg)
  local username = msg.username
  if type(username) ~= "string" or username == "" or #username > 20 then
    rednet.send(id, { type = "register_fail", reason = "invalid username" }, PROTOCOL)
    return
  end
  if not users[username] then
    users[username] = { registeredAt = os.epoch and os.epoch("utc") or os.time() }
    saveUsers()
  end
  onlineMap[username] = id
  rednet.send(id, { type = "register_ok", username = username }, PROTOCOL)
  log(username .. " connected (id " .. id .. ")")
end

local function usernameById(id)
  for name, uid in pairs(onlineMap) do
    if uid == id then return name end
  end
  return nil
end

local function handleListChannels(id, msg)
  local username = usernameById(id)
  local list = {}
  for name, ch in pairs(channels) do
    local memberCount = 0
    for _ in pairs(ch.members) do memberCount = memberCount + 1 end
    table.insert(list, {
      name = name,
      ctype = ch.ctype,
      description = ch.description,
      owner = ch.owner,
      members = memberCount,
      joined = username ~= nil and ch.members[username] == true,
    })
  end
  rednet.send(id, { type = "channel_list", channels = list }, PROTOCOL)
end

local function handleCreateChannel(id, msg)
  local username = usernameById(id)
  if not username then
    rednet.send(id, { type = "error", message = "not registered" }, PROTOCOL)
    return
  end
  local name = msg.name
  local ctype = msg.ctype == "channel" and "channel" or "group"
  if type(name) ~= "string" or name == "" or name:find("[^%w_%-]") then
    rednet.send(id, { type = "channel_create_fail", reason = "invalid name (use letters/digits/_/-)" }, PROTOCOL)
    return
  end
  if channels[name] then
    rednet.send(id, { type = "channel_create_fail", reason = "already exists" }, PROTOCOL)
    return
  end
  channels[name] = {
    ctype = ctype,
    owner = username,
    description = msg.description or "",
    members = { [username] = true },
    history = {},
  }
  saveChannels()
  rednet.send(id, { type = "channel_created", name = name, ctype = ctype }, PROTOCOL)
  log(username .. " created " .. ctype .. " '" .. name .. "'")
end

local function handleJoin(id, msg)
  local username = usernameById(id)
  if not username then return end
  local ch = channels[msg.name]
  if not ch then
    rednet.send(id, { type = "join_fail", reason = "no such channel" }, PROTOCOL)
    return
  end
  ch.members[username] = true
  saveChannels()
  rednet.send(id, { type = "joined", name = msg.name, ctype = ch.ctype, description = ch.description }, PROTOCOL)
  log(username .. " joined '" .. msg.name .. "'")
end

local function handleLeave(id, msg)
  local username = usernameById(id)
  if not username then return end
  local ch = channels[msg.name]
  if not ch then return end
  ch.members[username] = nil
  saveChannels()
  rednet.send(id, { type = "left", name = msg.name }, PROTOCOL)
end

local function handleSendMessage(id, msg)
  local username = usernameById(id)
  if not username then
    rednet.send(id, { type = "error", message = "not registered" }, PROTOCOL)
    return
  end
  local ch = channels[msg.channel]
  if not ch then
    rednet.send(id, { type = "error", message = "no such channel" }, PROTOCOL)
    return
  end
  if not ch.members[username] then
    rednet.send(id, { type = "error", message = "you have not joined '" .. msg.channel .. "'" }, PROTOCOL)
    return
  end
  if ch.ctype == "channel" and ch.owner ~= username then
    rednet.send(id, { type = "error", message = "only the owner can post in this channel" }, PROTOCOL)
    return
  end
  local time = os.date and os.date("%H:%M") or tostring(os.time())
  local entry = { channel = msg.channel, from = username, text = tostring(msg.text), time = time }
  pushHistory(ch, entry)
  saveChannels()
  broadcast(ch, entry, nil)
end

local function handleGetHistory(id, msg)
  local ch = channels[msg.channel]
  if not ch then
    rednet.send(id, { type = "error", message = "no such channel" }, PROTOCOL)
    return
  end
  rednet.send(id, { type = "history", channel = msg.channel, messages = ch.history }, PROTOCOL)
end

local function handleListUsers(id, msg)
  local list = {}
  for name, _ in pairs(users) do
    table.insert(list, { username = name, online = onlineMap[name] ~= nil })
  end
  rednet.send(id, { type = "user_list", users = list }, PROTOCOL)
end

local function handleDM(id, msg)
  local username = usernameById(id)
  if not username then return end
  local toUser = msg.to
  if not users[toUser] then
    rednet.send(id, { type = "error", message = "no such user '" .. tostring(toUser) .. "'" }, PROTOCOL)
    return
  end
  local time = os.date and os.date("%H:%M") or tostring(os.time())
  if onlineMap[toUser] then
    send(toUser, { type = "dm_message", from = username, text = tostring(msg.text), time = time })
    rednet.send(id, { type = "dm_sent", to = toUser }, PROTOCOL)
  else
    rednet.send(id, { type = "error", message = toUser .. " is offline, message not delivered" }, PROTOCOL)
  end
end

-- ---------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------

local handlers = {
  register       = handleRegister,
  list_channels  = handleListChannels,
  create_channel = handleCreateChannel,
  join_channel   = handleJoin,
  leave_channel  = handleLeave,
  send_message   = handleSendMessage,
  get_history    = handleGetHistory,
  list_users     = handleListUsers,
  dm             = handleDM,
}

local function main()
  loadAll()
  if not openModem() then
    print("No modem attached. Attach a wireless or ender modem and rerun.")
    return
  end
  rednet.host(PROTOCOL, HOSTNAME)
  log("Minegram server started. Hostname: " .. HOSTNAME)
  print("Listening for connections...")

  while true do
    local id, msg = rednet.receive(PROTOCOL)
    if type(msg) == "table" and type(msg.type) == "string" then
      local handler = handlers[msg.type]
      if handler then
        local ok, err = pcall(handler, id, msg)
        if not ok then
          log("Handler error (" .. msg.type .. "): " .. tostring(err))
        end
      end
    end
  end
end

main()
