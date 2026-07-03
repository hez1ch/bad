-- BAD installer
-- Run this on a computer (or copy bad.lua manually) to place the
-- program at /bin/bad and make sure /bin is on the shell's PATH,
-- both now and after reboots, so "bad" works from anywhere.

local URL = "https://raw.githubusercontent.com/hez1ch/bad/main/badpm/bad.lua"
local PATH_LINE = 'shell.setPath(shell.path() .. ":/bin")'

print("Installing BAD...")

if not http then
  print("HTTP API is disabled on this computer. Enable it in")
  print("config/computercraft-server.toml, http.enabled = true,")
  print("or copy bad.lua manually via a floppy disk to /bin/bad")
  return
end

local resp = http.get(URL)
if not resp then
  print("Failed to download bad.lua from:")
  print(URL)
  print("Edit the URL in install.lua or copy bad.lua manually.")
  return
end

local body = resp.readAll()
resp.close()

if not fs.exists("/bin") then fs.makeDir("/bin") end

local h = fs.open("/bin/bad", "w")
h.write(body)
h.close()

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
