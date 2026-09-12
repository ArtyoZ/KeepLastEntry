[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PrivateKeyFile,

    [Parameter(Mandatory = $false)]
    [string]$VersionInfoFile = (Join-Path $PSScriptRoot 'KeepLastEntry-version.txt')
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Resolve relative paths relative to the script directory, not the current
# PowerShell working directory.
# -----------------------------------------------------------------------------

function Resolve-ScriptRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath(
        (Join-Path $PSScriptRoot $Path)
    )
}

$PrivateKeyFile = Resolve-ScriptRelativePath $PrivateKeyFile
$VersionInfoFile = Resolve-ScriptRelativePath $VersionInfoFile

# -----------------------------------------------------------------------------
# Validate input files
# -----------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $PrivateKeyFile -PathType Leaf)) {
    throw "Private RSA key file not found: $PrivateKeyFile"
}

if (-not (Test-Path -LiteralPath $VersionInfoFile -PathType Leaf)) {
    throw "Version information file not found: $VersionInfoFile"
}

# -----------------------------------------------------------------------------
# Read version information
# -----------------------------------------------------------------------------

$text = [System.IO.File]::ReadAllText(
    $VersionInfoFile,
    [System.Text.Encoding]::UTF8
)

$lines = $text -split "`r?`n"

if ($lines.Count -lt 3) {
    throw 'Version information file is too short.'
}

# The first line contains ':' followed by the Base64 signature.

if ($lines[0].Length -lt 1 -or $lines[0].Substring(0, 1) -ne ':') {
    throw 'The version information file must use : as the separator.'
}

# Remove the empty element caused by a trailing newline.

if ($lines[$lines.Count - 1] -eq '') {
    $lines = $lines[0..($lines.Count - 2)]
}

if ($lines[$lines.Count - 1] -ne ':') {
    throw 'Version information file must end with a line containing only :.'
}

# -----------------------------------------------------------------------------
# Extract canonical payload
# -----------------------------------------------------------------------------

$payloadLines = @()

for ($i = 1; $i -lt ($lines.Count - 1); $i++) {
    $trimmed = $lines[$i].Trim()

    if ($trimmed.Length -gt 0) {
        $payloadLines += $trimmed
    }
}

if ($payloadLines.Count -eq 0) {
    throw 'Version information file contains no plugin versions.'
}

$payload = [System.Text.Encoding]::UTF8.GetBytes(
    ($payloadLines -join "`n") + "`n"
)

# -----------------------------------------------------------------------------
# Sign payload with RSA/SHA-512
# -----------------------------------------------------------------------------

$rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider

try {
    $rsa.PersistKeyInCsp = $false

    $privateXml = [System.IO.File]::ReadAllText(
        $PrivateKeyFile,
        [System.Text.Encoding]::UTF8
    )

    $rsa.FromXmlString($privateXml)

    $signature = $rsa.SignData(
        $payload,
        [System.Security.Cryptography.CryptoConfig]::MapNameToOID('SHA512')
    )
}
finally {
    $rsa.Dispose()
}

# -----------------------------------------------------------------------------
# Write signed version information
# -----------------------------------------------------------------------------

$signatureBase64 = [Convert]::ToBase64String($signature)

$output =
    ':' + $signatureBase64 + "`n" +
    ($payloadLines -join "`n") + "`n:`n"

[System.IO.File]::WriteAllText(
    $VersionInfoFile,
    $output,
    (New-Object System.Text.UTF8Encoding -ArgumentList $false)
)

Write-Host "Signed: $VersionInfoFile"