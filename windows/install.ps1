# Install Quill for Windows. No admin, no password.
#   irm https://raw.githubusercontent.com/xfreeze2/quill/main/windows/install.ps1 | iex
$ErrorActionPreference = 'Stop'
$Repo = 'xfreeze2/quill'
$Dest = Join-Path $env:LOCALAPPDATA 'Quill'
$Tmp = Join-Path $env:TEMP ('quill-' + [guid]::NewGuid())

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
    Write-Host "→ installing to $Dest"
    if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    Expand-Archive -Path $zip -DestinationPath $Dest -Force
    $exe = Join-Path $Dest 'Quill.exe'
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
