@echo off
chcp 65001 >nul
title 文殊计算器 - 手机真机调试
cd /d C:\huideng_counter

echo ==================================================
echo   文殊计算器 - Android 手机一键真机调试
echo ==================================================
echo.
echo 请确认：
echo 1. 手机已用 USB 连接电脑
echo 2. 手机已开启“开发者选项 - USB 调试”
echo 3. 手机弹出 USB 调试授权时选择“允许”
echo.
echo [1/3] 检查 Flutter...
where flutter >nul 2>nul
if errorlevel 1 (
    echo.
    echo [错误] 找不到 Flutter 命令。
    echo 请确认 Flutter 已安装并已加入 PATH。
    echo.
    pause
    exit /b 1
)

echo [2/3] 检查连接的设备...
flutter devices
echo.
echo 如果上面没有显示 Android 手机：
echo 请检查 USB 调试，并在手机上允许此电脑调试。
echo.
echo [3/3] 正在启动文殊计算器 Debug 版...
echo.
echo 启动成功后：
echo   按 r = 热重载（修改界面后最快查看）
echo   按 R = 热重启
echo   按 q = 退出调试
echo.
flutter run

echo.
echo Flutter 调试已结束。
pause
