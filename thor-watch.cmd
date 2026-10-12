@echo off
rem Thor board: double-click it, or run it from a shell. Refresh seconds as the first argument (default 5).
set EVERY=%1
if "%EVERY%"=="" set EVERY=5
where pwsh >nul 2>nul
if %errorlevel%==0 (
  start "Thor Traffic" pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0thor.ps1" watch -Every %EVERY%
) else (
  start "Thor Traffic" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0thor.ps1" watch -Every %EVERY%
)
