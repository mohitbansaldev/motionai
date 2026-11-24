@echo off
title MotionAI - build and run on phone
cd /d "%~dp0"
echo Checking code...
call flutter analyze > analyze-output.txt 2>&1
echo Looking for your phone...
call flutter devices > devices.txt 2>&1
type devices.txt
echo.
echo Building and installing on your phone (first build takes 5-10 minutes)...
powershell -NoProfile -Command "flutter run 2>&1 | Tee-Object -FilePath run-output.txt"
echo.
pause
