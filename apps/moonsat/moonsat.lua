-- ============================================================
--  moonsat - an ASCII screensaver: a spinning moon with a
--  little radio satellite orbiting around it.
--
--  Press q to quit.
--
--  Repository: https://github.com/hez1ch/bad
-- ============================================================

local SHADES = " .:-=+*#%@"

-- Optional shared monitor-mirroring library - if present, the moon
-- animation is also drawn on every attached monitor. Falls back to
-- terminal-only if the library isn't installed.
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

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- Builds the (fixed) geometry - moon size, orbit radius, star field -
-- for one particular screen size. Each mirrored target (terminal,
-- each monitor) gets its own geometry computed once and cached, so
-- monitors of a different size than the terminal still look right
-- and the star field doesn't jump around between frames.
local function buildGeometry(w, h)
  local cx, cy = math.floor(w / 2), math.floor(h / 2)
  local moonRx = math.min(math.floor(w / 5), 10)
  local moonRy = math.max(3, math.floor(moonRx / 2))
  local orbitRx = moonRx + 6
  local orbitRy = moonRy + 3

  local stars = {}
  for i = 1, math.floor(w * h / 40) do
    local sx = math.random(1, w)
    local sy = math.random(1, h)
    -- keep stars off the moon/orbit area
    local dx = (sx - cx) / orbitRx
    local dy = (sy - cy) / orbitRy
    if dx * dx + dy * dy > 1.3 then
      stars[#stars + 1] = { x = sx, y = sy, ch = (math.random(1, 3) == 1) and "*" or "." }
    end
  end

  return {
    cx = cx, cy = cy,
    moonRx = moonRx, moonRy = moonRy,
    orbitRx = orbitRx, orbitRy = orbitRy,
    stars = stars,
  }
end

local function main()
  math.randomseed((os.epoch and os.epoch("utc") or os.time()) % 100000)

  local geomByTarget = {}
  local frame = 0
  local running = true

  local function draw(w, h, targetName)
    local colorOk = term.isColor and term.isColor()
    local geom = geomByTarget[targetName]
    if not geom then
      geom = buildGeometry(w, h)
      geomByTarget[targetName] = geom
    end

    term.setBackgroundColor(colors and colors.black or nil)
    term.clear()

    -- stars
    if colorOk then term.setTextColor(colors.gray) end
    for _, s in ipairs(geom.stars) do
      term.setCursorPos(s.x, s.y)
      term.write(s.ch)
    end

    -- moon (shaded sphere, texture scrolls sideways each frame to
    -- fake rotation)
    for dy = -geom.moonRy, geom.moonRy do
      local ny = dy / geom.moonRy
      for dx = -geom.moonRx, geom.moonRx do
        local nx = dx / geom.moonRx
        if nx * nx + ny * ny <= 1 then
          local shade = math.sin((dx + frame * 0.6) * 0.5) * 0.5
                      + math.cos(dy * 0.9) * 0.5
          -- darker toward the rim for a spherical look
          local rim = 1 - (nx * nx + ny * ny)
          shade = shade * 0.6 + rim * 0.4
          local idx = clamp(math.floor((shade + 1) / 2 * (#SHADES - 1)) + 1, 1, #SHADES)
          local ch = SHADES:sub(idx, idx)
          if colorOk then term.setTextColor(colors.lightGray) end
          term.setCursorPos(geom.cx + dx, geom.cy + dy)
          term.write(ch)
        end
      end
    end

    -- orbiting satellite
    local angle = frame * 0.12
    local sx = geom.cx + math.floor(geom.orbitRx * math.cos(angle) + 0.5)
    local sy = geom.cy + math.floor(geom.orbitRy * math.sin(angle) + 0.5)

    if sx >= 2 and sx <= w - 1 and sy >= 1 and sy <= h then
      if colorOk then term.setTextColor(colors.lightBlue) end
      term.setCursorPos(sx - 1, sy)
      term.write("-o-")
      -- little radio blip trailing above it
      if math.floor(frame / 5) % 2 == 0 and sy > 1 then
        if colorOk then term.setTextColor(colors.red) end
        term.setCursorPos(sx, sy - 1)
        term.write(".")
      end
    end

    if colorOk then term.setTextColor(colors.white) end
    term.setCursorPos(1, h)
    term.write("moonsat - press q to quit")
  end

  local function renderFrame()
    if monlib then
      monlib.renderAll(draw)
    else
      local w, h = term.getSize()
      draw(w, h, "term")
    end
  end

  renderFrame()

  local function animate()
    while running do
      sleep(0.15)
      frame = frame + 1
      renderFrame()
    end
  end

  local function watchQuit()
    while running do
      if monlib then
        local ev = monlib.pullEvent()
        if (ev.type == "key" and ev.key == keys.q) or (ev.type == "char" and ev.char == "q")
          or ev.type == "click" then
          running = false
        end
      else
        local event, key = os.pullEvent("key")
        if key == keys.q then
          running = false
        end
      end
    end
  end

  parallel.waitForAny(animate, watchQuit)

  term.setBackgroundColor(colors and colors.black or nil)
  term.clear()
  term.setCursorPos(1, 1)
  if term.isColor and term.isColor() then term.setTextColor(colors.white) end
  print("moonsat closed.")
end

local ok, err = pcall(main)
if not ok then
  term.setBackgroundColor(colors and colors.black or nil)
  if term.isColor and term.isColor() then term.setTextColor(colors.red) end
  print("moonsat crashed: " .. tostring(err))
end
