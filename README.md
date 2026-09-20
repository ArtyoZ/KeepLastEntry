# KeepLastEntry — KeePass 2.x plugin

KeePass plugin that restores the last selected entry when a database is reopened.

The remembered entry is stored in the KeePass plugin configuration, not in the KDBX database. Therefore, changing the selection does not modify or mark the database as changed.

Entries are identified by their UUID, so the remembered selection remains valid when an entry is moved or renamed.

## Build

Run `Build_KeepLastEntry.ps1`. The script automatically requests Administrator privileges through UAC if it is not already elevated.

If no parameters are supplied, it automatically finds KeePass in the standard installation directory and displays:

1. DLL
2. PLGX
3. DLL + PLGX + source ZIP
4. Exit

For unattended use:

```powershell
.\Build_KeepLastEntry.ps1 -BuildType DLL
.\Build_KeepLastEntry.ps1 -BuildType PLGX
.\Build_KeepLastEntry.ps1 -BuildType Both
```

`-KeePassDir` is optional. Example:

```powershell
.\Build_KeepLastEntry.ps1 -KeePassDir "C:\Program Files\KeePass Password Safe 2" -BuildType Both
```

The script rebuilds the `release` directory on each invocation.

### Build output

The resulting files are placed in `release`:

```text
release\
    KeepLastEntry.dll
    KeepLastEntry.plgx
    KeepLastEntry-1.0.0-source.zip
    KeepLastEntry-version.txt
    README.txt
    DLL-build.log
    PLGX-build.log
```

Depending on the selected build type, not all binary files are necessarily regenerated.

The source ZIP contains the project source and build-related files required to reproduce the build. The private RSA update-signing key is never included.

### DLL build

The DLL build uses the same MSBuild command as the standalone `Build-DLL.ps1`:

```text
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\MSBuild.exe <project> /p:Configuration=Release /p:KeePassDir="..."
```

DLL compiler output is shown in the console and saved to:

```text
release\DLL-build.log
```

### PLGX build

For PLGX builds KeePass must be completely closed, including its tray process.

The PLGX build uses a staging directory beside the source directory. This avoids the Windows long-path/8.3-path mismatch that can otherwise produce unsafe `../../...` paths inside the PLGX archive.

The build invokes KeePass with `--plgx-create`. Debug information and KeePass compiler output are saved to:

```text
release\PLGX-build.log
```

The resulting plugin is:

```text
release\KeepLastEntry.plgx
```

The PLGX file is the primary distribution format for KeePass plugin installation and automatic updates.

## Version information

The plugin version is currently:

```text
1.0.0.0
```

The human-readable update version is:

```text
1.0.0
```

Assembly metadata is defined in:

```text
Properties\AssemblyInfo.cs
```

The plugin exposes the KeePass update information URL:

```text
https://raw.githubusercontent.com/ArtyoZ/KeepLastEntry/refs/heads/main/KeepLastEntry-version.txt
```

## Signed update information

`KeepLastEntry-version.txt` contains the current plugin version and an RSA signature.

Its format is:

```text
:<Base64 RSA signature>
KeepLastEntry:1.0.0
:
```

The signature is generated using:

- RSA
- SHA-512
- UTF-8 encoding
- LF line endings
- canonical payload consisting of the non-empty version lines followed by LF

The corresponding public RSA key is embedded in the plugin and is also stored in:

```text
KeepLastEntry-update-public.xml
```

The private signing key is kept separately and must never be committed to the repository, included in the source archive, or published with a release.

### Sign-UpdateInfo.ps1

`Sign-UpdateInfo.ps1` signs `KeepLastEntry-version.txt`.

The private key path is supplied explicitly:

```powershell
.\Sign-UpdateInfo.ps1 -PrivateKeyFile ".\private\KeepLastEntry-update-private.xml"
```

Relative paths are resolved relative to the directory containing `Sign-UpdateInfo.ps1`, rather than the current PowerShell working directory.

Therefore, the command works correctly even when PowerShell was started from another directory.

The version information file is optional and defaults to:

```text
KeepLastEntry-version.txt
```

in the script directory.

Example with an explicit version-information file:

```powershell
.\Sign-UpdateInfo.ps1 `
    -PrivateKeyFile ".\private\KeepLastEntry-update-private.xml" `
    -VersionInfoFile ".\KeepLastEntry-version.txt"
```

The signing script writes UTF-8 without BOM.

## Automatic updates

KeepLastEntry uses two related but separate KeePass update mechanisms.

### 1. `UpdateCheckEx` — update information and signature verification

The plugin exposes an update information URL through the KeePass `Plugin.UpdateUrl` property:

```text
https://raw.githubusercontent.com/ArtyoZ/KeepLastEntry/refs/heads/main/KeepLastEntry-version.txt
```

During initialization, the plugin registers its embedded RSA public key with KeePass:

```csharp
UpdateCheckEx.SetFileSigKey(UpdateUrl, UpdateInformationPublicKey);
```

This allows KeePass `UpdateCheckEx` to verify the RSA/SHA-512 signature contained in `KeepLastEntry-version.txt`.

The signed file provides the current plugin version:

```text
:<Base64 RSA signature>
KeepLastEntry:1.0.0
:
```

The signature protects the version information against unauthorized modification. The private signing key is not stored in the repository or distributed with the plugin.

### 2. EarlyUpdateCheck — plugin package installation

KeePass EarlyUpdateCheck is a separate mechanism used to discover and install plugin updates.

For details, see the [EarlyUpdateCheck project](https://github.com/Rookiestyle/EarlyUpdateCheck).

For KeepLastEntry, the external update entry points to the GitHub Releases package:

```xml
<UpdateInfoExtern>
    <PluginName>KeepLastEntry</PluginName>
    <PluginURL>https://github.com/ArtyoZ/KeepLastEntry</PluginURL>
    <PluginUpdateURL>https://github.com/ArtyoZ/KeepLastEntry/releases/latest/download/KeepLastEntry.plgx</PluginUpdateURL>
    <UpdateMode>PlgxDirect</UpdateMode>
    <AllowVersionStripping>False</AllowVersionStripping>
</UpdateInfoExtern>
```

In this configuration:

- `UpdateUrl` / `UpdateCheckEx` identifies and verifies the signed version information.
- `KeepLastEntry-version.txt` is the signed version-information file.
- `EarlyUpdateCheck` uses `PluginUpdateURL` to obtain the actual plugin package.
- `KeepLastEntry.plgx` is the primary package intended for KeePass plugin installation and automatic updating.
- The GitHub repository URL is used as the plugin project/homepage URL.

The two mechanisms therefore have different purposes: **`UpdateCheckEx` verifies the trusted update information, while EarlyUpdateCheck obtains the actual `.plgx` package.**

## Release contents

A GitHub Release should publish:

```text
KeepLastEntry.plgx
KeepLastEntry.dll
KeepLastEntry-1.0.0-source.zip
```

`KeepLastEntry.plgx` is the primary plugin distribution and automatic-update package.

The DLL is provided as an alternative distribution format.

The source ZIP provides the corresponding source code and build files.

`KeepLastEntry-version.txt` is maintained in the repository and is used as the signed update-information file; it does not need to be duplicated as a GitHub Release asset.

## Interactive build menu

When `Build_KeepLastEntry.ps1` is started without `-BuildType`, it displays the following menu:

```text
1. DLL
2. PLGX
3. DLL + PLGX + source ZIP
4. Exit
```

After each build operation, the script returns to the menu.

Selecting:

```text
4. Exit
```

terminates the script.

## Requirements

- Windows
- KeePass 2.61.1
- .NET Framework / MSBuild 4.x
- PowerShell
- Administrator privileges for the build script when required
- KeePass must be closed for PLGX creation

## Repository

GitHub repository:

https://github.com/ArtyoZ/KeepLastEntry
