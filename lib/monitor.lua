-- ============================================================
--  monlib - shared monitor-mirroring helper for BAD and its apps
--
--  Any program can use this to transparently mirror its display
--  onto every attached "monitor" peripheral, and to receive touch
--  taps from those monitors normalized as simple "click" events
--  (same shape as a mouse click on an Advanced Computer).
--
--  Usage:
--    local monlib = dofile("/lib/monitor.lua")
--
--    -- draw the exact same thing on the terminal AND every
--    -- attached monitor (auto text-scaled):
--    monlib.renderAll(function(w, h, targetName)
--      term.clear()
--      term.setCursorPos(1, 1)
--      term.write("hello, " .. targetName)
--    end)
--
--    -- normalized input (mouse_click + monitor_touch + key + char):
--    local ev = monlib.pullEvent()
--    if ev.type == "click" then ... end
--
--  Repository: https://github.com/hez1ch/bad
-- ============================================================

local M = {}

M.DEFAULT_SCALE = 0.5

-- ---------------------------------------------------------------
-- Discovery
-- ---------------------------------------------------------------

-- Returns { {name=peripheralSide, mon=wrappedPeripheral}, ... }
function M.list()
  local out = {}
  if not (peripheral and peripheral.getNames) then return out end
  for _, name in ipairs(peripheral.getNames()) do
    local ok, ptype = pcall(peripheral.getType, name)
    if ok and ptype == "monitor" then
      local okWrap, mon = pcall(peripheral.wrap, name)
      if okWrap and mon then
        table.insert(out, { name = name, mon = mon })
      end
    end
  end
  return out
end

-- True if at least one monitor peripheral is attached.
function M.available()
  return #M.list() > 0
end

-- Sets a sane text scale + clears a monitor, ready for drawing.
function M.prepare(mon, scale)
  pcall(mon.setTextScale, scale or M.DEFAULT_SCALE)
  if mon.setBackgroundColor then pcall(mon.setBackgroundColor, colors.black) end
  if mon.setTextColor then pcall(mon.setTextColor, colors.white) end
  pcall(mon.clear)
  pcall(mon.setCursorPos, 1, 1)
end

-- ---------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------

-- Calls drawFn(w, h, targetName) once for the terminal and once for
-- every attached monitor, redirecting `term.*` calls to each target
-- in turn so existing drawing code (written against the normal term
-- API) "just works" on every screen without modification.
--
-- opts.scale        - monitor text scale (default 0.5)
-- opts.monitorsOnly - if true, skip the terminal itself and only
--                     draw on attached monitors (useful for a
--                     background "dashboard" that shouldn't fight
--                     with a program's own terminal UI)
function M.renderAll(drawFn, opts)
  opts = opts or {}
  local prevTerm = term.current()

  if not opts.monitorsOnly then
    pcall(function()
      local w, h = term.getSize()
      drawFn(w, h, "term")
    end)
  end

  for _, entry in ipairs(M.list()) do
    local mon = entry.mon
    pcall(function()
      term.redirect(mon)
      pcall(mon.setTextScale, opts.scale or M.DEFAULT_SCALE)
      local w, h = mon.getSize()
      drawFn(w, h, entry.name)
    end)
    term.redirect(prevTerm)
  end
end

-- ---------------------------------------------------------------
-- Normalized input
-- ---------------------------------------------------------------

-- Blocks until a relevant event happens (or `timeout` seconds pass,
-- if given) and returns a small normalized table:
--   { type = "click", x = .., y = .., source = "term"|monitorSide, button = n }
--   { type = "key",   key = keys.xxx }
--   { type = "char",  char = "a" }
--   { type = "timeout" }
function M.pullEvent(timeout)
  local timerId = nil
  if timeout then
    timerId = os.startTimer(timeout)
  end

  while true do
    local ev = { os.pullEvent() }
    local event = ev[1]

    if event == "mouse_click" then
      return { type = "click", button = ev[2], x = ev[3], y = ev[4], source = "term" }
    elseif event == "monitor_touch" then
      return { type = "click", x = ev[3], y = ev[4], source = ev[2], button = 1 }
    elseif event == "key" then
      return { type = "key", key = ev[2] }
    elseif event == "char" then
      return { type = "char", char = ev[2] }
    elseif event == "timer" and timerId and ev[2] == timerId then
      return { type = "timeout" }
    end
    -- anything else (terminate, disk, etc.) is ignored and we keep
    -- waiting for the next event
  end
end

-- ---------------------------------------------------------------
-- Simple hit-testing helper for building clickable GUIs
-- ---------------------------------------------------------------

-- rects: { {id=.., x1=.., y1=.., x2=.., y2=..}, ... }
-- returns the id of the first rect containing (x, y), or nil
function M.hitTest(rects, x, y)
  for _, r in ipairs(rects) do
    if x >= r.x1 and x <= r.x2 and y >= r.y1 and y <= r.y2 then
      return r.id
    end
  end
  return nil
end

return M
