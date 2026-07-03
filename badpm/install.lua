-- Установщик BAD
-- Запустите этот файл на компьютере (или скопируйте bad.lua вручную),
-- он положит программу в /bin/bad, чтобы её можно было вызывать
-- из любого места просто командой "bad".

local URL = "https://raw.githubusercontent.com/YOURNAME/bad-repo/main/bad.lua"

print("Установка BAD...")

if not http then
  print("HTTP API отключён на этом компьютере. Включите его в")
  print("ComputerCraft.cfg (или config/computercraft-server.toml)")
  print("параметр http.enabled = true, либо скопируйте bad.lua")
  print("вручную через дискету в /bin/bad")
  return
end

local resp = http.get(URL)
if not resp then
  print("Не удалось скачать bad.lua по адресу:")
  print(URL)
  print("Отредактируйте URL в install.lua или скопируйте bad.lua вручную.")
  return
end

local body = resp.readAll()
resp.close()

if not fs.exists("/bin") then fs.makeDir("/bin") end

local h = fs.open("/bin/bad", "w")
h.write(body)
h.close()

print("Готово! Используйте команду: bad help")
