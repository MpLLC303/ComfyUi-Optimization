@echo off
rem Double-click to install, update, resume or repair the local AI stack.
rem It asks for administrator rights once (UAC) and continues in a NEW window.
rem Extract the downloaded ZIP first (right-click > Extract All); running it from inside the ZIP fails.
if not exist "%~dp0Install-LocalAI.ps1" (
  echo Install-LocalAI.ps1 was not found next to this file. Extract the whole ZIP first, then run it again.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-LocalAI.ps1" %*
echo.
echo The installer continues in the Administrator window that just opened. You can close this one.
pause
