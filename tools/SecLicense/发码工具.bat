@echo off
chcp 65001 >nul
cd /d "%~dp0"
where python >nul 2>&1
if errorlevel 1 (
  echo 未找到 Python，请安装 Python 3.8+ 并勾选 Add to PATH
  pause
  exit /b 1
)
python generate_code.py
pause
