# Smoke tests for mayfly.ps1. Pester 3 and later. No WSL, network or real profile needed.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\..\mayfly.ps1')

Describe 'swap detection' {
    It 'accepts zero in every unit spelling' {
        foreach ($v in '0', '0GB', '0 MB', '00') { (Test-MfSwapZero $v) | Should Be $true }
    }
    It 'rejects unset and non-zero values' {
        foreach ($v in $null, '', '8GB', '1', '0.5GB') { (Test-MfSwapZero $v) | Should Be $false }
    }
    It 'reads swap only from the wsl2 section' {
        $f = Join-Path $env:TEMP ('mf-wslconfig-' + [guid]::NewGuid().ToString('N'))
        Set-Content $f "[experimental]`nswap=0`n[wsl2]`nmemory=4GB`nswap=0`n"
        $env:MAYFLY_WSLCONFIG = $f
        (Get-WslConfigSwap) | Should Be '0'
        Set-Content $f "[experimental]`nswap=0`n[wsl2]`nmemory=4GB`n"
        (Get-WslConfigSwap) | Should Be $null
        Remove-Item Env:\MAYFLY_WSLCONFIG; Remove-Item $f
    }
}

Describe 'owner-only ACL' {
    It 'passes after Set-MfOwnerOnlyAcl and fails once another account is granted access' {
        $d = Join-Path $env:TEMP ('mf-acl-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $d | Out-Null
        Set-MfOwnerOnlyAcl $d
        (Test-MfOwnerOnlyAcl $d) | Should Be $true
        & icacls.exe $d /grant '*S-1-1-0:(R)' | Out-Null
        (Test-MfOwnerOnlyAcl $d) | Should Be $false
        Remove-Item $d -Recurse -Force
    }
}

Describe 'profile reading' {
    $dir = Join-Path $env:TEMP ('mf-prof-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $dir | Out-Null
    $file = Join-Path $dir 'wg.conf'
    It 'refuses a profile whose folder is not owner-only' {
        Set-Content $file 'x' -NoNewline
        { Read-MfProfileBytes $file } | Should Throw 'readable by your account only'
    }
    It 'refuses an empty and an oversized profile' {
        Set-MfOwnerOnlyAcl $dir
        Set-Content $file '' -NoNewline
        { Read-MfProfileBytes $file } | Should Throw '1..16384'
        [IO.File]::WriteAllBytes($file, (New-Object byte[] 16385))
        { Read-MfProfileBytes $file } | Should Throw '1..16384'
    }
    It 'returns the raw bytes of a file copied into the owner-only folder (inherited ACL)' {
        [IO.File]::WriteAllBytes($file, [byte[]](65, 10, 66))
        $b = Read-MfProfileBytes $file
        ($b -join ',') | Should Be '65,10,66'
    }
    It 'refuses a file that grants another account access' {
        & icacls.exe $file /grant '*S-1-1-0:(R)' | Out-Null
        { Read-MfProfileBytes $file } | Should Throw 'readable by your account only'
        & icacls.exe $file /remove '*S-1-1-0' | Out-Null
    }
    It 'never mentions file content in an error' {
        Set-Content $file 'PrivateKey = SECRETSECRET' -NoNewline
        $msg = ''
        try { Read-MfProfileBytes (Join-Path $dir 'missing.conf') } catch { $msg = $_.Exception.Message }
        $msg | Should Not Match 'SECRET'
    }
    Remove-Item $dir -Recurse -Force
}

Describe 'pins file' {
    $good = 'ROOTFS_URL=https://raw.githubusercontent.com/debuerreotype/docker-debian-artifacts/dist-amd64/trixie/oci/blobs/rootfs.tar.gz' + "`n" +
        'ROOTFS_SHA256=' + ('a' * 64) + "`n"
    $f = Join-Path $env:TEMP ('mf-pins-' + [guid]::NewGuid().ToString('N'))
    It 'accepts the literal key=value form' {
        Set-Content $f $good -NoNewline
        (Get-MfPins $f)['ROOTFS_SHA256'] | Should Be ('a' * 64)
    }
    It 'rejects another host, a short digest and extra lines' {
        Set-Content $f ($good -replace 'raw.githubusercontent.com', 'example.com') -NoNewline
        { Get-MfPins $f } | Should Throw 'failed validation'
        Set-Content $f ($good -replace ('a' * 64), 'abc') -NoNewline
        { Get-MfPins $f } | Should Throw 'failed validation'
        Set-Content $f ($good + "EXTRA=1`n") -NoNewline
        { Get-MfPins $f } | Should Throw 'unexpected line'
    }
    Remove-Item $f -ErrorAction SilentlyContinue
}

Describe 'preflight' {
    Mock Write-Host {}
    It 'fails on an old Windows build and names Windows 11' {
        Mock Get-MfWindowsBuild { 19045 }
        Mock Invoke-Wsl { [pscustomobject]@{ Code = 0; Text = "WSL version: 2.7.8.0`nWSLg version: 1.0.73.2" } }
        Mock Get-WslConfigSwap { '0' }
        Mock Test-MfDistroExists { $false }
        (Invoke-MfPreflight) | Should Be $false
        Assert-MockCalled Write-Host -ParameterFilter { $Object -like '*Windows 11 is required*' }
    }
    It 'fails and prints the .wslconfig fix when swap is not zero' {
        Mock Get-MfWindowsBuild { 26100 }
        Mock Invoke-Wsl { [pscustomobject]@{ Code = 0; Text = "WSL version: 2.7.8.0`nWSLg version: 1.0.73.2" } }
        Mock Get-WslConfigSwap { $null }
        Mock Test-MfDistroExists { $false }
        (Invoke-MfPreflight) | Should Be $false
        Assert-MockCalled Write-Host -ParameterFilter { $Object -like '*swap=0*' }
    }
    It 'passes when Windows, WSL, swap and the distro checks all pass' {
        Mock Get-MfWindowsBuild { 26100 }
        Mock Invoke-Wsl { [pscustomobject]@{ Code = 0; Text = "WSL version: 2.7.8.0`nWSLg version: 1.0.73.2`nok: fine" } }
        Mock Get-WslConfigSwap { '0' }
        Mock Test-MfDistroExists { $true }
        (Invoke-MfPreflight) | Should Be $true
    }
    It 'fails when the in-distro preflight fails' {
        Mock Get-MfWindowsBuild { 26100 }
        Mock Invoke-Wsl {
            if ($args -contains 'preflight') { [pscustomobject]@{ Code = 1; Text = 'MISSING: swap' } }
            else { [pscustomobject]@{ Code = 0; Text = "WSL version: 2.7.8.0`nWSLg version: 1.0.73.2" } }
        }
        Mock Get-WslConfigSwap { '0' }
        Mock Test-MfDistroExists { $true }
        (Invoke-MfPreflight) | Should Be $false
    }
}

Describe 'launch and uninstall guards' {
    It 'launch refuses when the base distro is missing' {
        Mock Test-MfDistroExists { $false }
        { Invoke-MfLaunch } | Should Throw 'not installed'
    }
    It 'uninstall asks for confirmation and changes nothing on the wrong answer' {
        Mock Read-Host { 'no' }
        Mock Invoke-Wsl {}
        { Invoke-MfUninstall } | Should Throw 'not confirmed'
        Assert-MockCalled Invoke-Wsl -Times 0
    }
}
