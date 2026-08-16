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

& git -C $Checkout apply --check (Join-Path $ScriptDir "zigcho-client.patch")
if ($LASTEXITCODE -ne 0) {
    throw "zigcho client patch does not apply to the pinned osu! checkout"
}

& git -C $Checkout apply (Join-Path $ScriptDir "zigcho-client.patch")
if ($LASTEXITCODE -ne 0) {
    throw "zigcho client patching failed"
}

Write-Host "zigcho client patch applied to $Checkout"
