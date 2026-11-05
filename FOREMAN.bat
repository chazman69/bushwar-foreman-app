@echo off
rem BUSHWAR Foreman - double-click to open the collaboration app.
rem (Console hides itself; fatal errors show as a dialog box.)
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "%~dp0src\foreman.ps1"
