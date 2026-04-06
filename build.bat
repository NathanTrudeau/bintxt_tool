@echo off
:: =============================================================================
:: build.bat — Package bintxt_tool UI into a standalone Windows executable
::
:: Usage:
::   Double-click build.bat  OR  run from cmd/PowerShell in repo root
::
:: Output:
::   dist\bintxt_tool.exe
::
:: Requirements:
::   pip install pyinstaller
:: =============================================================================

echo === bintxt_tool build ===

where pyinstaller >nul 2>&1
if errorlevel 1 (
  echo ERROR: pyinstaller not found. Run: pip install pyinstaller
  exit /b 1
)

pyinstaller ^
  --onefile ^
  --windowed ^
  --name "bintxt_tool" ^
  --icon="ui\assets\icon.ico" ^
  --add-data "cfg;cfg" ^
  --add-data "ui\assets;ui\assets" ^
  --paths "." ^
  --distpath "." ^
  ui\app.py

echo.
echo === Build complete ===
echo     Output: bintxt_tool.exe  (in repo root)
echo.
echo     Run bintxt_tool.exe from this folder so it finds cfg\, input\, output\
pause
