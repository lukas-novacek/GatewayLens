<#
.SYNOPSIS
    Checks a release before it goes out - or after you downloaded it.

.DESCRIPTION
    - GatewayLens.exe carries exactly the GatewayLens.ps1 that is released next to it.
    - -Signed: both carry a signature - any certificate, so SignPath's test signing
      passes too.
    - -Publisher: both are validly signed by that publisher, with a timestamp, so the
      signature outlives the certificate.

    The release workflow runs it after the build. On a download, from a copy of the
    repository at the release's tag:
        .\build\Test-Release.ps1 -Exe .\GatewayLens.exe -Script .\GatewayLens.ps1 -Publisher 'SignPath Foundation'
#>
#Requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][string]$Script,
    [switch]$Signed,
    [string]$Publisher
)
$ErrorActionPreference = 'Stop'

function Get-EmbeddedScript([string]$Path) {
    # The script is a .NET resource of the exe: read it from the file, without
    # loading - let alone running - the exe.
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $pe  = [System.Reflection.PortableExecutable.PEReader]::new($fs)
        $md  = [System.Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($pe)
        $dir = $pe.PEHeaders.CorHeader.ResourcesDirectory
        foreach ($h in $md.ManifestResources) {
            $r = $md.GetManifestResource($h)
            if ($md.GetString($r.Name) -ne 'GatewayLens.ps1') { continue }
            $rd = $pe.GetSectionData($dir.RelativeVirtualAddress + [int]$r.Offset).GetReader()
            return , $rd.ReadBytes($rd.ReadInt32())
        }
    }
    finally { $fs.Dispose() }
    throw "$Path does not carry GatewayLens.ps1."
}

function Get-Sha256([byte[]]$Bytes) {
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

$problems = [System.Collections.Generic.List[string]]::new()
$inside  = Get-EmbeddedScript $Exe
$outside = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Script).Path)
$hashIn  = Get-Sha256 $inside
$hashOut = Get-Sha256 $outside
if ($hashIn -ne $hashOut) { $problems.Add("The exe carries another script ($hashIn) than the one released next to it ($hashOut).") }
else { Write-Host "The exe carries exactly the released script - SHA-256 $hashIn" }

if ($Signed -or $Publisher) {
    foreach ($f in $Exe, $Script) {
        $leaf = Split-Path $f -Leaf
        $sig  = Get-AuthenticodeSignature -FilePath $f
        if (-not $sig.SignerCertificate) { $problems.Add("$leaf is not signed."); continue }
        $who = $sig.SignerCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
        if ($Publisher) {
            if ($sig.Status -ne 'Valid') { $problems.Add("$leaf has a signature that is $($sig.Status): $($sig.StatusMessage)"); continue }
            if ($who -ne $Publisher) { $problems.Add("$leaf is signed by '$who', not by '$Publisher'."); continue }
            if (-not $sig.TimeStamperCertificate) { $problems.Add("$leaf has no timestamp - its signature would end with the certificate."); continue }
        }
        Write-Host "$leaf is signed by $who - $($sig.Status)"
    }
}

if ($problems.Count) { throw ($problems -join [Environment]::NewLine) }
Write-Host 'The release is ready.' -ForegroundColor Green
