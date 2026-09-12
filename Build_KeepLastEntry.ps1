[CmdletBinding()]
param(
    [string]$KeePassDir,

    [ValidateSet('DLL','PLGX','Both')]
    [string]$BuildType
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Self-elevate. Building a plugin under Program Files and invoking KeePass's
# PLGX compiler is more reliable when the whole script runs elevated.
# -----------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Administrator privileges are required.'
    Write-Host 'Restarting Build_KeepLastEntry.ps1 with elevation (UAC)...'

    $scriptPath = $MyInvocation.MyCommand.Path
    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"")

    if ($KeePassDir) {
        $argumentList += @('-KeePassDir', "`"$KeePassDir`"")
    }
    if ($BuildType) {
        $argumentList += @('-BuildType', $BuildType)
    }

    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList ($argumentList -join ' ') -Verb RunAs -Wait -PassThru
        exit $p.ExitCode
    }
    catch {
        throw 'Elevation was cancelled or failed. The build was not started.'
    }
}

$scriptRoot = (Get-Item -LiteralPath $PSScriptRoot).FullName
$projectFile = Join-Path $scriptRoot 'KeepLastEntry.csproj'
$sourceFile = Join-Path $scriptRoot 'KeepLastEntry.cs'
$assemblyInfo = Join-Path $scriptRoot 'Properties\AssemblyInfo.cs'
$versionInfoFile = Join-Path $scriptRoot 'KeepLastEntry-version.txt'
$publicKeyFile = Join-Path $scriptRoot 'KeepLastEntry-update-public.xml'
$releaseDir = Join-Path $scriptRoot 'release'

function Assert-File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description not found: $Path"
    }
}

function Get-AssemblyVersion {
    Assert-File $assemblyInfo 'AssemblyInfo.cs'

    $text = [System.IO.File]::ReadAllText(
        $assemblyInfo,
        (New-Object System.Text.UTF8Encoding($false))
    )

    $m = [regex]::Match(
        $text,
        '(?m)^\s*\[assembly:\s*AssemblyFileVersion\("([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)"\)\]\s*$'
    )

    if (-not $m.Success) {
        throw "AssemblyFileVersion was not found in '$assemblyInfo'."
    }

    return $m.Groups[1].Value
}

function Get-ReleaseVersion {
    $v = Get-AssemblyVersion
    $parts = $v.Split('.')

    if ($parts.Count -eq 4 -and $parts[3] -eq '0') {
        return '{0}.{1}.{2}' -f $parts[0], $parts[1], $parts[2]
    }

    return $v
}

function Assert-VersionInfo {
    Assert-File $versionInfoFile 'KeepLastEntry-version.txt'

    $expected = Get-ReleaseVersion

    $lines = [System.IO.File]::ReadAllLines(
        $versionInfoFile,
        (New-Object System.Text.UTF8Encoding($false))
    )

    if ($lines.Count -lt 3) {
        throw "KeepLastEntry-version.txt has an invalid format: expected signature, version and footer."
    }

    # The first line contains ':' followed by the Base64 RSA signature.
    if ($lines[0] -notmatch '^:[A-Za-z0-9+/]+={0,2}$') {
        throw "KeepLastEntry-version.txt has an invalid signature line."
    }

    # The last line is the signature block terminator.
    if ($lines[$lines.Count - 1] -ne ':') {
        throw "KeepLastEntry-version.txt has an invalid header/footer format."
    }

    $matches = @(
        $lines | Where-Object {
            $_ -match '^KeepLastEntry:[0-9]+\.[0-9]+\.[0-9]+$'
        }
    )

    if ($matches.Count -ne 1) {
        throw "KeepLastEntry-version.txt must contain exactly one KeepLastEntry:X.Y.Z record."
    }

    $actual = $matches[0].Substring('KeepLastEntry:'.Length).Trim()

    if ($actual -ne $expected) {
        throw "Version mismatch: AssemblyFileVersion is $(Get-AssemblyVersion), but KeepLastEntry-version.txt contains $actual."
    }

    Write-Host "Version: $expected"
    Write-Host 'Version-info format: OK'
}

function Assert-Project {
    Assert-File $projectFile 'KeepLastEntry.csproj'
    Assert-File $sourceFile 'KeepLastEntry.cs'
    Assert-File $assemblyInfo 'Properties\AssemblyInfo.cs'
    Assert-File $versionInfoFile 'KeepLastEntry-version.txt'
    Assert-File $publicKeyFile 'KeepLastEntry-update-public.xml'

    Assert-VersionInfo

    $csproj = [System.IO.File]::ReadAllText(
        $projectFile,
        (New-Object System.Text.UTF8Encoding($false))
    )

    # Assembly metadata/version belongs in Properties\AssemblyInfo.cs.
    foreach ($tag in @(
        'AssemblyVersion',
        'FileVersion',
        'AssemblyTitle',
        'AssemblyDescription',
        'AssemblyCompany',
        'AssemblyProduct'
    )) {
        if ($csproj -match ('<' + $tag + '>')) {
            throw "KeepLastEntry.csproj must not contain <$tag> metadata; use Properties\AssemblyInfo.cs."
        }
    }

    Write-Host 'Project validation: OK'
}

# -----------------------------------------------------------------------------
# Locate KeePass automatically if -KeePassDir was not supplied.
# -----------------------------------------------------------------------------
if (-not $KeePassDir) {
    $possibleDirs = @(
        (Join-Path $env:ProgramFiles 'KeePass Password Safe 2'),
        (Join-Path ${env:ProgramFiles(x86)} 'KeePass Password Safe 2'),
        (Join-Path $env:LOCALAPPDATA 'KeePass Password Safe 2')
    ) | Where-Object { $_ -and $_ -ne '' } | Select-Object -Unique

    foreach ($d in $possibleDirs) {
        if (Test-Path -LiteralPath (Join-Path $d 'KeePass.exe')) {
            $KeePassDir = (Get-Item -LiteralPath $d).FullName
            break
        }
    }
}

if (-not $KeePassDir) {
    throw 'KeePassDir was not supplied and KeePass.exe could not be found in the standard installation directories.'
}

$KeePassDir = (Get-Item -LiteralPath $KeePassDir).FullName
$KeePassExe = Join-Path $KeePassDir 'KeePass.exe'
Assert-File $KeePassExe 'KeePass.exe'

# -----------------------------------------------------------------------------
# Release directory.
# It is deliberately recreated for every invocation, so stale artifacts from
# a previous build cannot be accidentally published.
# -----------------------------------------------------------------------------
if (Test-Path -LiteralPath $releaseDir) {
    Remove-Item -LiteralPath $releaseDir -Recurse -Force
}
New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null

# Clean normal MSBuild output before a DLL build.
foreach ($dir in @('bin','obj')) {
    $p = Join-Path $scriptRoot $dir
    if (Test-Path -LiteralPath $p) {
        Remove-Item -LiteralPath $p -Recurse -Force
    }
}

function Find-MSBuild {
    $candidates = @()

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        try {
            $installationPath = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath 2>$null
            if ($installationPath) {
                $candidates += (Join-Path $installationPath 'MSBuild\Current\Bin\MSBuild.exe')
            }
        }
        catch {}
    }

    $candidates += @(
        (Join-Path ${env:ProgramFiles} 'Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe'),
        (Join-Path ${env:ProgramFiles} 'Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe'),
        (Join-Path ${env:ProgramFiles} 'Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe'),
        (Join-Path ${env:ProgramFiles} 'Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'MSBuild\14.0\Bin\MSBuild.exe'),
        (Join-Path ${env:WINDIR} 'Microsoft.NET\Framework\v4.0.30319\MSBuild.exe'),
        (Join-Path ${env:WINDIR} 'Microsoft.NET\Framework64\v4.0.30319\MSBuild.exe')
    )

    foreach ($candidate in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate) {
            return (Get-Item -LiteralPath $candidate).FullName
        }
    }

    $cmd = Get-Command msbuild.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    return $null
}

function Build-DLL {
    # Preserve the exact MSBuild invocation known to work for the user's
    # current project.
    $msbuild = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\MSBuild.exe'

    if (-not (Test-Path -LiteralPath $msbuild)) {
        $msbuild = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\MSBuild.exe'
    }

    if (-not (Test-Path -LiteralPath $msbuild)) {
        throw 'MSBuild.exe was not found in the .NET Framework v4.0.30319 directory.'
    }

    $logFile = Join-Path $releaseDir 'DLL-build.log'

    Write-Host ''
    Write-Host "Building DLL with: $msbuild"
    Write-Host 'Command:'
    Write-Host "`"$msbuild`" `"$projectFile`" /p:Configuration=Release /p:KeePassDir=`"$KeePassDir`""
    Write-Host ''
    Write-Host "Detailed log: $logFile"
    Write-Host ''

    # Keep the working invocation unchanged: output remains visible and is
    # simultaneously captured in the release log.
    & $msbuild $projectFile /p:Configuration=Release /p:KeePassDir="$KeePassDir" 2>&1 |
        Tee-Object -FilePath $logFile

    $exitCode = $LASTEXITCODE

    Write-Host ''
    Write-Host "MSBuild exit code: $exitCode"

    if ($exitCode -ne 0) {
        throw "DLL build failed with MSBuild exit code $exitCode. See: $logFile"
    }

    $dll = Join-Path $scriptRoot 'bin\Release\KeepLastEntry.dll'
    Assert-File $dll 'Built DLL'

    $destination = Join-Path $releaseDir 'KeepLastEntry.dll'
    Copy-Item -LiteralPath $dll -Destination $destination -Force

    Write-Host "DLL created: $destination"
}

function Build-PLGX {
    # IMPORTANT: keep staging beside the source folder, not under %TEMP%.
    # This avoids KeePass PLGX relative-path problems caused by different
    # Windows path representations (long path vs 8.3 path).
    $sourceParent = Split-Path -Parent $scriptRoot
    $stageRoot = Join-Path $sourceParent ('KeepLastEntry-plgx-' + [Guid]::NewGuid().ToString('N'))
    $stage = Join-Path $stageRoot 'KeepLastEntry'

    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    $logFile = Join-Path $releaseDir 'PLGX-build.log'

    try {
        Copy-Item -LiteralPath $projectFile -Destination (Join-Path $stage 'KeepLastEntry.csproj') -Force
        Copy-Item -LiteralPath $sourceFile -Destination (Join-Path $stage 'KeepLastEntry.cs') -Force
        New-Item -ItemType Directory -Path (Join-Path $stage 'Properties') -Force | Out-Null
        Copy-Item -LiteralPath $assemblyInfo -Destination (Join-Path $stage 'Properties\AssemblyInfo.cs') -Force

        $runningKeePass = Get-Process -Name 'KeePass' -ErrorAction SilentlyContinue
        if ($runningKeePass) {
            throw "KeePass is already running (PID $($runningKeePass.Id -join ', ')). Close KeePass completely, including the tray icon, before building PLGX."
        }

        $commandLine = "`"$KeePassExe`" --plgx-create `"$stage`" --plgx-prereq-kp:2.61.1 --debug"

        Write-Host ''
        Write-Host "Building PLGX from staging directory: $stage"
        Write-Host "Detailed log: $logFile"
        Write-Host "Command: $commandLine"
        Write-Host ''

        Add-Content -LiteralPath $logFile -Value @(
            ('=' * 78),
            ('PLGX build started: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
            ('KeePass: ' + $KeePassExe),
            ('Staging: ' + $stage),
            ('Command: ' + $commandLine),
            ('=' * 78)
        )

        $startTime = Get-Date
        $stdoutFile = Join-Path $stageRoot 'plgx-stdout.log'
        $stderrFile = Join-Path $stageRoot 'plgx-stderr.log'

        $process = Start-Process -FilePath $KeePassExe `
            -ArgumentList @(
                '--plgx-create',
                "`"$stage`"",
                '--plgx-prereq-kp:2.61.1',
                '--debug'
            ) `
            -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile

        $exitCode = $process.ExitCode

        if (Test-Path -LiteralPath $stdoutFile) {
            $stdout = Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue
            if ($stdout) {
                Add-Content -LiteralPath $logFile -Value $stdout
            }
        }

        if (Test-Path -LiteralPath $stderrFile) {
            $stderr = Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue
            if ($stderr) {
                Add-Content -LiteralPath $logFile -Value $stderr
            }
        }

        Add-Content -LiteralPath $logFile -Value @(
            ('Exit code: ' + $exitCode),
            ('Finished: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        )

        if ($exitCode -ne 0) {
            throw "KeePass PLGX creation failed with process exit code $exitCode. See: $logFile"
        }

        $stageParent = Split-Path -Parent $stage
        $candidates = Get-ChildItem -LiteralPath $stageParent -Filter '*.plgx' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $startTime } |
            Sort-Object LastWriteTime -Descending

        if (-not $candidates) {
            throw "KeePass reported success but no .plgx file was found next to the staging directory: $stageParent"
        }

        $plgx = $candidates[0].FullName
        $destination = Join-Path $releaseDir 'KeepLastEntry.plgx'
        Copy-Item -LiteralPath $plgx -Destination $destination -Force

        Add-Content -LiteralPath $logFile -Value @(
            ('PLGX source: ' + $plgx),
            ('PLGX output: ' + $destination),
            ('PLGX size: ' + (Get-Item -LiteralPath $destination).Length + ' bytes')
        )

        Write-Host "PLGX created: $destination"
    }
    finally {
        if (Test-Path -LiteralPath $stageRoot) {
            Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Copy-ReleaseMetadata {
    $version = Get-ReleaseVersion

    Copy-Item -LiteralPath $versionInfoFile `
        -Destination (Join-Path $releaseDir 'KeepLastEntry-version.txt') -Force

    $manifest = @"
KeepLastEntry release $version

Automatic update asset:
  KeepLastEntry.plgx

Manual DLL installation:
  KeepLastEntry.dll

Source archive:
  KeepLastEntry-$version-source.zip

Project:
  https://github.com/ArtyoZ/KeepLastEntry

GitHub release:
  https://github.com/ArtyoZ/KeepLastEntry/releases/latest
"@

    [System.IO.File]::WriteAllText(
        (Join-Path $releaseDir 'README.txt'),
        $manifest,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function New-SourceArchive {
    $version = Get-ReleaseVersion
    $archive = Join-Path $releaseDir ("KeepLastEntry-{0}-source.zip" -f $version)

    if (Test-Path -LiteralPath $archive) {
        Remove-Item -LiteralPath $archive -Force
    }

    # Keep this list explicit. Private keys and arbitrary build output must
    # never enter the source archive.
    $items = @(
        'KeepLastEntry.cs',
        'KeepLastEntry.csproj',
        'Build_KeepLastEntry.ps1',
        'Sign-UpdateInfo.ps1',
        'KeepLastEntry-version.txt',
        'KeepLastEntry-update-public.xml',
        'README.md',
        '.gitignore',
        'Properties'
    )

    $existing = @()

    foreach ($item in $items) {
        $path = Join-Path $scriptRoot $item

        if (Test-Path -LiteralPath $path) {
            $existing += $path
        }
        else {
            Write-Warning "Source archive item not found, skipping: $item"
        }
    }

    if ($existing.Count -eq 0) {
        throw 'No source files available for source archive.'
    }

    $temp = Join-Path ([System.IO.Path]::GetTempPath()) `
        ('KeepLastEntry-source-' + [Guid]::NewGuid().ToString('N'))

    try {
        New-Item -ItemType Directory -Path $temp -Force | Out-Null

        foreach ($path in $existing) {
            $relative = $path.Substring($scriptRoot.Length).TrimStart('\')
            $destination = Join-Path $temp $relative
            $parent = Split-Path -Parent $destination

            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }

            if ((Get-Item -LiteralPath $path).PSIsContainer) {
                Copy-Item -LiteralPath $path -Destination $destination -Recurse -Force
            }
            else {
                Copy-Item -LiteralPath $path -Destination $destination -Force
            }
        }

        Compress-Archive `
            -Path (Join-Path $temp '*') `
            -DestinationPath $archive `
            -CompressionLevel Optimal
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "Source ZIP: $archive"
}

function Invoke-Build {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('DLL','PLGX','Both')]
        [string]$Mode
    )

    Write-Host ''
    Write-Host "Mode:    $Mode"

    try {
        Assert-Project

        switch ($Mode) {
            'DLL' {
                Build-DLL
                Copy-ReleaseMetadata
            }

            'PLGX' {
                Build-PLGX
                Copy-ReleaseMetadata
            }

            'Both' {
                Build-DLL
                Build-PLGX
                Copy-ReleaseMetadata
                New-SourceArchive
            }
        }

        Write-Host ''
        Write-Host '========================================' -ForegroundColor Green
        Write-Host 'BUILD COMPLETED' -ForegroundColor Green
        Write-Host '========================================' -ForegroundColor Green
        Write-Host ''
        Write-Host 'Files in release:'

        Get-ChildItem -LiteralPath $releaseDir -File |
            Sort-Object Name |
            ForEach-Object {
                Write-Host ("  {0}  ({1:N0} bytes)" -f $_.Name, $_.Length)
            }

        return $true
    }
    catch {
        Write-Host ''
        Write-Host '========================================' -ForegroundColor Red
        Write-Host 'BUILD FAILED' -ForegroundColor Red
        Write-Host '========================================' -ForegroundColor Red
        Write-Host ''
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host ''
        Write-Host "Error details: $($_ | Out-String)"
        return $false
    }
}

# -----------------------------------------------------------------------------
# Non-interactive mode:
#   .\Build_KeepLastEntry.ps1 -BuildType DLL
#   .\Build_KeepLastEntry.ps1 -BuildType PLGX
#   .\Build_KeepLastEntry.ps1 -BuildType Both
# -----------------------------------------------------------------------------
$interactive = [string]::IsNullOrWhiteSpace($BuildType)

if (-not $interactive) {
    $ok = Invoke-Build -Mode $BuildType
    if (-not $ok) {
        exit 1
    }

    exit 0
}

# -----------------------------------------------------------------------------
# Interactive menu.
# -----------------------------------------------------------------------------
while ($true) {
    Write-Host ''
    Write-Host 'KeepLastEntry build'
    Write-Host '==================='
    Write-Host '1. DLL'
    Write-Host '2. PLGX'
    Write-Host '3. DLL + PLGX + source ZIP'
    Write-Host '4. Exit'
    Write-Host ''

    do {
        $choice = Read-Host 'Choose [1-4]'
    } while ($choice -notin @('1','2','3','4'))

    if ($choice -eq '4') {
        Write-Host ''
        Write-Host 'Exit.'
        break
    }

    switch ($choice) {
        '1' { [void](Invoke-Build -Mode 'DLL') }
        '2' { [void](Invoke-Build -Mode 'PLGX') }
        '3' { [void](Invoke-Build -Mode 'Both') }
    }

    Write-Host ''
    [void](Read-Host 'Press Enter to return to the menu')
}
