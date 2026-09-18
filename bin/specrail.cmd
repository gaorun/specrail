@echo off
setlocal
set "arch=%PROCESSOR_ARCHITECTURE%"
if defined PROCESSOR_ARCHITEW6432 set "arch=%PROCESSOR_ARCHITEW6432%"
if /I "%arch%"=="AMD64" goto x64
if /I "%arch%"=="ARM64" goto arm64
>&2 echo Unsupported platform: windows %arch%
exit /b 2
:x64
set "binary=%~dp0..\libexec\specrail-windows-x64.exe"
goto run
:arm64
set "binary=%~dp0..\libexec\specrail-windows-arm64.exe"
:run
if not exist "%binary%" (
  >&2 echo Missing bundled CLI. Install a complete specrail plugin build.
  exit /b 2
)
set "BUN_BE_BUN="
set "BUN_OPTIONS="
set "NODE_OPTIONS="
set "NODE_PATH="
"%binary%" %*
exit /b %errorlevel%
