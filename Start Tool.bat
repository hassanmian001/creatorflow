@echo off
cd /d "%~dp0"
start "Slideshow Video Tool" powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0SlideshowVideoTool.ps1"

