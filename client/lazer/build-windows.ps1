[CmdletBinding()]
param(
    [string]$Checkout = "work/osu-client",
    [string]$OutputDirectory = "artifacts/lazer",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ScriptDir = $PSScriptRoot
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "../..")).Path
$CheckoutPath = (Resolve-Path $Checkout).Path
$Version = (Get-Content -Raw (Join-Path $ScriptDir "client-version.txt")).Trim()
$OsuRevision = (Get-Content -Raw (Join-Path $ScriptDir "upstream-commit.txt")).Trim()
$ZigchoRevision = (& git -C $RepoRoot rev-parse HEAD).Trim()

if ($LASTEXITCODE -ne 0 -or $ZigchoRevision -notmatch "^[0-9a-f]{40}$") {
    throw "could not read the zigcho revision"
}
if ($env:GITHUB_SHA -and $env:GITHUB_SHA -ne $ZigchoRevision) {
    throw "checked out zigcho revision does not match GITHUB_SHA"
}

$Dotnet = if ($env:ZIGCHO_DOTNET) { $env:ZIGCHO_DOTNET } else { "dotnet" }
$Python = if (Get-Command python -ErrorAction SilentlyContinue) { "python" } elseif (Get-Command python3 -ErrorAction SilentlyContinue) { "python3" } else { $null }
if (-not $Python) {
    throw "python 3 is required to package the Windows client"
}

& (Join-Path $ScriptDir "apply-endpoints.ps1") -Checkout $CheckoutPath

$VersionCore = $Version.Split("-")[0].Split(".")
if ($VersionCore.Count -ne 3) {
    throw "client-version.txt must begin with major.minor.patch"
}
$NumericVersion = "$($VersionCore[0]).$($VersionCore[1]).$($VersionCore[2]).0"
$PublishDirectory = Join-Path ([IO.Path]::GetTempPath()) ("zigcho-lazer-win-x64-" + [Guid]::NewGuid().ToString("N"))

try {
    & $Dotnet restore (Join-Path $CheckoutPath "osu.Desktop/osu.Desktop.csproj") -r win-x64
    if ($LASTEXITCODE -ne 0) { throw "Windows restore failed" }

    & $Dotnet publish (Join-Path $CheckoutPath "osu.Desktop/osu.Desktop.csproj") `
        -c Release -r win-x64 --self-contained true --no-restore `
        -o $PublishDirectory `
        "-p:Version=$Version" `
        "-p:FileVersion=$NumericVersion" `
        "-p:AssemblyVersion=$NumericVersion" `
        "-p:InformationalVersion=$Version+zigcho.$($ZigchoRevision.Substring(0, 8)).osu.$($OsuRevision.Substring(0, 8))" `
        -p:DebugType=None -p:DebugSymbols=false
    if ($LASTEXITCODE -ne 0) { throw "Windows publish failed" }

    $Arguments = @(
        (Join-Path $ScriptDir "package-windows.py"),
        "--publish-dir", $PublishDirectory,
        "--output-dir", $OutputDirectory,
        "--version", $Version,
        "--zigcho-revision", $ZigchoRevision,
        "--osu-revision", $OsuRevision,
        "--zigcho-license", (Join-Path $RepoRoot "LICENSE"),
        "--osu-license", (Join-Path $CheckoutPath "LICENCE")
    )
    if ($Force) { $Arguments += "--force" }
    & $Python @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Windows packaging failed" }

    $Archive = Join-Path $OutputDirectory "zigcho-lazer-$Version-windows-x64.zip"
    & $Python (Join-Path $ScriptDir "verify-windows-package.py") $Archive
    if ($LASTEXITCODE -ne 0) { throw "Windows package verification failed" }
}
finally {
    if (Test-Path -LiteralPath $PublishDirectory) {
        Remove-Item -LiteralPath $PublishDirectory -Recurse -Force
    }
}
