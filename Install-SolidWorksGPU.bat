@echo off
setlocal
title SOLIDWORKS GPU Hardware Acceleration ^& RealView Enabler
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Enable-SolidWorksGPU.ps1" %*
endlocal
