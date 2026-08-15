[CmdletBinding()]
param(
    [string]$Checkout = "work/osu-client"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ScriptDir = $PSScriptRoot
$ExpectedCommit = (Get-Content -Raw (Join-Path $ScriptDir "upstream-commit.txt")).Trim()
$ActualCommit = (& git -C $Checkout rev-parse HEAD).Trim()

if ($LASTEXITCODE -ne 0) {
    throw "could not read the osu! checkout at $Checkout"
}

if ($ActualCommit -ne $ExpectedCommit) {
    throw "expected osu! $ExpectedCommit, got $ActualCommit"
}

$Copies = @{
    "ProductionEndpointConfiguration.cs" = "osu.Game/Online/ProductionEndpointConfiguration.cs"
    "DevelopmentEndpointConfiguration.cs" = "osu.Game/Online/DevelopmentEndpointConfiguration.cs"
    "TrustedDomainOnlineStore.cs" = "osu.Game/Online/TrustedDomainOnlineStore.cs"
    "TrustedDomainOnlineStoreTest.cs" = "osu.Game.Tests/TrustedDomainOnlineStoreTest.cs"
    "PollingChatClient.cs" = "osu.Game/Online/Chat/PollingChatClient.cs"
    "PollingChatClientTest.cs" = "osu.Game.Tests/PollingChatClientTest.cs"
    "ZigchoLeaderboardAvailability.cs" = "osu.Game/Online/Leaderboards/ZigchoLeaderboardAvailability.cs"
    "ZigchoLeaderboardAvailabilityTest.cs" = "osu.Game.Tests/ZigchoLeaderboardAvailabilityTest.cs"
    "ZigchoRealtimeServicePolicy.cs" = "osu.Game/Online/API/ZigchoRealtimeServicePolicy.cs"
    "ZigchoRealtimeServicePolicyTest.cs" = "osu.Game.Tests/ZigchoRealtimeServicePolicyTest.cs"
}

foreach ($SourceName in $Copies.Keys) {
    Copy-Item -LiteralPath (Join-Path $ScriptDir $SourceName) -Destination (Join-Path $Checkout $Copies[$SourceName]) -Force
}

$Python = if (Get-Command python -ErrorAction SilentlyContinue) { "python" } elseif (Get-Command python3 -ErrorAction SilentlyContinue) { "python3" } else { $null }
if (-not $Python) {
    throw "python 3 is required to patch the pinned client"
}

& $Python (Join-Path $ScriptDir "patch-unavailable-realtime.py") $Checkout
if ($LASTEXITCODE -ne 0) {
    throw "client source patching failed"
}

Write-Host "zigcho endpoints, client isolation, and trusted resource domains applied to $Checkout"
