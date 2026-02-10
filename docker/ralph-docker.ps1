# ralph-docker.ps1 - Convenience wrapper for running Ralph in Docker on Windows
#
# Usage:
#   .\docker\ralph-docker.ps1 [ralph-options]
#
# Examples:
#   .\docker\ralph-docker.ps1 --help
#   .\docker\ralph-docker.ps1 --monitor
#   .\docker\ralph-docker.ps1 --live --verbose
#
# Environment:
#   ANTHROPIC_API_KEY  Required. Your Anthropic API key.
#   RALPH_IMAGE        Optional. Docker image name (default: ralph-claude-code:latest)

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RalphArgs
)

$ImageName = if ($env:RALPH_IMAGE) { $env:RALPH_IMAGE } else { "ralph-claude-code:latest" }

if (-not $env:ANTHROPIC_API_KEY) {
    Write-Error "ANTHROPIC_API_KEY environment variable is not set."
    Write-Host 'Set it first: $env:ANTHROPIC_API_KEY = "sk-ant-..."'
    exit 1
}

$DockerArgs = @(
    "run", "-it", "--rm",
    "-e", "ANTHROPIC_API_KEY=$env:ANTHROPIC_API_KEY",
    "-v", "${PWD}:/workspace",
    $ImageName,
    "ralph"
)

if ($RalphArgs) {
    $DockerArgs += $RalphArgs
}

& docker @DockerArgs
