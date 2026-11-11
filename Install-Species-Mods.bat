@echo off
title Species Unknown Mods - Setup
echo Downloading the Species: Unknown mod launcher...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $d=Join-Path $env:LOCALAPPDATA 'SpeciesMods'; New-Item -ItemType Directory -Force $d | Out-Null; $f=Join-Path $d 'launcher.ps1'; Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/thetomtoro/species-mods/main/launcher.ps1' -OutFile $f; & $f -Mode install; exit $LASTEXITCODE"
if errorlevel 1 (
  echo.
  echo Setup did not finish. Send a screenshot of this window to whoever gave you this file.
  pause
)
