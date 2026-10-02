@echo off
rem Double-click to install, resume or repair the local AI stack.
rem It asks for administrator rights once (UAC) and continues in a new window.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-LocalAI.ps1" %*
pause
