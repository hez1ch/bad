-- BAD installer
-- Run this on a computer (or copy bad.lua manually) to place the
-- program at /bin/bad so it can be called from anywhere as "bad".

local URL = "https://raw.githubusercontent.com/hez1ch/bad/main/badpm/bad.lua"

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

print("Done! Use the command: bad help")
