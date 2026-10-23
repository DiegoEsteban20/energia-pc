@echo off
rem Modo alternativo con consola para diagnosticar problemas de inicio.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0EnergiaPC.ps1"
if errorlevel 1 pause
