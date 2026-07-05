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
--
--  Click (mouse) or tap (monitor) a satellite marker to see its
--  full info: name, description, signal strength, orbital
--  parameters and every computer connected to it. Click/tap or
--  press any key again to return to the orbit view. Press q to
--  quit.
--
--  Repository: https://github.com/hez1ch/bad
-- ============================================================

local SHADES = " .:-=+*#%@"
local CAM_TILT = 0.35        -- fixed camera tilt (radians)
local ORBIT_TICK_SECONDS = 60 -- satellites advance once per real minute
local MARKER_CLICK_TOLERANCE = 2 -- how many cells away a click/tap can
                                  -- land from a satellite marker and
                                  -- still count as hitting it

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
    -- the same camera tilt as the Earth so they sit in the same scene
    local markers = {}
    for id, sat in pairs(satData) do
      local worldPos = satellitePosition(sat)
      local camPos = threed.rotateX(worldPos, CAM_TILT)
      local dx, dy = threed.project(camPos, geom.scaleX, geom.scaleY)
      local sx = geom.cx + math.floor(dx + 0.5)
      local sy = geom.cy + math.floor(dy + 0.5)
      if sx >= 1 and sx <= w and sy >= 1 and sy <= h then
        if colorOk then term.setTextColor(colors.orange) end
        term.setCursorPos(sx, sy)
        term.write("o")
        markers[#markers + 1] = { id = id, sx = sx, sy = sy }
      end
    end
    lastMarkers[targetName] = markers

    if colorOk then term.setTextColor(colors.white) end
    term.setCursorPos(1, h)
    local count = 0
    for _ in pairs(satData) do count = count + 1 end
    term.write("satellites (" .. count .. ") - click one for info, q to quit")
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
    while running do
      sleep(ORBIT_TICK_SECONDS)
      if advanceOrbits(satData) then
        saveData(satData)
      end
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

  parallel.waitForAny(animate, orbitUpdater, dataRefresher, watchInput)

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
