-- ============================================================
--  moonsat - an ASCII screensaver: a spinning moon with a
--  little radio satellite orbiting around it.
--
--  Press q to quit.
--
--  Repository: https://github.com/hez1ch/bad
-- ============================================================

local SHADES = " .:-=+*#%@"

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function main()
  local w, h = term.getSize()
  local colorOk = term.isColor and term.isColor()

  local cx, cy = math.floor(w / 2), math.floor(h / 2)
  local moonRx = math.min(math.floor(w / 5), 10)
  local moonRy = math.max(3, math.floor(moonRx / 2))

  local orbitRx = moonRx + 6
  local orbitRy = moonRy + 3

  -- fixed background stars
  math.randomseed((os.epoch and os.epoch("utc") or os.time()) % 100000)
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

  local frame = 0
  local running = true

  local function draw()
    term.setBackgroundColor(colors and colors.black or nil)
    term.clear()

    -- stars
    if colorOk then term.setTextColor(colors.gray) end
    for _, s in ipairs(stars) do
      term.setCursorPos(s.x, s.y)
      term.write(s.ch)
    end

    -- moon (shaded sphere, texture scrolls sideways each frame to
    -- fake rotation)
    for dy = -moonRy, moonRy do
      local ny = dy / moonRy
      for dx = -moonRx, moonRx do
        local nx = dx / moonRx
        if nx * nx + ny * ny <= 1 then
          local shade = math.sin((dx + frame * 0.6) * 0.5) * 0.5
                      + math.cos(dy * 0.9) * 0.5
          -- darker toward the rim for a spherical look
          local rim = 1 - (nx * nx + ny * ny)
          shade = shade * 0.6 + rim * 0.4
          local idx = clamp(math.floor((shade + 1) / 2 * (#SHADES - 1)) + 1, 1, #SHADES)
          local ch = SHADES:sub(idx, idx)
          if colorOk then term.setTextColor(colors.lightGray) end
          term.setCursorPos(cx + dx, cy + dy)
          term.write(ch)
        end
      end
    end

    -- orbiting satellite
    local angle = frame * 0.12
    local sx = cx + math.floor(orbitRx * math.cos(angle) + 0.5)
    local sy = cy + math.floor(orbitRy * math.sin(angle) + 0.5)

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

  draw()

  local function animate()
    while running do
      sleep(0.15)
      frame = frame + 1
      draw()
    end
  end

  local function watchQuit()
    while running do
      local event, key = os.pullEvent("key")
      if key == keys.q then
        running = false
      end
    end
  end

  parallel.waitForAny(animate, watchQuit)

  term.setBackgroundColor(colors and colors.black or nil)
  term.clear()
  term.setCursorPos(1, 1)
  if colorOk then term.setTextColor(colors.white) end
  print("moonsat closed.")
end

local ok, err = pcall(main)
if not ok then
  term.setBackgroundColor(colors and colors.black or nil)
  if term.isColor and term.isColor() then term.setTextColor(colors.red) end
  print("moonsat crashed: " .. tostring(err))
end
