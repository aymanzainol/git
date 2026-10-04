@echo off
:: Run once on any PC with internet. Downloads the Office installer and the
:: Office files into installers\Office so new PCs install Office offline.
:: Edition / language / channel come from installers\Office\configuration.xml.
setlocal
set "DEST=%~dp0installers\Office"
echo Downloading Office Deployment Tool...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop'; [Net.ServicePointManager]::SecurityProtocol='Tls12'; $ProgressPreference='SilentlyContinue';" ^
  "Invoke-WebRequest 'https://officecdn.microsoft.com/pr/wsus/setup.exe' -OutFile '%DEST%\setup.exe' -UseBasicParsing;" ^
  "$s = Get-AuthenticodeSignature '%DEST%\setup.exe'; if ($s.Status -ne 'Valid' -or $s.SignerCertificate.Subject -notlike '*O=Microsoft Corporation,*') { Remove-Item '%DEST%\setup.exe'; throw 'setup.exe is not signed by Microsoft' }"
if errorlevel 1 (echo. & echo FAILED to download setup.exe & pause & exit /b 1)
echo Downloading Office (about 4 GB, this takes a while - the window stays quiet until it's done)...
pushd "%DEST%"
setup.exe /download configuration.xml
set RC=%errorlevel%
popd
if not "%RC%"=="0" (echo. & echo FAILED - setup.exe /download returned %RC% & pause & exit /b 1)
echo.
echo Done. installers\Office now holds the Office installer - copy the whole PC-Setup folder to your USB stick.
pause
