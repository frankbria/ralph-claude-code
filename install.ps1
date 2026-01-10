# Ralph for Claude Code - Windows Installation Script
# This script wraps install.sh for easy installation from PowerShell

$ErrorActionPreference = "Stop"

Write-Host "Ralph for Claude Code - Windows Installer" -ForegroundColor Cyan
Write-Host ""

# Find Git Bash
$gitBashPaths = @(
    "$env:ProgramFiles\Git\bin\bash.exe",
    "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
)

$bashExe = $null
foreach ($path in $gitBashPaths) {
    if (Test-Path $path) {
        $bashExe = $path
        break
    }
}

if (-not $bashExe) {
    Write-Host "ERROR: Git Bash not found!" -ForegroundColor Red
    Write-Host ""
    Write-Host "Ralph requires Git Bash to run. Please install Git for Windows:" -ForegroundColor Yellow
    Write-Host "  https://git-scm.com/download/win" -ForegroundColor White
    Write-Host "  or: winget install Git.Git" -ForegroundColor White
    exit 1
}

Write-Host "Found Git Bash: $bashExe" -ForegroundColor Green

# Get the directory where this script is located
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$installScript = Join-Path $scriptDir "install.sh"

if (-not (Test-Path $installScript)) {
    Write-Host "ERROR: install.sh not found in $scriptDir" -ForegroundColor Red
    exit 1
}

# Convert Windows path to Unix path for Git Bash
$unixPath = $installScript -replace '\\', '/' -replace '^([A-Za-z]):', '/$1'
$unixPath = $unixPath.ToLower().Substring(0,2) + $unixPath.Substring(2)

Write-Host "Running install.sh..." -ForegroundColor Cyan
Write-Host ""

# Run install.sh with Git Bash
& $bashExe $unixPath

$exitCode = $LASTEXITCODE

if ($exitCode -eq 0) {
    Write-Host ""
    Write-Host "Installation complete!" -ForegroundColor Green
    Write-Host ""
    Write-Host "NOTE: You may need to restart your terminal or run:" -ForegroundColor Yellow
    Write-Host '  $env:PATH += ";$env:USERPROFILE\.local\bin"' -ForegroundColor White
    Write-Host ""
} else {
    Write-Host ""
    Write-Host "Installation failed with exit code $exitCode" -ForegroundColor Red
    exit $exitCode
}
