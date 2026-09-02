$ErrorActionPreference = "Stop"
$manifestUrl = "https://andresonanjorei-dotcom.github.io/trecho-releases/manifest.json"

function Say([string]$text, [string]$color = "White") { Write-Host $text -ForegroundColor $color }
function Step([string]$text) { Write-Host ""; Say "== $text ==" "Cyan" }
function Is-TrechoFolder([string]$path) {
    return (Test-Path (Join-Path $path "VERSION")) -and
        (Test-Path (Join-Path $path "copiloto")) -and
        (Test-Path (Join-Path $path "Abrir_Trecho.ps1"))
}
function VersionOf([string]$path) {
    try { return [version](((Get-Content (Join-Path $path "VERSION") -Raw).Trim() -split "-")[0]) } catch { return $null }
}
function Find-ExistingTrecho {
    $preferred = Join-Path $env:LOCALAPPDATA "Trecho"
    if (Is-TrechoFolder $preferred) { return $preferred }

    $desktop = [Environment]::GetFolderPath("DesktopDirectory")
    $shortcut = Join-Path $desktop "Trecho.lnk"
    if (Test-Path $shortcut) {
        try {
            $target = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut).TargetPath
            $candidate = Split-Path -Parent $target
            if (Is-TrechoFolder $candidate) { return $candidate }
        } catch {}
    }

    $bases = @($desktop, (Join-Path $env:USERPROFILE "Downloads"), (Join-Path $env:USERPROFILE "Documents"), $env:USERPROFILE) | Where-Object { Test-Path $_ }
    foreach ($base in $bases) {
        try {
            $found = Get-ChildItem -LiteralPath $base -Directory -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch "Trecho_Teste|dist\\stage|\\.git" -and (Is-TrechoFolder $_.FullName) } |
                Select-Object -First 1
            if ($found) { return $found.FullName }
        } catch {}
    }
    return $preferred
}
function Copy-Payload([string]$source, [string]$target) {
    if (-not (Test-Path $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }

    foreach ($folder in @("copiloto", "tools")) {
        $codeDir = Join-Path $target $folder
        if (Test-Path $codeDir) {
            Get-ChildItem -Path $codeDir -Filter "*.py" -Recurse -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            Get-ChildItem -Path $codeDir -Filter "__pycache__" -Recurse -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $backup = Join-Path $env:TEMP ("trecho-preserve-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    $preserve = @(".env", "app_preferences.json", "achievements.json", "daily_diary.json", "driver_memory.json", "trip_diary.json", "passport.json", "social_session.json", "gps_link_atual.txt", "gps_pairing_atual.json", "qr_pareamento.png")
    foreach ($name in $preserve) {
        $p = Join-Path $target $name
        if (Test-Path $p) { Copy-Item -LiteralPath $p -Destination (Join-Path $backup $name) -Force }
    }
    $cfg = Join-Path $target "copiloto\config.yaml"
    if (Test-Path $cfg) {
        New-Item -ItemType Directory -Path (Join-Path $backup "copiloto") -Force | Out-Null
        Copy-Item -LiteralPath $cfg -Destination (Join-Path $backup "copiloto\config.yaml") -Force
    }

    Copy-Item -Path (Join-Path $source "*") -Destination $target -Recurse -Force

    foreach ($name in $preserve) {
        $p = Join-Path $backup $name
        if (Test-Path $p) { Copy-Item -LiteralPath $p -Destination (Join-Path $target $name) -Force }
    }
    $cfgBackup = Join-Path $backup "copiloto\config.yaml"
    if (Test-Path $cfgBackup) { Copy-Item -LiteralPath $cfgBackup -Destination $cfg -Force }
    Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
}
function Create-DesktopShortcut([string]$installDir) {
    $desktop = [Environment]::GetFolderPath("DesktopDirectory")
    $shortcutPath = Join-Path $desktop "Trecho.lnk"
    $target = Join-Path $installDir "Abrir_Trecho.bat"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $target
    $shortcut.WorkingDirectory = $installDir
    $icon = Join-Path $installDir "Trecho.ico"
    if (Test-Path $icon) { $shortcut.IconLocation = $icon }
    $shortcut.Save()
    return $shortcutPath
}

try {
    Clear-Host
    Say "========================================" "Cyan"
    Say "          INSTALAR TRECHO" "Cyan"
    Say "========================================" "Cyan"
    Say "Vou instalar ou atualizar o Trecho automaticamente."

    Step "Procurando instalacao"
    $installDir = Find-ExistingTrecho
    Say "Pasta do Trecho: $installDir" "Green"

    Step "Consultando versao"
    $manifest = Invoke-RestMethod -Uri ($manifestUrl + "?t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -TimeoutSec 20
    if (-not $manifest.url) { throw "Nao encontrei o pacote publicado do Trecho." }
    $remoteVersionText = [string]$manifest.version
    $remoteVersion = try { [version](($remoteVersionText -split "-")[0]) } catch { $null }
    $localVersion = if (Is-TrechoFolder $installDir) { VersionOf $installDir } else { $null }
    if ($localVersion -and $remoteVersion -and $localVersion -ge $remoteVersion) {
        Say "Trecho ja esta instalado na versao atual." "Green"
        $shortcut = Create-DesktopShortcut $installDir
        Say "Atalho pronto: $shortcut" "Green"
        Step "Abrindo Trecho"
        Start-Process -FilePath (Join-Path $installDir "Abrir_Trecho.bat") -WorkingDirectory $installDir
        exit 0
    }

    Step "Baixando Trecho $remoteVersionText"
    $tmpDir = Join-Path $env:TEMP ("trecho-install-" + [guid]::NewGuid())
    $zipPath = Join-Path $tmpDir "trecho.zip"
    $extractPath = Join-Path $tmpDir "extract"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    Invoke-WebRequest -Uri $manifest.url -OutFile $zipPath
    if ($manifest.sha256) {
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
        $expected = ([string]$manifest.sha256).Trim().ToLowerInvariant()
        if ($actual -ne $expected) { throw "O download nao passou na conferencia de seguranca." }
    }
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
    $payload = $extractPath
    $items = @(Get-ChildItem -LiteralPath $extractPath)
    if ($items.Count -eq 1 -and $items[0].PSIsContainer) { $payload = $items[0].FullName }
    if (Test-Path (Join-Path $payload "Arquivos do Trecho")) { $payload = Join-Path $payload "Arquivos do Trecho" }
    if (-not (Is-TrechoFolder $payload)) { throw "O pacote baixado nao parece ser uma versao valida do Trecho." }

    Step "Instalando"
    Copy-Payload $payload $installDir
    $shortcut = Create-DesktopShortcut $installDir
    Say "Atalho criado na Area de Trabalho: $shortcut" "Green"
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

    Step "Preparando e abrindo"
    Start-Process -FilePath (Join-Path $installDir "Abrir_Trecho.bat") -WorkingDirectory $installDir
    Say "Pronto. Da proxima vez, use o icone Trecho na Area de Trabalho." "Green"
    Start-Sleep -Seconds 2
} catch {
    Say ""
    Say "Nao consegui concluir a instalacao: $($_.Exception.Message)" "Red"
    Read-Host "Pressione Enter para sair"
    exit 1
}