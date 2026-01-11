# Ralph for Claude Code - Windows Test Runner
# Runs bats tests using Git Bash

param(
    [string]$TestPath = "tests/unit tests/integration",
    [switch]$Unit,
    [switch]$Integration,
    [switch]$Help
)

if ($Help) {
    Write-Host "Ralph Test Runner for Windows"
    Write-Host ""
    Write-Host "Usage: .\test.ps1 [options]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -Unit          Run only unit tests"
    Write-Host "  -Integration   Run only integration tests"
    Write-Host "  -TestPath      Custom test path"
    Write-Host "  -Help          Show this help message"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  .\test.ps1                    # Run all tests"
    Write-Host "  .\test.ps1 -Unit              # Run unit tests only"
    Write-Host "  .\test.ps1 -Integration       # Run integration tests only"
    exit 0
}

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
    exit 1
}

# Determine test path based on flags
if ($Unit) {
    $TestPath = "tests/unit"
} elseif ($Integration) {
    $TestPath = "tests/integration"
}

# Check if node_modules exists
if (-not (Test-Path "node_modules/.bin/bats")) {
    Write-Host "Bats not found. Running npm install..." -ForegroundColor Yellow
    npm install
}

Write-Host "Running tests..." -ForegroundColor Cyan

# Run: export RALPH_TEST_MODE=1 && ./node_modules/.bin/bats <tests>
$unixPath = $PWD.Path -replace '\\', '/' -replace '^([A-Za-z]):', '/$1'
& $bashExe -c "cd '$unixPath' && export RALPH_TEST_MODE=1 && ./node_modules/.bin/bats $TestPath"

exit $LASTEXITCODE
