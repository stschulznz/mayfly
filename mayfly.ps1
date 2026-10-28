<#
.SYNOPSIS
    Mayfly for Windows 11 with WSL2: disposable, RAM-only browser sessions over WireGuard.
.DESCRIPTION
    preflight                  Check Windows and WSL (read-only) and print the fix for anything missing.
    setup [-Yes] [-Rebuild]    Fetch and verify a Debian rootfs, build the base distro "mayfly", import it.
    check-profile [-Profile P] Check the WireGuard profile format without printing it.
    launch [-Entry firefox|i2p|tor] [-Profile P]  Start one session. Close the browser to end it.
    cleanup                    Remove stale session mounts and stop the base distro.
    uninstall [-Yes]           Unregister the base distro and delete the downloaded and built files.
    State lives in %LOCALAPPDATA%\mayfly (override with MAYFLY_HOME), owner-only.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [switch]$Yes,
    [switch]$Rebuild,
    [ValidateSet('firefox', 'i2p', 'tor')][string]$Entry,
    [string]$Profile
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:MfDistro = 'mayfly'
$script:MfBuildDistro = 'mayfly-build'
$script:MfLib = '/usr/local/lib/mayfly'
$script:MfRootfsBase = 'https://raw.githubusercontent.com/debuerreotype/docker-debian-artifacts/dist-amd64/trixie/oci'
$script:MfSourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# Fail with a fixed, prefixed message; the main block prints it and exits 1.
function Stop-Mf([string]$Message) { throw "BLOCKED: $Message" }

# State folder: MAYFLY_HOME if set, else %LOCALAPPDATA%\mayfly.
function Get-MfHome {
    if ($env:MAYFLY_HOME) { return $env:MAYFLY_HOME }
    return (Join-Path $env:LOCALAPPDATA 'mayfly')
}

# A named subfolder or file under the state folder.
function Get-MfPath([string]$Name) { Join-Path (Get-MfHome) $Name }

# wsl.exe prints UTF-16 unless WSL_UTF8 is honoured; strip NULs either way.
function Invoke-Wsl {
    $env:WSL_UTF8 = '1'
    $ErrorActionPreference = 'Continue'
    $text = (& wsl.exe @args 2>&1 | Out-String) -replace "`0", ''
    [pscustomobject]@{ Code = $LASTEXITCODE; Text = $text }
}

# Windows build number (22000 or higher is Windows 11).
function Get-MfWindowsBuild { [int](Get-CimInstance Win32_OperatingSystem).BuildNumber }

# SID of the current Windows account, used for owner-only ACLs.
function Get-MfUserSid { [Security.Principal.WindowsIdentity]::GetCurrent().User }

# A folder must have inheritance cut. A file may inherit from an owner-only folder, so only
# its effective entries are judged.
function Test-MfOwnerOnlyAcl([string]$Path, [switch]$AllowInherited) {
    $acl = Get-Acl -LiteralPath $Path
    if (-not $AllowInherited -and -not $acl.AreAccessRulesProtected) { return $false }
    $me = Get-MfUserSid
    $rules = @($acl.Access)
    if ($rules.Count -eq 0) { return $false }
    foreach ($rule in $rules) {
        $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier])
        if ($sid.Value -ne $me.Value -or $rule.AccessControlType -ne 'Allow') { return $false }
    }
    $true
}

# Cut inheritance and grant only the current account, then confirm no other entry remains.
function Set-MfOwnerOnlyAcl([string]$Path) {
    $isDir = Test-Path -LiteralPath $Path -PathType Container
    $grant = if ($isDir) { '(OI)(CI)F' } else { '(F)' }
    $out = & icacls.exe $Path /inheritance:r /grant:r "*$((Get-MfUserSid).Value):$grant" 2>&1
    if ($LASTEXITCODE -ne 0) { Stop-Mf "could not restrict permissions on $Path" }
    # Remove any explicit entry that is not the current user.
    $acl = Get-Acl -LiteralPath $Path
    foreach ($rule in @($acl.Access)) {
        $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier])
        if ($sid.Value -ne (Get-MfUserSid).Value) { Stop-Mf "unexpected permission entry on $Path" }
    }
}
# Create the state folders. Only pins and secrets are owner-only: the WSL service cannot create the distro disk in an owner-only folder.
function Initialize-MfState {
    $root = Get-MfHome
    foreach ($dir in @($root, (Get-MfPath 'pins'), (Get-MfPath 'secrets'), (Get-MfPath 'downloads'),
            (Get-MfPath 'build'), (Get-MfPath 'rootfs'), (Get-MfPath 'distro'))) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    }
    # Only the profile folder (and pins) is owner-only. The WSL service cannot create
    # or open the distro disk under an owner-only folder, so the rest keeps the default ACL.
    foreach ($dir in @('pins', 'secrets')) { Set-MfOwnerOnlyAcl (Get-MfPath $dir) }
}

# Returns the swap value from [wsl2] in .wslconfig, or $null when unset.
function Get-WslConfigSwap {
    $file = if ($env:MAYFLY_WSLCONFIG) { $env:MAYFLY_WSLCONFIG } else { Join-Path $env:USERPROFILE '.wslconfig' }
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $section = ''
    $swap = $null
    foreach ($line in (Get-Content -LiteralPath $file)) {
        $line = $line.Trim()
        if ($line -match '^\[(.+)\]$') { $section = $Matches[1].ToLowerInvariant(); continue }
        if ($section -eq 'wsl2' -and $line -match '^swap\s*=\s*([^#;]*)') { $swap = $Matches[1].Trim() }
    }
    $swap
}

# True for an explicit zero swap value in any unit spelling (0, 0GB, 0 MB).
function Test-MfSwapZero($Value) { $null -ne $Value -and $Value -match '^0+\s*(B|KB|MB|GB|TB)?$' }

# True when wsl.exe lists a distro with exactly this name.
function Test-MfDistroExists([string]$Name) {
    $r = Invoke-Wsl --list --quiet
    $r.Code -eq 0 -and @($r.Text -split "`r?`n" | ForEach-Object { $_.Trim() }) -contains $Name
}

# Preflight output: a passed check.
function Write-MfOk([string]$Text) { Write-Host "ok:      $Text" }
# Preflight output: a failed check and the exact fix.
function Write-MfBad([string]$Text, [string]$Fix) { Write-Host "MISSING: $Text"; Write-Host "         Fix: $Fix" }

# Read-only. Returns $true when every Windows-side check and (if installed) every
# in-distro check passes.
function Invoke-MfPreflight {
    $good = $true
    $build = Get-MfWindowsBuild
    if ($build -ge 22000) { Write-MfOk "Windows 11 (build $build)" }
    else { Write-MfBad 'Windows 11 is required (WSLg and the WSL2 kernel features need it)' 'update Windows'; $good = $false }

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        Write-MfBad 'wsl.exe was not found' 'run "wsl --install" from an administrator PowerShell and restart'
        return $false
    }
    $v = Invoke-Wsl --version
    if ($v.Code -eq 0 -and $v.Text -match 'WSL version:\s*(\d+)\.(\d+)' -and [int]$Matches[1] -ge 2) {
        Write-MfOk 'WSL (Store version) is installed'
        if ($v.Text -match 'WSLg version:\s*\d') { Write-MfOk 'WSLg is installed' }
        else { Write-MfBad 'WSLg is not reported by wsl --version' 'run "wsl --update"'; $good = $false }
    } else {
        Write-MfBad 'a current WSL2 is not installed' 'run "wsl --update" (or "wsl --install") from an administrator PowerShell'
        $good = $false
    }

    $swap = Get-WslConfigSwap
    if (Test-MfSwapZero $swap) { Write-MfOk '.wslconfig sets swap=0' }
    else {
        Write-MfBad '.wslconfig does not set swap=0 (WSL swap is global to every distro)' `
            'put "[wsl2]" and "swap=0" in %UserProfile%\.wslconfig, then run "wsl --shutdown"'
        $good = $false
    }

    if (Test-MfDistroExists $script:MfDistro) {
        Write-MfOk "distro $($script:MfDistro) is installed"
        $r = Invoke-Wsl -d $script:MfDistro -u root -- "$($script:MfLib)/session.sh" preflight
        Write-Host ($r.Text.TrimEnd())
        if ($r.Code -ne 0) { $good = $false }
    } else {
        Write-MfBad "distro $($script:MfDistro) is not installed" 'run ".\mayfly.ps1 setup"'
        $good = $false
    }
    $good
}

# Read the WireGuard profile as raw bytes after size, link and permission checks. Never prints or logs content.
function Read-MfProfileBytes([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Stop-Mf 'the WireGuard profile was not found' }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -lt 1 -or $item.Length -gt 16384) { Stop-Mf 'the profile must be 1..16384 bytes' }
    if ($item.LinkType) { Stop-Mf 'the profile must not be a link' }
    if (-not (Test-MfOwnerOnlyAcl $Path -AllowInherited) -or -not (Test-MfOwnerOnlyAcl (Split-Path -Parent $Path))) {
        Stop-Mf 'the profile and its folder must be readable by your account only; keep it in the secrets folder, which setup restricts'
    }
    , [IO.File]::ReadAllBytes($Path)
}

# Starts wsl.exe with the given argument string, feeds the bytes to its stdin as
# raw data and waits. Output goes to this console. Returns the exit code.
function Invoke-MfWslWithStdin([string]$Arguments, [byte[]]$Bytes) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'wsl.exe'
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $p = [Diagnostics.Process]::Start($psi)
    try {
        $stream = $p.StandardInput.BaseStream
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Close()
        $p.WaitForExit()
        $p.ExitCode
    } finally {
        if (-not $p.HasExited) { $p.Kill() }
        [Array]::Clear($Bytes, 0, $Bytes.Length)
    }
}

# The profile to use: -Profile if given, else secrets\wireguard.conf.
function Get-MfProfilePath { if ($Profile) { $Profile } else { Get-MfPath 'secrets\wireguard.conf' } }

# Send the profile to the distro to be parsed by the shared strict parser; nothing is printed.
function Invoke-MfCheckProfile {
    if (-not (Test-MfDistroExists $script:MfDistro)) { Stop-Mf 'the base distro is not installed; run ".\mayfly.ps1 setup"' }
    $bytes = Read-MfProfileBytes (Get-MfProfilePath)
    $code = Invoke-MfWslWithStdin "-d $($script:MfDistro) -u root -- $($script:MfLib)/session.sh check-profile" $bytes
    if ($code -ne 0) { Stop-Mf 'the WireGuard profile was refused' }
}

# Without -Entry, ask.
function Select-MfEntry {
    if ($script:Entry) { return $script:Entry }
    if ([Console]::IsInputRedirected) { return 'firefox' }
    Write-Host 'Choose a browser:'
    Write-Host '  1  Firefox over WireGuard'
    Write-Host '  2  I2P over WireGuard (eepsites only)'
    Write-Host '  3  Tor Browser over WireGuard'
    switch ((Read-Host 'Number [1]').Trim()) {
        '' { return 'firefox' }
        '1' { return 'firefox' }
        '2' { return 'i2p' }
        '3' { return 'tor' }
        default { Stop-Mf 'choose 1, 2 or 3' }
    }
}

# Start one session. The profile goes to the distro on stdin, and cleanup always runs afterwards.
function Invoke-MfLaunch {
    if (-not (Test-MfDistroExists $script:MfDistro)) { Stop-Mf 'the base distro is not installed; run ".\mayfly.ps1 setup"' }
    $choice = Select-MfEntry
    $bytes = Read-MfProfileBytes (Get-MfProfilePath)
    $swap = Get-WslConfigSwap
    if (-not (Test-MfSwapZero $swap)) {
        Write-Warning 'swap=0 is not set in .wslconfig; the session will refuse to start if the WSL VM has swap.'
    }
    $code = 1
    try {
        $code = Invoke-MfWslWithStdin "-d $($script:MfDistro) -u root -- $($script:MfLib)/session.sh run $choice" $bytes
    } finally {
        Invoke-MfCleanup | Out-Null
    }
    if ($code -ne 0) { Stop-Mf "the session ended with an error (exit code $code)" }
}

# Remove stale session mounts, then stop the base distro (which frees the session RAM).
function Invoke-MfCleanup {
    if (-not (Test-MfDistroExists $script:MfDistro)) { return }
    Invoke-Wsl -d $script:MfDistro -u root -- "$($script:MfLib)/session.sh" cleanup | Out-Null
    # Ends every process in the distro; the session tmpfs lives in its RAM only.
    Invoke-Wsl --terminate $script:MfDistro | Out-Null
}

# Read and strictly validate the rootfs pins file (literal KEY=value lines only).
function Get-MfPins([string]$Path) {
    $pins = @{}
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match '^(ROOTFS_URL|ROOTFS_SHA256)=(\S+)$') { $pins[$Matches[1]] = $Matches[2] }
        else { Stop-Mf 'the pins file has an unexpected line' }
    }
    if ($pins['ROOTFS_URL'] -notmatch '^https://raw\.githubusercontent\.com/debuerreotype/docker-debian-artifacts/[A-Za-z0-9._/-]+$' -or
        $pins['ROOTFS_SHA256'] -notmatch '^[a-f0-9]{64}$') { Stop-Mf 'the pins file failed validation' }
    $pins
}

# Show what will be downloaded, ask, then record the published rootfs URL and SHA-256.
function New-MfPins([string]$Path) {
    $manifest = Invoke-RestMethod -Uri "$($script:MfRootfsBase)/blobs/image-manifest.json"
    $digest = [string]$manifest.layers[0].digest
    if ($digest -notmatch '^sha256:([a-f0-9]{64})$') { Stop-Mf 'the published manifest has no valid layer digest' }
    $sha = $Matches[1]
    $url = "$($script:MfRootfsBase)/blobs/rootfs.tar.gz"
    Write-Host 'Mayfly will download and verify:'
    Write-Host "  Debian trixie rootfs: $url"
    Write-Host "  Published SHA-256:    $sha"
    Write-Host 'Debian publishes no detached signature for this file. Trust here is HTTPS to GitHub'
    Write-Host 'plus the digest in the same Debian artifacts repository, not signed provenance.'
    Write-Host 'Setup also contacts Debian mirrors, the Tor Project and keys.openpgp.org, and takes the current'
    Write-Host 'Tor Browser version without asking. The downloads expose your IP address. -Yes skips this review.'
    if (-not $Yes) {
        if ((Read-Host 'Continue? [y/N]') -notmatch '^(y|yes)$') { Stop-Mf 'not confirmed; nothing was downloaded or written' }
    }
    [IO.File]::WriteAllText($Path, "ROOTFS_URL=$url`nROOTFS_SHA256=$sha`n")
    Set-MfOwnerOnlyAcl $Path
}

# Download the rootfs once and delete it if its SHA-256 does not match the pin.
function Get-MfVerifiedDownload($Pins) {
    $file = Join-Path (Get-MfPath 'downloads') 'debian-rootfs.tar.gz'
    if (-not (Test-Path -LiteralPath $file)) { Invoke-WebRequest -Uri $Pins['ROOTFS_URL'] -OutFile $file }
    if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Pins['ROOTFS_SHA256']) {
        Remove-Item -LiteralPath $file -Force
        Stop-Mf 'the downloaded rootfs does not match the pinned SHA-256 and was deleted'
    }
    Write-Host 'ok: the rootfs matches the pinned SHA-256'
    $file
}

# Build the base distro: verified rootfs, temporary build distro, provision, export with a checksum, import.
function Invoke-MfSetup {
    $v = Invoke-Wsl --version
    if ($v.Code -ne 0) { Stop-Mf 'WSL is not installed; run ".\mayfly.ps1 preflight"' }
    Initialize-MfState
    if (Test-MfDistroExists $script:MfDistro) {
        if (-not $Rebuild) { Stop-Mf "distro $($script:MfDistro) already exists; use -Rebuild to replace it, or uninstall" }
    }
    $pinsFile = Join-Path (Get-MfPath 'pins') 'wsl.pins'
    if (-not (Test-Path -LiteralPath $pinsFile)) { New-MfPins $pinsFile }
    $pins = Get-MfPins $pinsFile
    $download = Get-MfVerifiedDownload $pins

    if (Test-MfDistroExists $script:MfBuildDistro) { Invoke-Wsl --unregister $script:MfBuildDistro | Out-Null }
    $buildDir = Join-Path (Get-MfPath 'build') 'distro'
    if (Test-Path -LiteralPath $buildDir) { Remove-Item -LiteralPath $buildDir -Recurse -Force }
    try {
        if ((Invoke-Wsl --import $script:MfBuildDistro $buildDir $download --version 2).Code -ne 0) { Stop-Mf 'could not import the build distro' }
        if ($script:MfSourceRoot.Contains("'")) { Stop-Mf 'the Mayfly folder path must not contain an apostrophe' }
        $winPath = $script:MfSourceRoot -replace '\\', '/'
        $src = (Invoke-Wsl -d $script:MfBuildDistro -u root -- wslpath -a "'$winPath'").Text.Trim()
        if (-not $src.StartsWith('/')) { Stop-Mf 'could not locate the Mayfly sources from WSL (is the folder on a local drive?)' }
        Write-Host 'Building the base distro (downloads packages; this takes several minutes)...'
        & wsl.exe -d $script:MfBuildDistro -u root -- bash "'$src/wsl/provision.sh'" "'$src'"
        if ($LASTEXITCODE -ne 0) { Stop-Mf 'the provisioning step failed' }
        Invoke-Wsl --terminate $script:MfBuildDistro | Out-Null
        $rootfs = Join-Path (Get-MfPath 'rootfs') 'mayfly-rootfs.tar.gz'
        if (Test-Path -LiteralPath $rootfs) { Remove-Item -LiteralPath $rootfs -Force }
        if ((Invoke-Wsl --export $script:MfBuildDistro $rootfs --format tar.gz).Code -ne 0) { Stop-Mf 'could not export the base rootfs' }
        $hash = (Get-FileHash -LiteralPath $rootfs -Algorithm SHA256).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText("$rootfs.sha256", "$hash  mayfly-rootfs.tar.gz`n")
    } finally {
        Invoke-Wsl --unregister $script:MfBuildDistro | Out-Null
        if (Test-Path -LiteralPath $buildDir) { Remove-Item -LiteralPath $buildDir -Recurse -Force }
    }
    if ((Get-FileHash -LiteralPath $rootfs -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash) { Stop-Mf 'the built rootfs changed after checksumming' }
    Write-Host "Rootfs checksum: $hash"
    if (Test-MfDistroExists $script:MfDistro) {
        Invoke-MfCleanup
        Invoke-Wsl --unregister $script:MfDistro | Out-Null
    }
    $distroDir = Join-Path (Get-MfPath 'distro') $script:MfDistro
    if (Test-Path -LiteralPath $distroDir) { Remove-Item -LiteralPath $distroDir -Recurse -Force }
    if ((Invoke-Wsl --import $script:MfDistro $distroDir $rootfs --version 2).Code -ne 0) { Stop-Mf 'could not import the base distro' }
    Invoke-Wsl --terminate $script:MfDistro | Out-Null
    Write-Host 'Setup finished. Next: put your WireGuard file in the secrets folder, then run preflight and launch.'
    Write-Host "  Profile location: $(Get-MfPath 'secrets\wireguard.conf')"
}

# Unregister the base distro and delete downloads and builds. The secrets folder is kept.
function Invoke-MfUninstall {
    if (-not $Yes) {
        if ((Read-Host "This unregisters the WSL distro '$($script:MfDistro)' and deletes its files. Type 'uninstall' to continue") -ne 'uninstall') {
            Stop-Mf 'not confirmed; nothing was changed'
        }
    }
    if (Test-MfDistroExists $script:MfDistro) {
        Invoke-MfCleanup
        Invoke-Wsl --unregister $script:MfDistro | Out-Null
    }
    if (Test-MfDistroExists $script:MfBuildDistro) { Invoke-Wsl --unregister $script:MfBuildDistro | Out-Null }
    foreach ($dir in @('distro', 'rootfs', 'build', 'downloads', 'pins')) {
        $path = Get-MfPath $dir
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
    Write-Host "Uninstalled. Your profile folder was left in place: $(Get-MfPath 'secrets')"
}

# Print the command summary.
function Show-MfUsage {
    Write-Host 'Usage: .\mayfly.ps1 preflight | setup [-Yes] [-Rebuild] | check-profile [-Profile PATH]'
    Write-Host '       .\mayfly.ps1 launch [-Entry firefox|i2p|tor] [-Profile PATH] | cleanup | uninstall [-Yes]'
    Write-Host 'First run: preflight, setup, copy your WireGuard file to the secrets folder, launch.'
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        switch ($Command) {
            'preflight' { if (-not (Invoke-MfPreflight)) { exit 78 } }
            'setup' { Invoke-MfSetup }
            'check-profile' { Invoke-MfCheckProfile }
            'launch' { Invoke-MfLaunch }
            'cleanup' { Invoke-MfCleanup; Write-Host 'Session mounts removed and the base distro stopped.' }
            'uninstall' { Invoke-MfUninstall }
            default { Show-MfUsage; if ($Command -ne 'help') { exit 64 } }
        }
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }
}
