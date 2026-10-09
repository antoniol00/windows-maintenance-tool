@echo off
rem Lanzador: doble clic para ejecutar el mantenimiento completo.
rem Acepta los mismos parametros que el script, p. ej.:  Mantenimiento.cmd -Only Temp,CleanMgr
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-WindowsMaintenance.ps1" %*
