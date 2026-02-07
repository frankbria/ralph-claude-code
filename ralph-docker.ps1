<#
.SYNOPSIS
    Ralph for Claude Code - Windows Docker Helper
    Implements: Issue #74 - Phase 6.1 Local Docker Sandbox Execution

.DESCRIPTION
    Provides Windows-native commands to build, run, and manage Ralph
    inside Docker containers. Supports interactive auth (Claude Max/Pro)
    and API key authentication.

.EXAMPLE
    # First-time setup: build image and authenticate
    .\ralph-docker.ps1 setup

    # Start ralph in your project directory
    cd C:\Users\you\my-project
    .\ralph-docker.ps1 start

    # Interactive shell
    .\ralph-docker.ps1 shell

    # Monitor dashboard
    .\ralph-docker.ps1 monitor

    # Stop everything
    .\ralph-docker.ps1 stop

.NOTES
    Requirements:
    - Docker Desktop for Windows (with WSL2 or Hyper-V backend)
    - PowerShell 5.1+ or PowerShell Core 7+
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet("setup", "build", "shell", "start", "stop", "monitor", "status", "logs", "clean", "help")]
    [string]$Command = "help",

    [Parameter()]
    [string]$ProjectDir = ".",

    [Parameter()]
    [string]$ApiKey = "",

    [Parameter()]
    [int]$Calls = 100,

    [Parameter()]
    [int]$Timeout = 15,

    [Parameter()]
    [switch]$Live
)

# ============================================================================
# Configuration
# ============================================================================

$ErrorActionPreference = "Stop"
$ImageName = "ralph-claude-code:latest"
$ContainerPrefix = "ralph"

# Resolve project directory to absolute path
$ProjectDir = (Resolve-Path -Path $ProjectDir -ErrorAction SilentlyContinue)?.Path ?? (Get-Location).Path

# Claude config directory (for auth persistence)
$ClaudeConfigDir = Join-Path $env:USERPROFILE ".claude"
if (-not (Test-Path $ClaudeConfigDir)) {
    New-Item -ItemType Directory -Path $ClaudeConfigDir -Force | Out-Null
}

# ============================================================================
# Helper Functions
# ============================================================================

function Write-RalphHeader {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║   Ralph for Claude Code - Docker Mode    ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Test-DockerRunning {
    try {
        docker info 2>&1 | Out-Null
        return $true
    }
    catch {
        Write-Host "ERROR: Docker is not running. Please start Docker Desktop." -ForegroundColor Red
        return $false
    }
}

function Test-ImageExists {
    $result = docker images -q $ImageName 2>$null
    return ($null -ne $result -and $result -ne "")
}

function Get-RalphScriptDir {
    # Find the ralph-claude-code repo directory
    # Check if we're inside it, or look for it relative to this script
    $scriptDir = $PSScriptRoot
    if (Test-Path (Join-Path $scriptDir "install.sh")) {
        return $scriptDir
    }
    # Check common locations
    $candidates = @(
        (Join-Path $env:USERPROFILE "ralph-claude-code"),
        (Join-Path $env:USERPROFILE "source\repos\ralph-claude-code"),
        (Join-Path $env:USERPROFILE "projects\ralph-claude-code")
    )
    foreach ($dir in $candidates) {
        if (Test-Path (Join-Path $dir "install.sh")) {
            return $dir
        }
    }
    return $null
}

# ============================================================================
# Commands
# ============================================================================

function Invoke-Setup {
    Write-RalphHeader
    Write-Host "Setting up Ralph Docker environment..." -ForegroundColor Yellow
    Write-Host ""

    # Step 1: Check Docker
    if (-not (Test-DockerRunning)) { exit 1 }
    Write-Host "  [OK] Docker is running" -ForegroundColor Green

    # Step 2: Build image
    Invoke-Build

    # Step 3: Run interactive auth
    Write-Host ""
    Write-Host "  Launching interactive shell for Claude Code authentication..." -ForegroundColor Yellow
    Write-Host "  Run 'claude' inside the container to log in with your Max/Pro subscription." -ForegroundColor Gray
    Write-Host "  After authenticating, type 'exit' to return here." -ForegroundColor Gray
    Write-Host ""

    docker run -it --rm `
        --name "${ContainerPrefix}-setup" `
        -v "${ProjectDir}:/workspace" `
        -v "${ClaudeConfigDir}:/home/ralph/.claude" `
        -e "TERM=xterm-256color" `
        -w /workspace `
        $ImageName

    Write-Host ""
    Write-Host "  [OK] Setup complete! Your authentication is saved." -ForegroundColor Green
    Write-Host "  Use '.\ralph-docker.ps1 start' to begin autonomous development." -ForegroundColor Cyan
    Write-Host ""
}

function Invoke-Build {
    Write-Host "  Building Ralph Docker image..." -ForegroundColor Yellow

    $ralphDir = Get-RalphScriptDir
    if ($null -eq $ralphDir) {
        Write-Host "  ERROR: Cannot find ralph-claude-code repository." -ForegroundColor Red
        Write-Host "  Make sure this script is in the ralph-claude-code directory," -ForegroundColor Red
        Write-Host "  or clone it to ~/ralph-claude-code" -ForegroundColor Red
        exit 1
    }

    docker build -t $ImageName $ralphDir
    Write-Host "  [OK] Image built: $ImageName" -ForegroundColor Green
}

function Invoke-Shell {
    Write-RalphHeader
    if (-not (Test-DockerRunning)) { exit 1 }
    if (-not (Test-ImageExists)) {
        Write-Host "  Image not found. Building first..." -ForegroundColor Yellow
        Invoke-Build
    }

    Write-Host "  Opening interactive Ralph shell..." -ForegroundColor Cyan
    Write-Host "  Project: $ProjectDir" -ForegroundColor Gray
    Write-Host ""

    $envArgs = @("-e", "TERM=xterm-256color")
    if ($ApiKey -ne "") {
        $envArgs += @("-e", "ANTHROPIC_API_KEY=$ApiKey")
    }

    docker run -it --rm `
        --name "${ContainerPrefix}-shell" `
        -v "${ProjectDir}:/workspace" `
        -v "${ClaudeConfigDir}:/home/ralph/.claude" `
        @envArgs `
        -w /workspace `
        $ImageName
}

function Invoke-Start {
    Write-RalphHeader
    if (-not (Test-DockerRunning)) { exit 1 }
    if (-not (Test-ImageExists)) {
        Write-Host "  Image not found. Building first..." -ForegroundColor Yellow
        Invoke-Build
    }

    Write-Host "  Starting Ralph autonomous loop..." -ForegroundColor Cyan
    Write-Host "  Project: $ProjectDir" -ForegroundColor Gray
    Write-Host "  Calls/hour: $Calls" -ForegroundColor Gray
    Write-Host "  Timeout: ${Timeout}min" -ForegroundColor Gray
    Write-Host ""

    $ralphArgs = @("--calls", "$Calls", "--timeout", "$Timeout")
    if ($Live) {
        $ralphArgs += "--live"
    }

    $envArgs = @("-e", "TERM=xterm-256color")
    if ($ApiKey -ne "") {
        $envArgs += @("-e", "ANTHROPIC_API_KEY=$ApiKey")
    }

    docker run -it --rm `
        --name "${ContainerPrefix}-loop" `
        -v "${ProjectDir}:/workspace" `
        -v "${ClaudeConfigDir}:/home/ralph/.claude" `
        @envArgs `
        -w /workspace `
        --entrypoint ralph `
        $ImageName `
        @ralphArgs
}

function Invoke-Monitor {
    Write-RalphHeader
    if (-not (Test-DockerRunning)) { exit 1 }

    # Check if ralph-loop is running
    $running = docker ps --filter "name=${ContainerPrefix}-loop" --format "{{.Names}}" 2>$null
    if ($null -eq $running -or $running -eq "") {
        Write-Host "  WARNING: Ralph loop is not running." -ForegroundColor Yellow
        Write-Host "  Start it first with: .\ralph-docker.ps1 start" -ForegroundColor Gray
        Write-Host ""
    }

    docker run -it --rm `
        --name "${ContainerPrefix}-monitor" `
        -v "${ProjectDir}:/workspace" `
        -e "TERM=xterm-256color" `
        -w /workspace `
        --entrypoint ralph-monitor `
        $ImageName
}

function Invoke-Stop {
    Write-Host "  Stopping Ralph containers..." -ForegroundColor Yellow
    docker ps --filter "name=${ContainerPrefix}" --format "{{.Names}}" | ForEach-Object {
        Write-Host "  Stopping $_..." -ForegroundColor Gray
        docker stop $_ 2>$null | Out-Null
    }
    Write-Host "  [OK] All Ralph containers stopped." -ForegroundColor Green
}

function Invoke-Status {
    Write-RalphHeader
    Write-Host "  Container Status:" -ForegroundColor Cyan
    Write-Host ""
    $containers = docker ps -a --filter "name=${ContainerPrefix}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>$null
    if ($null -eq $containers -or $containers.Count -le 1) {
        Write-Host "  No Ralph containers found." -ForegroundColor Gray
    }
    else {
        $containers | ForEach-Object { Write-Host "  $_" }
    }
    Write-Host ""

    # Check image
    if (Test-ImageExists) {
        Write-Host "  Image: $ImageName [EXISTS]" -ForegroundColor Green
    }
    else {
        Write-Host "  Image: $ImageName [NOT BUILT]" -ForegroundColor Yellow
    }

    # Check auth
    if (Test-Path (Join-Path $ClaudeConfigDir ".credentials.json")) {
        Write-Host "  Auth:  Claude credentials found" -ForegroundColor Green
    }
    else {
        Write-Host "  Auth:  No credentials (run 'setup' first)" -ForegroundColor Yellow
    }
    Write-Host ""
}

function Invoke-Logs {
    $running = docker ps --filter "name=${ContainerPrefix}-loop" --format "{{.Names}}" 2>$null
    if ($null -eq $running -or $running -eq "") {
        Write-Host "  Ralph loop is not running." -ForegroundColor Yellow
        return
    }
    docker logs -f "${ContainerPrefix}-loop"
}

function Invoke-Clean {
    Write-Host "  Cleaning up Ralph Docker resources..." -ForegroundColor Yellow
    Invoke-Stop
    docker rmi $ImageName 2>$null | Out-Null
    docker volume rm ralph-home 2>$null | Out-Null
    Write-Host "  [OK] Cleaned up image and volumes." -ForegroundColor Green
}

function Show-Help {
    Write-RalphHeader
    Write-Host "  USAGE:" -ForegroundColor White
    Write-Host "    .\ralph-docker.ps1 <command> [options]" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  COMMANDS:" -ForegroundColor White
    Write-Host "    setup       Build image and authenticate with Claude (first-time)" -ForegroundColor Gray
    Write-Host "    build       Build/rebuild the Docker image" -ForegroundColor Gray
    Write-Host "    shell       Open interactive shell in container" -ForegroundColor Gray
    Write-Host "    start       Start Ralph autonomous development loop" -ForegroundColor Gray
    Write-Host "    monitor     Open the Ralph monitor dashboard" -ForegroundColor Gray
    Write-Host "    stop        Stop all Ralph containers" -ForegroundColor Gray
    Write-Host "    status      Show container and auth status" -ForegroundColor Gray
    Write-Host "    logs        Follow Ralph loop logs" -ForegroundColor Gray
    Write-Host "    clean       Remove image, containers, and volumes" -ForegroundColor Gray
    Write-Host "    help        Show this help message" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  OPTIONS:" -ForegroundColor White
    Write-Host "    -ProjectDir <path>   Project directory to mount (default: current dir)" -ForegroundColor Gray
    Write-Host "    -ApiKey <key>        Anthropic API key (alternative to interactive auth)" -ForegroundColor Gray
    Write-Host "    -Calls <n>           Max API calls per hour (default: 100)" -ForegroundColor Gray
    Write-Host "    -Timeout <min>       Execution timeout in minutes (default: 15)" -ForegroundColor Gray
    Write-Host "    -Live                Enable live streaming output" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  EXAMPLES:" -ForegroundColor White
    Write-Host "    # First-time setup (authenticate with Claude Max/Pro)" -ForegroundColor DarkGray
    Write-Host "    .\ralph-docker.ps1 setup" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "    # Start autonomous dev in current directory" -ForegroundColor DarkGray
    Write-Host "    .\ralph-docker.ps1 start -Live" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "    # Use a specific project directory" -ForegroundColor DarkGray
    Write-Host '    .\ralph-docker.ps1 start -ProjectDir "C:\Users\me\my-app"' -ForegroundColor Cyan
    Write-Host ""
    Write-Host "    # Use API key instead of interactive login" -ForegroundColor DarkGray
    Write-Host '    .\ralph-docker.ps1 start -ApiKey "sk-ant-api03-xxxxx"' -ForegroundColor Cyan
    Write-Host ""
}

# ============================================================================
# Main Dispatch
# ============================================================================

switch ($Command) {
    "setup"   { Invoke-Setup }
    "build"   { Invoke-Build }
    "shell"   { Invoke-Shell }
    "start"   { Invoke-Start }
    "stop"    { Invoke-Stop }
    "monitor" { Invoke-Monitor }
    "status"  { Invoke-Status }
    "logs"    { Invoke-Logs }
    "clean"   { Invoke-Clean }
    "help"    { Show-Help }
}
