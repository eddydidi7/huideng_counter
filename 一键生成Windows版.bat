@echo off
chcp 65001 >nul
setlocal EnableExtensions
set "FLUTTER=C:\Users\eddyd\Documents\Codex\tools\flutter\bin\flutter.bat"
set "PROJECT=%~dp0"
if "%PROJECT:~-1%"=="\" set "PROJECT=%PROJECT:~0,-1%"
for %%I in ("%PROJECT%\..") do set "OUTPUTS=%%~fI"

rem The project path is very long; Windows builds fail beyond 260 characters.
rem Map the parent folder (it also holds ../huideng_connection) to a short
rem temporary drive letter just for this build.
set "DRIVE="
for %%D in (W V U T S R Q P O N) do if not defined DRIVE if not exist %%D:\ set "DRIVE=%%D:"
if not defined DRIVE (
  echo 没有可用的临时盘符，无法生成 Windows 版。
  pause
  exit /b 1
)
subst %DRIVE% "%OUTPUTS%"
if errorlevel 1 (
  echo 无法创建临时盘符 %DRIVE%
  pause
  exit /b 1
)
pushd %DRIVE%\huideng_counter

echo [1/3] 获取依赖...
call "%FLUTTER%" pub get
if errorlevel 1 goto :fail

echo [2/3] 生成 Windows 正式版（首次约 5-15 分钟）...
call "%FLUTTER%" build windows --release
if errorlevel 1 goto :fail

echo [3/3] 启动文殊计算器 Windows 版...
start "" "%DRIVE%\huideng_counter\build\windows\x64\runner\Release\huideng_counter.exe"
echo.
echo 程序位置：%PROJECT%\build\windows\x64\runner\Release\huideng_counter.exe
echo 可以把整个 Release 文件夹复制到任意位置使用。
goto :done

:fail
echo.
echo 生成失败。若提示找不到 atlbase.h / atlstr.h：
echo   打开 Visual Studio Installer - 修改 Build Tools 2022 - 单个组件，
echo   勾选“适用于最新 v143 生成工具的 C++ ATL (x86 和 x64)”，安装后重新运行本脚本。
echo 其他错误请把上面的信息复制给 Claude。

:done
popd
subst %DRIVE% /d
pause
