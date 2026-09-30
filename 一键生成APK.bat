@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Wenshu Counter - Release APK Builder

set "PROJECT=%~dp0"
if "%PROJECT:~-1%"=="\" set "PROJECT=%PROJECT:~0,-1%"
set "FLUTTER=C:\Users\eddyd\Documents\Codex\tools\flutter\bin\flutter.bat"

cls
echo.
echo ============================================================
echo              Wenshu Counter APK Builder
echo ============================================================
echo.

if not exist "%PROJECT%\pubspec.yaml" goto :NO_PROJECT
if not exist "%FLUTTER%" goto :NO_FLUTTER
cd /d "%PROJECT%"

set "VERSION="
set "VERSION_NAME="
set "VERSION_CODE="
for /f "tokens=2" %%A in ('findstr /b /c:"version:" "pubspec.yaml"') do set "VERSION=%%A"
if not defined VERSION goto :NO_VERSION
for /f "tokens=1,2 delims=+" %%A in ("%VERSION%") do set "VERSION_NAME=%%A"& set "VERSION_CODE=%%B"
if not defined VERSION_CODE goto :BAD_VERSION

echo Source version: %VERSION_NAME%  ^(versionCode %VERSION_CODE%^)
echo.
choice /c YN /n /m "Continue building this version? [Y/N]: "
if errorlevel 2 goto :CANCELLED

set "RELEASE_DIR=%PROJECT%\release_apk"
set "FINAL=%RELEASE_DIR%\wenshu-counter-%VERSION_NAME%-release-universal.apk"
if not exist "%RELEASE_DIR%" mkdir "%RELEASE_DIR%"
if exist "%FINAL%" goto :CONFIRM_OVERWRITE
goto :START_BUILD

:CONFIRM_OVERWRITE
echo.
echo WARNING: The same APK version already exists:
echo %FINAL%
choice /c YN /n /m "Overwrite it? [Y/N]: "
if errorlevel 2 goto :CANCELLED

:START_BUILD
echo.
echo [1/5] Cleaning old build files...
call "%FLUTTER%" clean
if errorlevel 1 goto :BUILD_ERROR

echo.
echo [2/5] Resolving dependencies...
call "%FLUTTER%" pub get
if errorlevel 1 goto :BUILD_ERROR

echo.
echo [3/5] Running flutter analyze...
REM Info diagnostics from vendored dependencies do not block a build.
REM Real warnings and errors still return a failure code.
call "%FLUTTER%" analyze --no-fatal-infos
if errorlevel 1 goto :ANALYZE_ERROR

echo.
echo [4/5] Building the signed release APK...
echo Version: %VERSION_NAME% ^(%VERSION_CODE%^)
call "%FLUTTER%" build apk --release
if errorlevel 1 goto :BUILD_ERROR

set "SOURCE=%PROJECT%\build\app\outputs\flutter-apk\app-release.apk"
if not exist "%SOURCE%" goto :NO_APK

echo.
echo [5/5] Copying and verifying the APK...
if exist "%FINAL%" del /f /q "%FINAL%"
copy /y "%SOURCE%" "%FINAL%" >nul
if errorlevel 1 goto :COPY_ERROR

for %%A in ("%FINAL%") do set "SIZE_BYTES=%%~zA"& set "BUILD_TIME=%%~tA"
set "SHA256="
for /f "tokens=1" %%A in ('powershell -NoProfile -Command "(Get-FileHash -LiteralPath ''%FINAL%'' -Algorithm SHA256).Hash"') do set "SHA256=%%A"
if not defined SHA256 goto :HASH_ERROR

cls
echo.
echo ============================================================
echo                    APK BUILD SUCCEEDED
echo ============================================================
echo App: Wenshu Counter
echo Version: %VERSION_NAME% ^(%VERSION_CODE%^)
echo Pubspec: version: %VERSION%
echo Build time: %BUILD_TIME%
echo APK: %FINAL%
echo Size: %SIZE_BYTES% bytes
echo SHA-256: %SHA256%
echo ============================================================
echo.
explorer /select,"%FINAL%"
pause
exit /b 0

:NO_PROJECT
echo ERROR: pubspec.yaml was not found:
echo %PROJECT%\pubspec.yaml
goto :FAILED

:NO_FLUTTER
echo ERROR: Flutter was not found:
echo %FLUTTER%
goto :FAILED

:NO_VERSION
echo ERROR: Cannot read the version from pubspec.yaml.
goto :FAILED

:BAD_VERSION
echo ERROR: Invalid version. Expected a value like 1.0.51+52.
goto :FAILED

:ANALYZE_ERROR
echo.
echo ERROR: flutter analyze found a warning or error. Build stopped.
echo Send the first warning/error shown above to Codex.
goto :FAILED

:NO_APK
echo ERROR: app-release.apk was not produced.
goto :FAILED

:COPY_ERROR
echo ERROR: Failed to copy or rename the APK.
goto :FAILED

:HASH_ERROR
echo ERROR: Failed to calculate SHA-256.
goto :FAILED

:BUILD_ERROR
echo.
echo ERROR: APK build failed. No old APK will be copied as a new build.
goto :FAILED

:CANCELLED
echo.
echo Cancelled. No APK was generated.
pause
exit /b 0

:FAILED
echo.
pause
exit /b 1
