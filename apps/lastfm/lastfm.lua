-- ============================================================
--  lastfm - a pretty "now playing" viewer powered by Last.fm
--
--  Shows the track you're currently scrobbling (or your last
--  played track) in a nice bordered box, auto-refreshing.
--
--  Requires:
--   - a Last.fm account that is scrobbling (via a desktop/phone
--     scrobbler) so the API has something to show
--   - a free Last.fm API key: https://www.last.fm/api/account/create
--   - ws.audioscrobbler.com whitelisted in the server's
--     computercraft-server.toml HTTP rules
--
--  Repository: https://github.com/hez1ch/bad
-- ============================================================

local CONFIG_DIR  = "/.lastfm"
local CONFIG_FILE = CONFIG_DIR .. "/config.json"
local REFRESH_SEC = 20

-- ---------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------

local function ensureConfigDir()
  if not fs.exists(CONFIG_DIR) then fs.makeDir(CONFIG_DIR) end
end

local function loadConfig()
  if not fs.exists(CONFIG_FILE) then return nil end
  local h = fs.open(CONFIG_FILE, "r")
  local content = h.readAll()
  h.close()
  local ok, data = pcall(textutils.unserializeJSON, content)
  if ok and data then return data end
  return nil
end

local function saveConfig(cfg)
  ensureConfigDir()
  local h = fs.open(CONFIG_FILE, "w")
  h.write(textutils.serializeJSON(cfg))
  h.close()
end

local function setup()
  term.clear() term.setCursorPos(1, 1)
  print("=== lastfm setup ===")
  print("You need a free Last.fm API key:")
  print("https://www.last.fm/api/account/create")
  print("")
  write("Last.fm username: ")
  local user = read()
  write("API key: ")
  local key = read()
  local cfg = { username = user, apikey = key }
  saveConfig(cfg)
  print("Saved. Starting player...")
  sleep(1)
  return cfg
end

-- ---------------------------------------------------------------
-- API
-- ---------------------------------------------------------------

local function fetchRecentTrack(cfg)
  if not http then
    return nil, "HTTP API is disabled on this computer"
  end
  local url = "http://ws.audioscrobbler.com/2.0/?method=user.getrecenttracks"
    .. "&user=" .. textutils.urlEncode(cfg.username)
    .. "&api_key=" .. textutils.urlEncode(cfg.apikey)
    .. "&format=json&limit=1"

  local ok, resp = pcall(http.get, url)
  if not ok or resp == nil then
    return nil, "could not reach ws.audioscrobbler.com (check server whitelist)"
  end
  local body = resp.readAll()
  resp.close()

  local okJson, data = pcall(textutils.unserializeJSON, body)
  if not okJson or not data then
    return nil, "bad response from Last.fm"
  end
  if data.error then
    return nil, tostring(data.message or ("Last.fm error " .. tostring(data.error)))
  end
  local track = data.recenttracks and data.recenttracks.track and data.recenttracks.track[1]
  if not track then
    return nil, "no scrobbles found for this user"
  end
  return track, nil
end

-- ---------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------

local function truncate(text, width)
  if #text > width then
    return text:sub(1, width - 3) .. "..."
  end
  return text
end

local function centerPad(text, width)
  text = truncate(text, width)
  local pad = math.floor((width - #text) / 2)
  return string.rep(" ", math.max(0, pad)) .. text
end

local function drawBox(cfg, track, err, lastUpdate)
  term.clear()
  local w, h = term.getSize()
  local boxW = math.min(w - 2, 48)
  local left = math.floor((w - boxW) / 2) + 1
  local top = 2

  local colorOk = term.isColor and term.isColor()

  local function setFg(c)
    if colorOk then term.setTextColor(c) end
  end

  local function line(y, text, fg)
    term.setCursorPos(left, y)
    setFg(fg or (colors and colors.white or nil))
    term.write(text)
  end

  -- border
  setFg(colors and colors.lightGray or nil)
  term.setCursorPos(left, top)
  term.write("+" .. string.rep("-", boxW - 2) .. "+")
  for y = top + 1, top + 9 do
    term.setCursorPos(left, y)
    term.write("|" .. string.rep(" ", boxW - 2) .. "|")
    term.setCursorPos(left + boxW - 1, y)
    term.write("|")
  end
  term.setCursorPos(left, top + 10)
  term.write("+" .. string.rep("-", boxW - 2) .. "+")

  line(top + 1, " " .. centerPad("lastfm - " .. cfg.username, boxW - 4), colors and colors.orange or nil)

  if err then
    line(top + 3, " " .. centerPad("Error:", boxW - 4), colors and colors.red or nil)
    line(top + 4, " " .. centerPad(truncate(err, boxW - 4), boxW - 4), colors and colors.red or nil)
  elseif track then
    local isNowPlaying = track["@attr"] and track["@attr"].nowplaying == "true"
    local status = isNowPlaying and "> NOW PLAYING" or "  LAST PLAYED"
    line(top + 3, " " .. centerPad(status, boxW - 4),
      isNowPlaying and (colors and colors.lime or nil) or (colors and colors.gray or nil))

    local artist = (track.artist and (track.artist["#text"] or track.artist.name)) or "Unknown artist"
    local name = track.name or "Unknown track"
    local album = track.album and track.album["#text"] or ""

    line(top + 5, " " .. centerPad(truncate(name, boxW - 4), boxW - 4), colors and colors.white or nil)
    line(top + 6, " " .. centerPad(truncate(artist, boxW - 4), boxW - 4), colors and colors.lightBlue or nil)
    if album ~= "" then
      line(top + 7, " " .. centerPad(truncate("on " .. album, boxW - 4), boxW - 4), colors and colors.gray or nil)
    end
  else
    line(top + 4, " " .. centerPad("No data.", boxW - 4), colors and colors.gray or nil)
  end

  setFg(colors and colors.gray or nil)
  term.setCursorPos(left, top + 12)
  term.write("Updated " .. (lastUpdate or "--:--") .. "   [r]efresh  [q]uit")
  setFg(colors and colors.white or nil)
end

-- ---------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------

local function main()
  ensureConfigDir()
  local cfg = loadConfig()
  if not cfg or not cfg.username or not cfg.apikey then
    cfg = setup()
  end

  local running = true
  local track, err, lastUpdate

  local function refresh()
    track, err = fetchRecentTrack(cfg)
    lastUpdate = os.date and os.date("%H:%M:%S") or "?"
    drawBox(cfg, track, err, lastUpdate)
  end

  refresh()

  while running do
    local timerId = os.startTimer(REFRESH_SEC)
    local event, p1 = os.pullEvent()
    if event == "timer" and p1 == timerId then
      refresh()
    elseif event == "key" then
      if p1 == keys.q then
        running = false
      elseif p1 == keys.r then
        refresh()
      end
    end
  end

  term.clear()
  term.setCursorPos(1, 1)
  print("lastfm closed.")
end

main()
