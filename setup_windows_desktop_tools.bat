@echo off
setlocal enabledelayedexpansion

:: Check for administrative permissions
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo ====================================================================
    echo  Requesting Administrator privileges to configure Windows Desktop...
    echo ====================================================================
    powershell -Command "Start-Process cmd -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

echo ====================================================================
echo  [1/3] Enabling Windows Developer Mode (Symlink Support)...
echo ====================================================================
reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v "AllowDevelopmentWithoutDevLicense" /d 1
if %errorlevel% equ 0 (
    echo  [OK] Developer Mode enabled successfully.
) else (
    echo  [WARNING] Could not set Developer Mode registry key.
)

echo.
echo ====================================================================
echo  [2/3] Adding Flutter to System PATH...
echo ====================================================================
powershell -NoProfile -Command "[System.Environment]::SetEnvironmentVariable('Path', [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';D:\flutter\bin;D:\flutter\bin\cache\dart-sdk\bin', 'Machine')"
echo  [OK] System PATH updated with Flutter and Dart SDK.

echo.
echo ====================================================================
echo  [3/3] Downloading and Installing Visual Studio C++ Build Tools...
echo  (This will download and configure Microsoft MSVC C++ Compilers)
echo ====================================================================
winget install --id Microsoft.VisualStudio.2022.BuildTools --exact --accept-package-agreements --accept-source-agreements --override "--passive --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"

echo.
echo ====================================================================
echo  Verification: Running Flutter Doctor...
echo ====================================================================
set "PATH=%PATH%;D:\flutter\bin;D:\flutter\bin\cache\dart-sdk\bin"
"D:\flutter\bin\flutter.bat" doctor -v

echo.
echo ====================================================================
echo  ALL DONE! You can now close this window and run:
echo  flutter run -d windows
echo ====================================================================
pause

