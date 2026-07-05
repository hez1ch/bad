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

-- Optional shared monitor-mirroring library - if present, the
-- now-playing box is also drawn on every attached monitor, e.g. a
-- monitor mounted as a little "jukebox display" next to a speaker.
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
-- Cyrillic -> Latin transliteration
-- (CC: Tweaked's default font doesn't render Cyrillic, so any
-- Cyrillic text coming from track/artist/album names is converted
-- to a readable Latin approximation before being displayed.)
-- ---------------------------------------------------------------

local CYRILLIC_MAP = {
  ["\208\176"] = "a",
  ["\208\144"] = "A",
  ["\208\177"] = "b",
  ["\208\145"] = "B",
  ["\208\178"] = "v",
  ["\208\146"] = "V",
  ["\208\179"] = "g",
  ["\208\147"] = "G",
  ["\208\180"] = "d",
  ["\208\148"] = "D",
  ["\208\181"] = "e",
  ["\208\149"] = "E",
  ["\209\145"] = "e",
  ["\208\129"] = "E",
  ["\208\182"] = "zh",
  ["\208\150"] = "Zh",
  ["\208\183"] = "z",
  ["\208\151"] = "Z",
  ["\208\184"] = "i",
  ["\208\152"] = "I",
  ["\208\185"] = "y",
  ["\208\153"] = "Y",
  ["\208\186"] = "k",
  ["\208\154"] = "K",
  ["\208\187"] = "l",
  ["\208\155"] = "L",
  ["\208\188"] = "m",
  ["\208\156"] = "M",
  ["\208\189"] = "n",
  ["\208\157"] = "N",
  ["\208\190"] = "o",
  ["\208\158"] = "O",
  ["\208\191"] = "p",
  ["\208\159"] = "P",
  ["\209\128"] = "r",
  ["\208\160"] = "R",
  ["\209\129"] = "s",
  ["\208\161"] = "S",
  ["\209\130"] = "t",
  ["\208\162"] = "T",
  ["\209\131"] = "u",
  ["\208\163"] = "U",
  ["\209\132"] = "f",
  ["\208\164"] = "F",
  ["\209\133"] = "h",
  ["\208\165"] = "H",
  ["\209\134"] = "ts",
  ["\208\166"] = "Ts",
  ["\209\135"] = "ch",
  ["\208\167"] = "Ch",
  ["\209\136"] = "sh",
  ["\208\168"] = "Sh",
  ["\209\137"] = "sch",
  ["\208\169"] = "Sch",
  ["\209\138"] = "",
  ["\208\170"] = "",
  ["\209\139"] = "y",
  ["\208\171"] = "Y",
  ["\209\140"] = "",
  ["\208\172"] = "",
  ["\209\141"] = "e",
  ["\208\173"] = "E",
  ["\209\142"] = "yu",
  ["\208\174"] = "Yu",
  ["\209\143"] = "ya",
  ["\208\175"] = "Ya",
}

-- Walks the string byte by byte; whenever a UTF-8 sequence matches a
-- known Cyrillic character it's replaced with its Latin equivalent.
-- Anything else (plain ASCII, or other scripts) passes through as-is.
local function transliterate(text)
  if not text or text == "" then return text end
  local out = {}
  local i = 1
  local len = #text
  while i <= len do
    local b = text:byte(i)
    local seqLen = 1
    if b >= 0xF0 then seqLen = 4
    elseif b >= 0xE0 then seqLen = 3
    elseif b >= 0xC0 then seqLen = 2 end

    if seqLen > 1 and i + seqLen - 1 <= len then
      local seq = text:sub(i, i + seqLen - 1)
      local mapped = CYRILLIC_MAP[seq]
      out[#out + 1] = mapped or seq
      i = i + seqLen
    else
      out[#out + 1] = string.char(b)
      i = i + 1
    end
  end
  return table.concat(out)
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

local function drawBox(cfg, track, err, lastUpdate, w, h)
  term.clear()
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

  line(top + 1, " " .. centerPad("lastfm - " .. transliterate(cfg.username), boxW - 4), colors and colors.orange or nil)

  if err then
    line(top + 3, " " .. centerPad("Error:", boxW - 4), colors and colors.red or nil)
    line(top + 4, " " .. centerPad(truncate(err, boxW - 4), boxW - 4), colors and colors.red or nil)
  elseif track then
    local isNowPlaying = track["@attr"] and track["@attr"].nowplaying == "true"
    local status = isNowPlaying and "> NOW PLAYING" or "  LAST PLAYED"
    line(top + 3, " " .. centerPad(status, boxW - 4),
      isNowPlaying and (colors and colors.lime or nil) or (colors and colors.gray or nil))

    local artist = transliterate((track.artist and (track.artist["#text"] or track.artist.name)) or "Unknown artist")
    local name = transliterate(track.name or "Unknown track")
    local album = transliterate(track.album and track.album["#text"] or "")

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
    if monlib then
      monlib.renderAll(function(w, h)
        drawBox(cfg, track, err, lastUpdate, w, h)
      end)
    else
      local w, h = term.getSize()
      drawBox(cfg, track, err, lastUpdate, w, h)
    end
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
    elseif event == "monitor_touch" then
      -- tapping a mirrored monitor works like pressing 'r'
      refresh()
    end
  end

  term.clear()
  term.setCursorPos(1, 1)
  print("lastfm closed.")
end

main()
