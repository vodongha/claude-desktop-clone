<#
.SYNOPSIS
    (Optional) Compiles the launcher into a standalone .exe using ps2exe.

.DESCRIPTION
    Some people prefer a real .exe over a .vbs/.ps1. This wraps
    Launch-Claude.ps1 into ClaudeLauncher.exe with no console window.

    The produced exe still takes -ProfileDir, e.g.:
        ClaudeLauncher.exe -ProfileDir "C:\Users\me\ClaudeProfiles\personal"

    NOTE: ps2exe-produced executables sometimes trip antivirus / SmartScreen
    heuristics (they are unsigned). The .vbs launcher from Setup.ps1 is the
    recommended, friction-free option; this is here only if you specifically
    want an .exe.

.PARAMETER OutputPath
    Where to write the exe. Default: dist\ClaudeLauncher.exe next to the repo.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'dist\ClaudeLauncher.exe')
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = Join-Path $scriptRoot 'Launch-Claude.ps1'

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "Installing ps2exe (current user)..." -ForegroundColor Cyan
    Install-Module ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null

# Try to embed the Claude icon if the app is installed.
$iconArg = @{}
$pkg = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending | Select-Object -First 1
if ($pkg) {
    $iconExe = Join-Path $pkg.InstallLocation 'app\Claude.exe'
    if (Test-Path $iconExe) { $iconArg['iconFile'] = $iconExe }
}

ps2exe -inputFile $src -outputFile $OutputPath -noConsole -title 'Claude Launcher' `
    -description 'Launch Claude Desktop with an isolated profile' @iconArg

Write-Host "Built: $OutputPath" -ForegroundColor Green
