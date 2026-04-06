@echo off
:: =============================================================================
:: build.bat — Package bintxt_tool UI into a standalone Windows executable
::
:: Usage:
::   Double-click build.bat  OR  run from cmd/PowerShell in repo root
::
:: Output:
::   bintxt_tool_v1-0-0.exe  (in repo root)
::
:: Requirements:
::   pip install --upgrade pyinstaller
::   Close and reopen terminal/VS Code before running if just installed/upgraded.
::
:: Update EXE_NAME below when shipping a new UI version.
:: =============================================================================

set EXE_NAME=bintxt_tool_v1-0-0

echo === bintxt_tool build (%EXE_NAME%) ===

where pyinstaller >nul 2>&1
if errorlevel 1 (
  echo ERROR: pyinstaller not found. Run: pip install --upgrade pyinstaller
  exit /b 1
)

pyinstaller ^
  --onefile ^
  --windowed ^
  --name "%EXE_NAME%" ^
  --icon="ui\assets\icon.ico" ^
  --add-data "cfg;cfg" ^
  --add-data "ui\assets;ui\assets" ^
  --paths "." ^
  --distpath "." ^
  --workpath "build" ^
  ui\app.py

echo.
echo === Build complete ===
echo     Output: %EXE_NAME%.exe  (repo root)
echo.
echo     Run %EXE_NAME%.exe from this folder so it finds cfg\, input\, output\
pause
