@echo off
rem Double-click to check the Atomic arm64 stable-diffusion.cpp build @TAG@ on this machine.
rem Downloads verify-spark.ps1 of the same release and runs it; extra arguments are passed on
rem (for example: verify-spark.cmd -Video   or   verify-spark.cmd -Quick).
setlocal
set "PS1=%TEMP%\verify-spark-@SHORT@.ps1"
set "URL=https://github.com/@REPO@/releases/download/@TAG@/verify-spark.ps1"
echo Downloading %URL%
curl.exe -L --fail --retry 3 -o "%PS1%" "%URL%"
if errorlevel 1 (
  echo Could not download the check script.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
echo.
echo Done. The sd-verify folder with report.txt has been opened on the Desktop.
pause
