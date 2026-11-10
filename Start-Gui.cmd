@echo off
setlocal
set "HERE=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%HERE%ui\DriveSift.Gui.ps1" %*
if errorlevel 1 pause
