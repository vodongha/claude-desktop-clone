<#
.SYNOPSIS
    Removes the desktop shortcuts created by Setup.ps1. Optionally deletes the
    profile data (logins/history) too.

.PARAMETER Profile
    Profile names to remove. Default: Work, Personal.

.PARAMETER InstallDir
    Where profiles were installed. Default: %USERPROFILE%\ClaudeProfiles.

.PARAMETER RemoveData
    Also delete the isolated profile data directories (this signs you out and
    erases that profile's local history). The "Work" profile that reuses
    %APPDATA%\Claude is never deleted.
#>
[CmdletBinding()]
param(
    [string[]]$Profile = @('Work', 'Personal'),
    [string]$InstallDir = (Join-Path $env:USERPROFILE 'ClaudeProfiles'),
    [switch]$RemoveData
)

$desktop = [Environment]::GetFolderPath('Desktop')

foreach ($name in $Profile) {
    $lnk = Join-Path $desktop "Claude ($name).lnk"
    if (Test-Path $lnk) {
        Remove-Item $lnk -Force
        Write-Host "Removed shortcut: $lnk" -ForegroundColor Yellow
    }

    if ($RemoveData) {
        $dataDir = Join-Path $InstallDir $name
        if (Test-Path $dataDir) {
            Remove-Item $dataDir -Recurse -Force
            Write-Host "Removed profile data: $dataDir" -ForegroundColor Yellow
        }
    }
}

Write-Host "Done."
