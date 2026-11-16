@echo off
setlocal
cd /d "%~dp0"
echo ============================================
echo   Gear VR Pointer - build APK
echo ============================================

rem --- find the Android SDK ---
set "SDK="
if defined ANDROID_HOME if exist "%ANDROID_HOME%\platform-tools" set "SDK=%ANDROID_HOME%"
if not defined SDK if defined ANDROID_SDK_ROOT if exist "%ANDROID_SDK_ROOT%\platform-tools" set "SDK=%ANDROID_SDK_ROOT%"
if not defined SDK if exist "%LOCALAPPDATA%\Android\Sdk" set "SDK=%LOCALAPPDATA%\Android\Sdk"
if not defined SDK (
  echo.
  echo [X] Android SDK not found.
  echo     Install Android Studio from https://developer.android.com/studio
  echo     open it once so it downloads the SDK, then run this file again.
  goto :fail
)
echo SDK : %SDK%
set "SDKF=%SDK:\=/%"
> local.properties echo sdk.dir=%SDKF%

rem --- find a JDK (Android Studio ships one) ---
if exist "%ProgramFiles%\Android\Android Studio\jbr\bin\java.exe" set "JAVA_HOME=%ProgramFiles%\Android\Android Studio\jbr"
if not defined JAVA_HOME if exist "%LOCALAPPDATA%\Programs\Android Studio\jbr\bin\java.exe" set "JAVA_HOME=%LOCALAPPDATA%\Programs\Android Studio\jbr"
if defined JAVA_HOME (echo JDK : %JAVA_HOME%) else (echo JDK : using java from PATH)

echo.
echo Building... the first run downloads Gradle and can take several minutes.
echo.
call gradlew.bat --no-daemon assembleDebug > build-log.txt 2>&1
if errorlevel 1 (
  echo [X] Build failed. The details are in build-log.txt - last lines:
  echo.
  powershell -NoProfile -Command "Get-Content build-log.txt -Tail 40"
  goto :fail
)
copy /y "app\build\outputs\apk\debug\app-debug.apk" "GearVRPointer.apk" > nul
echo.
echo [OK] Done:  %cd%\GearVRPointer.apk
echo      Copy it to your phone and install it.
echo.
pause
exit /b 0

:fail
echo.
pause
exit /b 1
