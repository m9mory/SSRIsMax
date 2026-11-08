# Rebuilds the CLI probe mirror (Tools/max-core/Core) from MaxClient/Core.
#
# MaxClient/Core is the single source of truth. The mirror exists only so
# `swift run` on macOS/Linux can build the core without GRDB, UIKit or Security.
# MaxMemoryCredentialStore.swift (protocol MaxCredentialStore) is mirror-only:
# the app uses KeychainCredentialStore from MaxClient/Core/Storage, so copying
# the protocol there would duplicate the declaration.
#
# Usage:  pwsh -File scripts/sync-core.ps1
#         pwsh -File scripts/sync-core.ps1 -Verify

param([switch]$Verify)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dest = Join-Path $root 'Tools/max-core/Core'

$files = @(
    'MaxClient/Core/Protocol/MessagePack.swift',
    'MaxClient/Core/Protocol/MaxProtocol.swift',
    'MaxClient/Core/Protocol/MaxParser.swift',
    'MaxClient/Core/Models/Models.swift',
    'MaxClient/Core/Network/MaxTransport.swift',
    'MaxClient/Core/Network/MaxWebSocketTransport.swift',
    'MaxClient/Core/Network/MaxTCPTransport.swift',
    'MaxClient/Core/Auth/MaxAuthService.swift'
)

$mirrorOnly = @(
    'Tools/max-core/Core/MaxMemoryCredentialStore.swift'
)

if ($Verify) {
    $drift = @()
    foreach ($relative in $files) {
        $source = Join-Path $root $relative
        $target = Join-Path $dest (Split-Path $relative -Leaf)
        if (-not (Test-Path $target)) { $drift += "$relative (missing)"; continue }
        if ((Get-FileHash $source).Hash -ne (Get-FileHash $target).Hash) { $drift += $relative }
    }
    foreach ($relative in $mirrorOnly) {
        if (-not (Test-Path (Join-Path $root $relative))) { $drift += "$relative (missing)" }
    }
    if ($drift.Count -gt 0) {
        Write-Output "Mirror is stale:"
        foreach ($item in $drift) { Write-Output "  $item" }
        Write-Output "Run scripts/sync-core.ps1"
        exit 1
    }
    Write-Output "Mirror is up to date."
    exit 0
}

New-Item -ItemType Directory -Force -Path $dest | Out-Null
foreach ($relative in $files) {
    Copy-Item (Join-Path $root $relative) (Join-Path $dest (Split-Path $relative -Leaf)) -Force
}
Write-Output "Copied $($files.Count) files to Tools/max-core/Core ($($mirrorOnly.Count) mirror-only kept)"

