-- ============================================================
--  satellites - a real 3D spinning Earth (proper sphere geometry,
--  rotation matrices, Lambert lighting) with satellites tracked in
--  orbit around it. Satellites are added/managed with the separate
--  `satellites-admin` tool.
--
--  Satellite motion is REAL TIME: each one advances along its
--  orbit once per real-world minute (based on its configured
--  orbital period), not once per animation frame - so it looks
--  slow and deliberate, the way an actual satellite pass would.
--  Each is drawn as a small solar-panel glyph oriented in its
--  direction of travel, with a short fading trail behind it showing
--  where it's been.
--
--  Click (mouse) or tap (monitor) a satellite marker to see its
--  full info: name, description, signal strength, orbital
--  parameters and every computer connected to it. Click/tap or
--  press any key again to return to the orbit view. Press q to
--  quit.
--
--  If a modem is attached, this also listens for satellite catalogs
--  broadcast by `satellites-admin serve` on another computer, and
--  merges them in live - handy for a remote tracking-station
--  computer that doesn't have its own local satellites.json.
--
--  Repository: https://github.com/hez1ch/bad
-- ============================================================

local SHADES = " .:-=+*#%@"
local CAM_TILT = 0.35        -- fixed camera tilt (radians)
local ORBIT_TICK_SECONDS = 60 -- satellites advance once per real minute
local MARKER_CLICK_TOLERANCE = 2 -- how many cells away a click/tap can
                                  -- land from a satellite marker and
                                  -- still count as hitting it
local TRAIL_MAX_POINTS = 6    -- how many past positions to fade out behind a satellite
local NET_PROTOCOL = "bad-satellites" -- must match satellites-admin's serve command

local DATA_DIR  = "/.satellites"
local DATA_FILE = DATA_DIR .. "/satellites.json"

-- ---------------------------------------------------------------
-- Optional/required shared libraries
-- ---------------------------------------------------------------

local function loadLib(candidates)
  for _, p in ipairs(candidates) do
    if fs.exists(p) then
      local ok, lib = pcall(dofile, p)
      if ok and lib then return lib end
    end
  end
  return nil
end

local monlib = loadLib({ "/lib/monitor.lua", "/.bad/lib/monitor.lua" })
local threed = loadLib({ "/lib/threed.lua", "/.bad/lib/threed.lua" })

-- Opens the first modem we can find (wireless or wired) for rednet,
-- so we can passively listen for a `satellites-admin serve` catalog
-- broadcast. Entirely optional - returns nil and we just skip the
-- networking feature if there's no modem attached.
local function openAnyModem()
  if not (peripheral and rednet) then return nil end
  local ok, names = pcall(peripheral.getNames)
  if not ok then return nil end
  for _, side in ipairs(names) do
    if peripheral.getType(side) == "modem" then
      if rednet.isOpen(side) then return side end
      if pcall(rednet.open, side) then return side end
    end
  end
  return nil
end

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
-- Orbit math (real time based)
-- ---------------------------------------------------------------

-- Advances every satellite's `angle` to account for real time elapsed
-- since its `lastTick`, based on its own orbital period (minutes for
-- a full 360-degree revolution). Mutates `data` in place and returns
-- true if anything changed (so the caller knows whether to save).
local function advanceOrbits(data)
  local changed = false
  local t = now()
  for _, sat in pairs(data) do
    sat.lastTick = sat.lastTick or t
    local elapsedMinutes = (t - sat.lastTick) / 60000
    if elapsedMinutes > 0 and sat.period and sat.period > 0 then
      local degPerMinute = 360 / sat.period
      sat.angle = ((sat.angle or 0) + degPerMinute * elapsedMinutes) % 360
      sat.lastTick = t
      changed = true
    end
  end
  return changed
end

-- World-space position of a satellite on its (tilted, circular)
-- orbit, in Earth-radii units. Pure function of its stored fields -
-- easy to unit test independently of any rendering.
local function satellitePosition(sat)
  local rad = math.rad(sat.angle or 0)
  local local_ = { x = sat.orbitRadius * math.cos(rad), y = 0, z = sat.orbitRadius * math.sin(rad) }
  return threed.rotateX(local_, math.rad(sat.inclination or 0))
end

-- Screen position of a satellite, given the target's projection
-- geometry. A pure function of the satellite's own fields, so it can
-- also be evaluated for a slightly-advanced "ghost" angle to work out
-- which way it's heading (see headingChar below).
local function satScreenPos(sat, geom)
  local worldPos = satellitePosition(sat)
  local camPos = threed.rotateX(worldPos, CAM_TILT)
  local dx, dy = threed.project(camPos, geom.scaleX, geom.scaleY)
  local sx = geom.cx + math.floor(dx + 0.5)
  local sy = geom.cy + math.floor(dy + 0.5)
  return sx, sy
end

-- Picks a single character (>,<,^,v,/,\) that best matches the
-- direction a satellite is currently moving on screen, so its glyph
-- visibly points the way it's flying rather than sitting there as a
-- plain, direction-less dot.
local function headingChar(dx, dy)
  if dx == 0 and dy == 0 then return "o" end
  local h, v = math.abs(dx), math.abs(dy)
  if h > v * 2 then
    return dx > 0 and ">" or "<"
  elseif v > h * 2 then
    return dy > 0 and "v" or "^"
  else
    if (dx > 0) == (dy < 0) then return "/" else return "\\" end
  end
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- ---------------------------------------------------------------
-- Earth surface classification (deterministic "continents" pattern -
-- a fixed function of each point's own coordinates, so it rotates
-- naturally with the globe instead of jittering between frames)
--
-- Blends five sine/cosine harmonics at different frequencies/weights
-- (a cheap stand-in for Perlin-style noise) so the coastline reads as
-- organic continent-ish shapes rather than a handful of same-sized
-- blobs. The 0.23 threshold was picked to land at roughly Earth's
-- real ~29% land coverage. Points near the poles (|y| beyond 0.82)
-- are classified as polar ice regardless, so the globe gets visible
-- ice caps like the real thing.
-- ---------------------------------------------------------------

local LAND_THRESHOLD = 0.23
local ICE_LATITUDE = 0.82

local function classifyPoint(p)
  if p.y > ICE_LATITUDE or p.y < -ICE_LATITUDE then
    return "ice"
  end
  local v = math.sin(p.x * 5 + p.z * 3) * 0.5
          + math.cos(p.y * 4 - p.x * 2) * 0.35
          + math.sin(p.z * 6 + p.y * 2) * 0.3
          + math.sin(p.x * 11 - p.z * 7) * 0.15
          + math.cos(p.x * 2 + p.y * 2 + p.z * 2) * 0.2
  return (v > LAND_THRESHOLD) and "land" or "ocean"
end

-- ---------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------

-- Sphere radius (in character cells) that best fills a screen of
-- w x h without touching the edges. Leaves a couple of rows for the
-- header/footer text and a small side margin. No arbitrary low cap -
-- a big monitor gets a big, detailed Earth instead of the same tiny
-- globe as a Pocket Computer.
local function computeScale(w, h)
  local scaleX = math.max(4, math.min(math.floor((w - 4) / 2), h - 3))
  local scaleY = math.max(2, math.floor(scaleX / 2))
  return scaleX, scaleY
end

-- Sphere sampling resolution scaled to how big it'll actually be
-- drawn, so a large monitor gets a smoothly-sampled globe instead of
-- gappy/blocky sparse points, while a small terminal doesn't waste
-- cycles on detail nobody can see. Capped for performance.
local function computeResolution(scaleX, scaleY)
  local lonSteps = clamp(math.floor(scaleX * 1.6), 24, 60)
  local latSteps = clamp(math.floor(scaleY * 1.8), 12, 30)
  return latSteps, lonSteps
end

local function buildGeometry(w, h)
  local cx, cy = math.floor(w / 2), math.floor(h / 2)
  local scaleX, scaleY = computeScale(w, h)

  local stars = {}
  for i = 1, math.floor(w * h / 45) do
    local sx = math.random(1, w)
    local sy = math.random(1, h)
    stars[#stars + 1] = { x = sx, y = sy, ch = (math.random(1, 4) == 1) and "*" or "." }
  end

  return { cx = cx, cy = cy, scaleX = scaleX, scaleY = scaleY, stars = stars }
end

-- Looks at the terminal and every attached monitor to find the
-- largest scale the scene will ever be drawn at, so the shared
-- sphere point-cloud is sampled finely enough for the biggest screen
-- it'll be mirrored to.
local function maxSceneScale(monlib)
  local maxX, maxY = computeScale(term.getSize())
  if monlib then
    for _, entry in ipairs(monlib.list()) do
      local ok, w, h = pcall(entry.mon.getSize)
      if ok and w and h then
        local sx, sy = computeScale(w, h)
        if sx > maxX then maxX = sx end
        if sy > maxY then maxY = sy end
      end
    end
  end
  return maxX, maxY
end

local function main()
  if not threed then
    print("satellites needs the shared 3D library to draw its scene.")
    print("Install it with: bad install threed")
    print("(or copy /lib/threed.lua manually)")
    return
  end

  math.randomseed((os.epoch and os.epoch("utc") or os.time()) % 100000)
  local LIGHT = threed.normalize({ x = -0.4, y = 0.5, z = 1 })

  -- Real 3D Earth: a unit sphere sampled once, plus a fixed
  -- land/ocean/ice classification per point (computed once, carried
  -- through rotation via `extras`, never re-randomized). Resolution
  -- is picked to match the largest screen (terminal or any mirrored
  -- monitor) this will actually be drawn on.
  local maxScaleX, maxScaleY = maxSceneScale(monlib)
  local EARTH_RES_LAT, EARTH_RES_LON = computeResolution(maxScaleX, maxScaleY)
  local earthPts = threed.sphere(EARTH_RES_LAT, EARTH_RES_LON)
  local earthLand = {}
  for i, p in ipairs(earthPts) do
    earthLand[i] = classifyPoint(p)
  end

  local geomByTarget = {}
  local lastMarkers = {} -- targetName -> { {id=,sx=,sy=}, ... } from the last orbit-view draw
  local frame = 0
  local running = true
  local mode = "orbit" -- "orbit" | "detail"
  local selectedId = nil

  local function loadAndCatchUp()
    local data = loadData()
    if advanceOrbits(data) then
      saveData(data)
    end
    return data
  end

  local satData = loadAndCatchUp()

  -- Picks up satellites added/edited/removed via `satellites-admin`
  -- *while this viewer is already open*, without needing a restart.
  -- Keeps each existing satellite's in-memory `angle`/`lastTick` (so a
  -- satellite mid-orbit doesn't visibly jump), but takes everything
  -- else - including brand new satellites - fresh from disk.
  local RELOAD_TICK_SECONDS = 5
  local function reloadFromDisk()
    local diskData = loadData()
    local changed = false

    for id, diskSat in pairs(diskData) do
      local cur = satData[id]
      if not cur then
        satData[id] = diskSat
        changed = true
      else
        for k, v in pairs(diskSat) do
          if k ~= "angle" and k ~= "lastTick" and cur[k] ~= v then
            cur[k] = v
            changed = true
          end
        end
      end
    end

    for id in pairs(satData) do
      if not diskData[id] then
        satData[id] = nil
        changed = true
      end
    end

    return changed
  end

  -- Merges a catalog received over the network (from a
  -- `satellites-admin serve` broadcast). Additive only - it never
  -- removes a locally-known satellite just because a given broadcast
  -- didn't happen to mention it, since the network is a supplemental
  -- source, not necessarily the whole picture.
  local function mergeFromNetwork(newData)
    local changed = false
    for id, incoming in pairs(newData) do
      local cur = satData[id]
      if not cur then
        satData[id] = incoming
        changed = true
      else
        for k, v in pairs(incoming) do
          if k ~= "angle" and k ~= "lastTick" and cur[k] ~= v then
            cur[k] = v
            changed = true
          end
        end
      end
    end
    return changed
  end

  local netSide = openAnyModem()

  -- Short fading trail of each satellite's last few real positions,
  -- per render target (a monitor and the terminal can have different
  -- scales/projections). Recorded once per real orbit tick, not once
  -- per animation frame, since that's the only point positions
  -- actually change.
  local trails = {} -- targetName -> id -> { {sx=,sy=}, ... }

  local function recordTrails()
    for targetName, geom in pairs(geomByTarget) do
      local t = trails[targetName]
      if not t then t = {}; trails[targetName] = t end
      for id, sat in pairs(satData) do
        local sx, sy = satScreenPos(sat, geom)
        local list = t[id]
        if not list then list = {}; t[id] = list end
        local last = list[#list]
        if not last or last.sx ~= sx or last.sy ~= sy then
          list[#list + 1] = { sx = sx, sy = sy }
          while #list > TRAIL_MAX_POINTS do table.remove(list, 1) end
        end
      end
      for id in pairs(t) do
        if not satData[id] then t[id] = nil end
      end
    end
  end

  local function drawOrbit(w, h, targetName)
    local colorOk = term.isColor and term.isColor()
    local geom = geomByTarget[targetName]
    if not geom then
      geom = buildGeometry(w, h)
      geomByTarget[targetName] = geom
    end

    term.setBackgroundColor(colors and colors.black or nil)
    term.clear()

    if colorOk then term.setTextColor(colors.gray) end
    for _, s in ipairs(geom.stars) do
      term.setCursorPos(s.x, s.y)
      term.write(s.ch)
    end

    local spin = frame * 0.04
    local buffer = threed.rasterizeSphere(
      earthPts, spin, CAM_TILT, LIGHT,
      geom.scaleX, geom.scaleY, geom.cx, geom.cy, w, h, earthLand
    )
    for _, cell in ipairs(buffer) do
      local idx = clamp(math.floor(cell.shade * (#SHADES - 1)) + 1, 1, #SHADES)
      if colorOk then
        if cell.extra == "ice" then
          term.setTextColor(cell.shade > 0.4 and colors.white or colors.lightGray)
        elseif cell.extra == "land" then
          term.setTextColor(cell.shade > 0.5 and colors.lime or colors.green)
        else
          term.setTextColor(cell.shade > 0.5 and colors.lightBlue or colors.blue)
        end
      end
      term.setCursorPos(cell.sx, cell.sy)
      term.write(SHADES:sub(idx, idx))
    end

    -- satellites: each one's REAL orbital position (angle only moves
    -- once per real minute - see advanceOrbits), spinning around with
    -- the same camera tilt as the Earth so they sit in the same scene.
    -- Drawn as a small 3-cell glyph ("=" solar panels either side of a
    -- direction arrow) so it reads as a spacecraft rather than a dot,
    -- with a short fading trail behind it showing its recent track.
    local markers = {}
    local targetTrails = trails[targetName]
    for id, sat in pairs(satData) do
      local sx, sy = satScreenPos(sat, geom)
      if sx >= 1 and sx <= w and sy >= 1 and sy <= h then
        -- fading trail (older points first; the most recent one is
        -- ~ the current position, so skip it - the glyph covers it)
        local list = targetTrails and targetTrails[id]
        if list then
          for i = 1, #list - 1 do
            local pt = list[i]
            if pt.sx ~= sx or pt.sy ~= sy then
              if colorOk then term.setTextColor(colors.gray) end
              term.setCursorPos(pt.sx, pt.sy)
              term.write(i >= #list - 2 and ":" or ".")
            end
          end
        end

        -- heading: sample the orbit slightly ahead to see which way
        -- the satellite is actually flying right now
        local aheadSx, aheadSy = satScreenPos(
          { angle = ((sat.angle or 0) + 3) % 360, inclination = sat.inclination, orbitRadius = sat.orbitRadius },
          geom
        )
        local dirCh = headingChar(aheadSx - sx, aheadSy - sy)

        local bodyColor = colors.orange
        if sat.signal then
          if sat.signal >= 70 then bodyColor = colors.lime
          elseif sat.signal < 30 then bodyColor = colors.red end
        end

        if sx - 1 >= 1 then
          if colorOk then term.setTextColor(colors.yellow) end
          term.setCursorPos(sx - 1, sy)
          term.write("=")
        end
        if colorOk then term.setTextColor(bodyColor) end
        term.setCursorPos(sx, sy)
        term.write(dirCh)
        if sx + 1 <= w then
          if colorOk then term.setTextColor(colors.yellow) end
          term.setCursorPos(sx + 1, sy)
          term.write("=")
        end

        markers[#markers + 1] = { id = id, sx = sx, sy = sy }
      end
    end
    lastMarkers[targetName] = markers

    if colorOk then term.setTextColor(colors.white) end
    term.setCursorPos(1, h)
    local count = 0
    for _ in pairs(satData) do count = count + 1 end
    local netTag = netSide and (" | net:" .. netSide) or ""
    term.write("satellites (" .. count .. ")" .. netTag .. " - click one for info, q to quit")
  end

  local function drawDetail(w, h)
    local colorOk = term.isColor and term.isColor()
    term.setBackgroundColor(colors and colors.black or nil)
    term.clear()
    term.setCursorPos(1, 1)

    local sat = satData[selectedId]
    if not sat then
      term.write("(satellite no longer exists)")
      term.setCursorPos(1, h)
      term.write("click / press any key to go back")
      return
    end

    if colorOk then term.setTextColor(colors.yellow) end
    term.write(tostring(sat.name) .. "  [" .. tostring(selectedId) .. "]")
    if colorOk then term.setTextColor(colors.white) end

    local row = 3
    local function line(label, value)
      if row >= h then return end
      term.setCursorPos(1, row)
      if colorOk then term.setTextColor(colors.lightGray) end
      term.write(label .. ": ")
      if colorOk then term.setTextColor(colors.white) end
      term.write(tostring(value))
      row = row + 1
    end

    line("Description", sat.description ~= "" and sat.description or "(none)")
    line("Signal strength", tostring(sat.signal) .. "%")
    line("Orbital period", tostring(sat.period) .. " min/orbit")
    line("Inclination", tostring(sat.inclination) .. " deg")
    line("Orbit radius", tostring(sat.orbitRadius) .. " Earth radii")
    line("Current angle", string.format("%.1f", sat.angle or 0) .. " deg")

    row = row + 1
    if row < h then
      term.setCursorPos(1, row)
      if colorOk then term.setTextColor(colors.lightGray) end
      term.write("Connected computers:")
      row = row + 1
    end
    if sat.computers and #sat.computers > 0 then
      for _, c in ipairs(sat.computers) do
        if row >= h then break end
        term.setCursorPos(1, row)
        if colorOk then term.setTextColor(colors.white) end
        term.write("  #" .. tostring(c.id) .. " - " .. tostring(c.name))
        row = row + 1
      end
    else
      if row < h then
        term.setCursorPos(1, row)
        term.write("  (none connected)")
      end
    end

    if colorOk then term.setTextColor(colors.gray) end
    term.setCursorPos(1, h)
    term.write("click / press any key to go back")
  end

  local function render(w, h, targetName)
    if mode == "detail" then
      drawDetail(w, h)
    else
      drawOrbit(w, h, targetName)
    end
  end

  local function renderFrame()
    if monlib then
      monlib.renderAll(render)
    else
      local w, h = term.getSize()
      render(w, h, "term")
    end
  end

  renderFrame()

  -- Earth keeps spinning smoothly; satellites only actually move once
  -- a real minute, but we still redraw regularly so clicks feel snappy.
  local function animate()
    while running do
      sleep(0.2)
      if mode == "orbit" then
        frame = frame + 1
      end
      renderFrame()
    end
  end

  -- Advances satellite orbital positions once per real minute.
  local function orbitUpdater()
    recordTrails() -- capture the starting position so the trail has something to fade from
    while running do
      sleep(ORBIT_TICK_SECONDS)
      if advanceOrbits(satData) then
        saveData(satData)
      end
      recordTrails()
    end
  end

  -- Picks up new/edited/removed satellites from `satellites-admin`
  -- every few seconds, so you don't have to close and reopen this
  -- viewer to see something you just added.
  local function dataRefresher()
    while running do
      sleep(RELOAD_TICK_SECONDS)
      if reloadFromDisk() then
        renderFrame()
      end
    end
  end

  -- Passively listens for satellite catalogs broadcast by
  -- `satellites-admin serve` on another computer over rednet, and
  -- merges anything new/changed in live. A no-op loop (never
  -- returning, so it doesn't disturb parallel.waitForAny) if there's
  -- no modem attached.
  local function networkListener()
    while running do
      if netSide then
        local _, msg = rednet.receive(NET_PROTOCOL, 5)
        if type(msg) == "table" and msg.type == "catalog" and type(msg.data) == "table" then
          if mergeFromNetwork(msg.data) then
            renderFrame()
          end
        end
      else
        sleep(5)
      end
    end
  end

  local function nearestMarker(markers, x, y, maxDist)
    local best, bestDist = nil, nil
    for _, m in ipairs(markers) do
      local d = math.abs(m.sx - x) + math.abs(m.sy - y)
      if d <= maxDist and (not bestDist or d < bestDist) then
        best, bestDist = m.id, d
      end
    end
    return best
  end

  local function watchInput()
    while running do
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

      if mode == "orbit" then
        if ev.type == "click" then
          local markers = lastMarkers[ev.source] or lastMarkers["term"] or {}
          local hit = nearestMarker(markers, ev.x, ev.y, MARKER_CLICK_TOLERANCE)
          if hit then
            selectedId = hit
            mode = "detail"
            renderFrame()
          end
        elseif (ev.type == "key" and ev.key == keys.q) or (ev.type == "char" and ev.char == "q") then
          running = false
        end
      else -- mode == "detail"
        if ev.type == "click" or ev.type == "key" or ev.type == "char" then
          mode = "orbit"
          selectedId = nil
          renderFrame()
        end
      end
    end
  end

  parallel.waitForAny(animate, orbitUpdater, dataRefresher, networkListener, watchInput)

  term.setBackgroundColor(colors and colors.black or nil)
  term.clear()
  term.setCursorPos(1, 1)
  if term.isColor and term.isColor() then term.setTextColor(colors.white) end
  print("satellites closed.")
end

local ok, err = pcall(main)
if not ok then
  term.setBackgroundColor(colors and colors.black or nil)
  if term.isColor and term.isColor() then term.setTextColor(colors.red) end
  print("satellites crashed: " .. tostring(err))
end
