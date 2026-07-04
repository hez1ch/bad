-- BAD installer
-- Run this on a computer (or copy bad.lua manually) to place the
-- program at /bin/bad and make sure /bin is on the shell's PATH,
-- both now and after reboots, so "bad" works from anywhere.
--
-- Also fetches the optional shared monitor-mirroring library
-- (/lib/monitor.lua) that BAD's `gui` command and the bundled apps
-- use to mirror their screens onto any attached monitor peripherals.
-- If that download fails for any reason, BAD itself still installs
-- fine and simply runs terminal-only until the library is available.

local BAD_URL = "https://raw.githubusercontent.com/hez1ch/bad/main/badpm/bad.lua"
local MONLIB_URL = "https://raw.githubusercontent.com/hez1ch/bad/main/lib/monitor.lua"
local PATH_LINE = 'shell.setPath(shell.path() .. ":/bin")'

print("Installing BAD...")

if not http then
  print("HTTP API is disabled on this computer. Enable it in")
  print("config/computercraft-server.toml, http.enabled = true,")
  print("or copy bad.lua manually via a floppy disk to /bin/bad")
  return
end

local resp = http.get(BAD_URL)
if not resp then
  print("Failed to download bad.lua from:")
  print(BAD_URL)
  print("Edit the URL in install.lua or copy bad.lua manually.")
  return
end

local body = resp.readAll()
resp.close()

if not fs.exists("/bin") then fs.makeDir("/bin") end

local h = fs.open("/bin/bad", "w")
h.write(body)
h.close()

-- Best-effort: grab the shared monitor library too, so `bad gui` and
-- the bundled apps can mirror to any attached monitors right away.
local monResp = http.get(MONLIB_URL)
if monResp then
  local monBody = monResp.readAll()
  monResp.close()
  if not fs.exists("/lib") then fs.makeDir("/lib") end
  local mh = fs.open("/lib/monitor.lua", "w")
  mh.write(monBody)
  mh.close()
  print("Installed shared monitor library (/lib/monitor.lua).")
else
  print("Note: could not fetch /lib/monitor.lua (monitor mirroring")
  print("will be unavailable until it's installed).")
end

-- Make "bad" work immediately in this session...
shell.setPath(shell.path() .. ":/bin")

-- ...and make it survive reboots by adding the same line to /startup.lua
local startupContent = ""
if fs.exists("/startup.lua") then
  local sh = fs.open("/startup.lua", "r")
  startupContent = sh.readAll()
  sh.close()
end

if not startupContent:find(PATH_LINE, 1, true) then
  local sh = fs.open("/startup.lua", "a")
  sh.write("\n" .. PATH_LINE .. "\n")
  sh.close()
  print("Added /bin to the startup PATH.")
end

print("Done! Use the command: bad help")
