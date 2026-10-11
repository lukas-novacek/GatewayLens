<#
.SYNOPSIS
    Builds dist\GatewayLens.exe from GatewayLens.ps1.

.DESCRIPTION
    Needs the .NET SDK (any version from 6 on):  winget install Microsoft.DotNet.SDK.8
    The exe takes its version from $script:AppVersion in GatewayLens.ps1, so the
    two can never disagree. GitHub Actions runs this same script for every push
    and for every release.
#>
#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
$root    = Split-Path -Parent $PSScriptRoot
$script  = Join-Path $root 'GatewayLens.ps1'
$project = Join-Path $PSScriptRoot 'launcher/GatewayLens.csproj'
$dist    = Join-Path $root 'dist'

$m = [regex]::Match((Get-Content $script -Raw), "AppVersion\s*=\s*'(\d+\.\d+\.\d+)'")
if (-not $m.Success) { throw 'Could not read $script:AppVersion from GatewayLens.ps1.' }
$version = $m.Groups[1].Value

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'The .NET SDK is not installed. Install it with: winget install Microsoft.DotNet.SDK.8'
}

Write-Host "Building GatewayLens.exe $version" -ForegroundColor Cyan
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
dotnet build $project -c Release -o $dist -p:Version=$version --nologo
if ($LASTEXITCODE) { throw "dotnet build failed (exit $LASTEXITCODE)." }

# keep only what is shipped
Get-ChildItem $dist | Where-Object { $_.Name -ne 'GatewayLens.exe' } | Remove-Item -Recurse -Force
$exe = Get-Item (Join-Path $dist 'GatewayLens.exe')
$fv  = $exe.VersionInfo.FileVersion
Write-Host ("Built {0}  ({1:N0} KB, file version {2})" -f $exe.FullName, ($exe.Length / 1KB), $fv) -ForegroundColor Green
if (-not $fv.StartsWith($version)) { throw "The exe reports version $fv, expected $version." }
