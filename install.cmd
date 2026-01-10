@echo off
REM Ralph for Claude Code - Windows Installation Script
REM This script wraps install.sh for easy installation from CMD

echo Ralph for Claude Code - Windows Installer
echo.

REM Find Git Bash
set "BASH_EXE="
if exist "%ProgramFiles%\Git\bin\bash.exe" (
    set "BASH_EXE=%ProgramFiles%\Git\bin\bash.exe"
) else if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" (
    set "BASH_EXE=%ProgramFiles(x86)%\Git\bin\bash.exe"
) else if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" (
    set "BASH_EXE=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
)

if "%BASH_EXE%"=="" (
    echo ERROR: Git Bash not found!
    echo.
    echo Ralph requires Git Bash to run. Please install Git for Windows:
    echo   https://git-scm.com/download/win
    echo   or: winget install Git.Git
    exit /b 1
)

echo Found Git Bash: %BASH_EXE%
echo Running install.sh...
echo.

"%BASH_EXE%" "%~dp0install.sh" %*

if %ERRORLEVEL% neq 0 (
    echo.
    echo Installation failed with exit code %ERRORLEVEL%
    exit /b %ERRORLEVEL%
)

echo.
echo Installation complete!
echo.
echo NOTE: You may need to restart your terminal for PATH changes to take effect.
