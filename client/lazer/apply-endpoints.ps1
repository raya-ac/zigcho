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

$Patch = Join-Path $ScriptDir "zigcho-client.patch"

& git -C $Checkout apply --check $Patch 2>$null
if ($LASTEXITCODE -eq 0) {
    & git -C $Checkout apply $Patch
    if ($LASTEXITCODE -ne 0) {
        throw "zigcho client patching failed"
    }

    Write-Host "zigcho client patch applied to $Checkout"
    return
}

& git -C $Checkout apply --reverse --check $Patch 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "zigcho client patch already applied to $Checkout"
    return
}

throw "zigcho client patch does not apply cleanly to the pinned osu! checkout"
