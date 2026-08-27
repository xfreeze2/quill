# Install Quill for Windows. No admin, no password.
#   irm https://raw.githubusercontent.com/xfreeze2/quill/main/windows/install.ps1 | iex
$ErrorActionPreference = 'Stop'
$Repo = 'xfreeze2/quill'
$Dest = Join-Path $env:LOCALAPPDATA 'Quill'
$Tmp = Join-Path $env:TEMP ('quill-' + [guid]::NewGuid())

# Windows PowerShell 5.1 on some machines still defaults to TLS 1.0 and then
# cannot reach api.github.com at all.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
try {
    Write-Host '→ finding the latest Windows release…'
    $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest"
    $asset = $rel.assets | Where-Object { $_.name -eq 'Quill-windows-x64.zip' } | Select-Object -First 1
    if (-not $asset) {
        # Same version as Mac; the zip may live on the latest release once uploaded.
        throw "Could not find Quill-windows-x64.zip on $($rel.tag_name). See https://github.com/$Repo/releases"
    }
    $zip = Join-Path $Tmp 'Quill-windows-x64.zip'
    Write-Host '→ downloading…'
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip
    # Strip the mark-of-the-web so SmartScreen doesn't refuse to start the
    # extracted exe (Expand-Archive propagates the zone marker to every file).
    Unblock-File -Path $zip -ErrorAction SilentlyContinue

    Write-Host "→ installing to $Dest"
    # A running Quill holds a lock on Quill.exe; stop it before replacing.
    Get-Process -Name 'Quill' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path -like (Join-Path $Dest '*') } |
        ForEach-Object {
            Write-Host '→ stopping the running Quill…'
            $_ | Stop-Process -Force
            $_.WaitForExit(5000) | Out-Null
        }
    if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    Expand-Archive -Path $zip -DestinationPath $Dest -Force
    Get-ChildItem -Path $Dest -Recurse | Unblock-File -ErrorAction SilentlyContinue
    $exe = Join-Path $Dest 'Quill.exe'
    if (-not (Test-Path $exe)) { throw "Quill.exe missing after extraction — the release zip looks damaged." }
    $start = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'
    New-Item -ItemType Directory -Force -Path $start | Out-Null
    $w = New-Object -ComObject WScript.Shell
    $lnk = $w.CreateShortcut((Join-Path $start 'Quill.lnk'))
    $lnk.TargetPath = $exe
    $lnk.WorkingDirectory = $Dest
    $lnk.Description = 'Quill'
    $lnk.Save()
    Write-Host '✓ installed. Opening — the setup window will show what to allow.'
    Start-Process $exe
}
finally {
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}
