#Requires -Version 7.0

#region Constants
$script:PROFILES_BASE = Join-Path $HOME ".claude-profiles"
$script:PROFILES_DIR  = Join-Path $script:PROFILES_BASE "profiles"
$script:BIN_DIR       = Join-Path $script:PROFILES_BASE "bin"
$script:REGISTRY_FILE = Join-Path $script:PROFILES_BASE "profiles.json"
$script:ACTIVE_FILE   = Join-Path $script:PROFILES_BASE "active"
$script:CLAUDE_DIR    = Join-Path $HOME ".claude"
$script:BACKUP_DIR    = Join-Path $script:CLAUDE_DIR ".ccprofile-backup"
$script:MANAGED_FILES = @(".credentials.json", "settings.json")
#endregion

#region Output Helpers
function Write-Err([string]$msg) {
    [System.Console]::Error.WriteLine("ERRORE: $msg")
}

function Write-Warn([string]$msg) {
    Write-Host "AVVISO: $msg" -ForegroundColor Yellow
}

function Write-Ok([string]$msg) {
    Write-Host "OK: $msg" -ForegroundColor Green
}
#endregion

#region Validation
function Assert-ProfileName([string]$name) {
    if ($name -notmatch '^[a-zA-Z0-9_-]{1,32}$') {
        throw "Nome profilo non valido: '$name'. Usa solo lettere, numeri, - e _ (max 32 caratteri)"
    }
}

function Test-ApiKeyFormat([string]$key) {
    return $key -match '^sk-ant-[a-zA-Z0-9\-_]{20,}$'
}
#endregion

#region Registry & State
function Initialize-Dirs {
    foreach ($dir in @($script:PROFILES_BASE, $script:PROFILES_DIR, $script:BIN_DIR, $script:CLAUDE_DIR)) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
    if (-not (Test-Path $script:REGISTRY_FILE)) {
        Set-Content $script:REGISTRY_FILE -Value '{}' -Encoding UTF8
    }
    if (-not (Test-Path $script:ACTIVE_FILE)) {
        Set-Content $script:ACTIVE_FILE -Value '' -Encoding UTF8
    }
}

function Read-Registry {
    $content = Get-Content $script:REGISTRY_FILE -Encoding UTF8 -Raw
    return $content | ConvertFrom-Json
}

function Write-Registry([PSCustomObject]$reg) {
    $reg | ConvertTo-Json -Depth 10 | Set-Content $script:REGISTRY_FILE -Encoding UTF8
}

function Read-ActiveProfile {
    if (-not (Test-Path $script:ACTIVE_FILE)) { return '' }
    return ((Get-Content $script:ACTIVE_FILE -Encoding UTF8 -Raw)?.Trim() ?? '')
}

function Write-ActiveProfile([string]$name) {
    Set-Content $script:ACTIVE_FILE -Value $name -Encoding UTF8
}

function Get-ProfileDir([string]$name) {
    return Join-Path $script:PROFILES_DIR $name
}
#endregion

#region File Swap
function Save-CurrentFiles([string]$name) {
    $profileDir = Get-ProfileDir $name
    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }
    foreach ($file in $script:MANAGED_FILES) {
        $src = Join-Path $script:CLAUDE_DIR $file
        if (Test-Path $src) {
            Copy-Item $src $profileDir -Force
        }
    }
}

function Apply-ProfileFiles([string]$name) {
    $profileDir = Get-ProfileDir $name
    foreach ($file in $script:MANAGED_FILES) {
        $src = Join-Path $profileDir $file
        $dst = Join-Path $script:CLAUDE_DIR $file
        if (Test-Path $src) {
            Copy-Item $src $dst -Force
        } elseif (Test-Path $dst) {
            Remove-Item $dst -Force
        }
    }
}

function Apply-ProfileFiles-Safe([string]$name) {
    if (Test-Path $script:BACKUP_DIR) {
        Remove-Item $script:BACKUP_DIR -Recurse -Force
    }
    New-Item -ItemType Directory -Path $script:BACKUP_DIR -Force | Out-Null

    foreach ($file in $script:MANAGED_FILES) {
        $src = Join-Path $script:CLAUDE_DIR $file
        if (Test-Path $src) {
            Copy-Item $src $script:BACKUP_DIR -Force
        }
    }

    try {
        Apply-ProfileFiles $name
        Remove-Item $script:BACKUP_DIR -Recurse -Force
    } catch {
        Write-Warn "Errore durante lo swap. Ripristino backup..."
        foreach ($file in $script:MANAGED_FILES) {
            $bak = Join-Path $script:BACKUP_DIR $file
            $dst = Join-Path $script:CLAUDE_DIR $file
            if (Test-Path $bak) {
                Copy-Item $bak $dst -Force
            }
        }
        Remove-Item $script:BACKUP_DIR -Recurse -Force
        throw
    }
}

function Set-EnvApiKey([string]$key) {
    $env:ANTHROPIC_API_KEY = $key
    [System.Environment]::SetEnvironmentVariable("ANTHROPIC_API_KEY", $key, "User")
}

function Clear-EnvApiKey {
    $env:ANTHROPIC_API_KEY = $null
    [System.Environment]::SetEnvironmentVariable("ANTHROPIC_API_KEY", $null, "User")
}

function Set-EnvBaseUrl([string]$url) {
    $env:ANTHROPIC_BASE_URL = $url
    [System.Environment]::SetEnvironmentVariable("ANTHROPIC_BASE_URL", $url, "User")
}

function Clear-EnvBaseUrl {
    $env:ANTHROPIC_BASE_URL = $null
    [System.Environment]::SetEnvironmentVariable("ANTHROPIC_BASE_URL", $null, "User")
}
#endregion

#region Argument Parsing
function Parse-Args([string[]]$cmdArgs) {
    $result = @{
        _positional = [System.Collections.Generic.List[string]]::new()
    }
    $i = 0
    while ($i -lt $cmdArgs.Count) {
        $a = $cmdArgs[$i]
        if ($a -match '^--(.+)$') {
            $key = $matches[1]
            if (($i + 1) -lt $cmdArgs.Count -and $cmdArgs[$i + 1] -notmatch '^--') {
                $result[$key] = $cmdArgs[$i + 1]
                $i += 2
            } else {
                $result[$key] = $true
                $i++
            }
        } else {
            $result['_positional'].Add($a)
            $i++
        }
    }
    return $result
}
#endregion

#region Commands
function Command-List([string[]]$cmdArgs) {
    $reg = Read-Registry
    $active = Read-ActiveProfile
    $profiles = @($reg.PSObject.Properties)

    if ($profiles.Count -eq 0) {
        Write-Host "Nessun profilo configurato. Usa 'ccprofile add' per aggiungerne uno."
        return
    }

    foreach ($p in $profiles) {
        $marker    = $p.Name -eq $active ? '*' : ' '
        $type      = $p.Value.type
        $urlSuffix = $p.Value.base_url ? " [url: $($p.Value.base_url)]" : ''
        Write-Host "$marker $($p.Name) [$type]$urlSuffix"
    }
}

function Command-Use([string[]]$cmdArgs) {
    $parsed = Parse-Args $cmdArgs
    $name = $parsed['_positional'][0]

    if ([string]::IsNullOrWhiteSpace($name)) {
        Write-Err "Nome profilo mancante. Uso: ccprofile use <nome>"
        return
    }

    Assert-ProfileName $name

    $reg = Read-Registry
    if ($null -eq $reg.PSObject.Properties[$name]) {
        Write-Err "Profilo '$name' non trovato."
        return
    }

    $active = Read-ActiveProfile
    if ($active -eq $name) {
        Write-Host "Profilo '$name' gia' attivo."
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($active)) {
        Save-CurrentFiles $active
    }

    Apply-ProfileFiles-Safe $name
    Write-ActiveProfile $name

    $profile = $reg.PSObject.Properties[$name].Value

    if ($profile.type -eq 'apikey') {
        Set-EnvApiKey $profile.api_key
    } else {
        Clear-EnvApiKey
    }

    if ($profile.base_url) {
        Set-EnvBaseUrl $profile.base_url
    } else {
        Clear-EnvBaseUrl
    }

    Write-Ok "Profilo '$name' attivato."
}

function Command-Add([string[]]$cmdArgs) {
    $parsed = Parse-Args $cmdArgs
    $name    = $parsed['_positional'][0]
    $type    = $parsed['type']
    $key     = $parsed['key']
    $baseUrl = $parsed['base-url']

    if ([string]::IsNullOrWhiteSpace($name)) {
        Write-Err "Nome profilo mancante. Uso: ccprofile add <nome> --type pro|apikey [--key sk-ant-...] [--base-url <url>]"
        return
    }
    if ([string]::IsNullOrWhiteSpace($type)) {
        Write-Err "Tipo profilo mancante. Usa --type pro o --type apikey"
        return
    }
    if ($type -notin @('pro', 'apikey')) {
        Write-Err "Tipo non valido: '$type'. Usa 'pro' o 'apikey'."
        return
    }
    if ($type -eq 'apikey' -and [string]::IsNullOrWhiteSpace($key)) {
        Write-Err "API key mancante per profilo apikey. Usa --key sk-ant-..."
        return
    }

    Assert-ProfileName $name

    $reg = Read-Registry
    if ($null -ne $reg.PSObject.Properties[$name]) {
        Write-Err "Profilo '$name' esiste gia'."
        return
    }

    if ($type -eq 'apikey' -and -not [string]::IsNullOrWhiteSpace($key)) {
        if (-not (Test-ApiKeyFormat $key)) {
            Write-Warn "La API key non corrisponde al formato atteso (sk-ant-...). Procedo comunque."
        }
    }

    if ($baseUrl -and $type -eq 'pro') {
        Write-Warn "base_url impostato su profilo pro. Le credenziali OAuth sono Anthropic-specifiche."
    }

    $profileDir = Get-ProfileDir $name
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null

    $settingsPath = Join-Path $profileDir "settings.json"
    if (-not (Test-Path $settingsPath)) {
        Set-Content $settingsPath -Value '{}' -Encoding UTF8
    }

    if ($type -eq 'pro') {
        $srcCreds = Join-Path $script:CLAUDE_DIR ".credentials.json"
        if (Test-Path $srcCreds) {
            Copy-Item $srcCreds $profileDir -Force
        } else {
            Write-Warn ".credentials.json non trovato in ~/.claude/. Aggiungilo manualmente in: $profileDir"
        }
    }

    $entry = [PSCustomObject]@{
        type    = $type
        created = (Get-Date).ToString("o")
    }

    if ($type -eq 'apikey') {
        $entry | Add-Member -NotePropertyName 'api_key' -NotePropertyValue $key
    }

    if (-not [string]::IsNullOrWhiteSpace($baseUrl)) {
        $entry | Add-Member -NotePropertyName 'base_url' -NotePropertyValue $baseUrl
    }

    $reg | Add-Member -NotePropertyName $name -NotePropertyValue $entry
    Write-Registry $reg

    Write-Ok "Profilo '$name' ($type) creato."
}

function Command-Delete([string[]]$cmdArgs) {
    $parsed = Parse-Args $cmdArgs
    $name = $parsed['_positional'][0]

    if ([string]::IsNullOrWhiteSpace($name)) {
        Write-Err "Nome profilo mancante. Uso: ccprofile delete <nome>"
        return
    }

    Assert-ProfileName $name

    $reg = Read-Registry
    if ($null -eq $reg.PSObject.Properties[$name]) {
        Write-Err "Profilo '$name' non trovato."
        return
    }

    $active = Read-ActiveProfile
    if ($active -eq $name) {
        Write-Err "Impossibile eliminare il profilo attivo. Passa a un altro profilo prima."
        return
    }

    $profileDir = Get-ProfileDir $name
    if (Test-Path $profileDir) {
        Remove-Item $profileDir -Recurse -Force
    }

    $reg.PSObject.Properties.Remove($name)
    Write-Registry $reg

    Write-Ok "Profilo '$name' eliminato."
}

function Command-Current([string[]]$cmdArgs) {
    $active = Read-ActiveProfile
    if ([string]::IsNullOrWhiteSpace($active)) {
        Write-Host "Nessun profilo attivo."
    } else {
        Write-Host $active
    }
}

function Command-Status([string[]]$cmdArgs) {
    $active = Read-ActiveProfile

    if ([string]::IsNullOrWhiteSpace($active)) {
        Write-Host "Profilo attivo: (nessuno)"
        return
    }

    $reg = Read-Registry
    if ($null -eq $reg.PSObject.Properties[$active]) {
        Write-Host "Profilo attivo: $active (non trovato nel registro)"
        return
    }

    $profile = $reg.PSObject.Properties[$active].Value
    $profileDir = Get-ProfileDir $active

    Write-Host "Profilo attivo: $active"
    Write-Host "  Tipo:       $($profile.type)"
    Write-Host "  Directory:  $profileDir"

    if ($profile.type -eq 'apikey') {
        $keyStatus = if ([string]::IsNullOrEmpty($env:ANTHROPIC_API_KEY)) { '(non impostata)' } else { 'impostata' }
        Write-Host "  API Key:    $keyStatus"
    }

    if ($profile.base_url) {
        $urlStatus = if ([string]::IsNullOrEmpty($env:ANTHROPIC_BASE_URL)) { '(non impostata)' } else { 'impostata' }
        Write-Host "  Base URL:   $($profile.base_url)"
        Write-Host "  ANTHROPIC_BASE_URL: $urlStatus"
    }

    if ($profile.created) {
        Write-Host "  Creato:     $($profile.created)"
    }
}

function Command-Rename([string[]]$cmdArgs) {
    $parsed = Parse-Args $cmdArgs
    $oldName = $parsed['_positional'][0]
    $newName = $parsed['_positional'][1]

    if ([string]::IsNullOrWhiteSpace($oldName) -or [string]::IsNullOrWhiteSpace($newName)) {
        Write-Err "Uso: ccprofile rename <vecchio-nome> <nuovo-nome>"
        return
    }

    Assert-ProfileName $oldName
    Assert-ProfileName $newName

    $reg = Read-Registry
    if ($null -eq $reg.PSObject.Properties[$oldName]) {
        Write-Err "Profilo '$oldName' non trovato."
        return
    }
    if ($null -ne $reg.PSObject.Properties[$newName]) {
        Write-Err "Profilo '$newName' esiste gia'."
        return
    }

    $oldDir = Get-ProfileDir $oldName
    $newDir = Get-ProfileDir $newName
    Rename-Item $oldDir $newDir

    $oldEntry = $reg.PSObject.Properties[$oldName].Value
    $newEntry = $oldEntry | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $reg | Add-Member -NotePropertyName $newName -NotePropertyValue $newEntry
    $reg.PSObject.Properties.Remove($oldName)
    Write-Registry $reg

    $active = Read-ActiveProfile
    if ($active -eq $oldName) {
        Write-ActiveProfile $newName
    }

    Write-Ok "Profilo '$oldName' rinominato in '$newName'."
}

function Command-Edit([string[]]$cmdArgs) {
    $parsed = Parse-Args $cmdArgs
    $name = $parsed['_positional'][0]

    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = Read-ActiveProfile
        if ([string]::IsNullOrWhiteSpace($name)) {
            Write-Err "Nessun profilo attivo e nessun nome specificato."
            return
        }
    }

    Assert-ProfileName $name

    $reg = Read-Registry
    if ($null -eq $reg.PSObject.Properties[$name]) {
        Write-Err "Profilo '$name' non trovato."
        return
    }

    $settingsPath = Join-Path (Get-ProfileDir $name) "settings.json"
    if (-not (Test-Path $settingsPath)) {
        Set-Content $settingsPath -Value '{}' -Encoding UTF8
    }

    $active = Read-ActiveProfile
    if ($active -eq $name) {
        Write-Warn "Stai modificando il profilo attivo. Esegui 'ccprofile use $name' per applicare le modifiche a Claude Code."
    }

    Write-Host "Apertura: $settingsPath"
    Start-Process $settingsPath
}

function Add-ZipEntry([System.IO.Compression.ZipArchive]$zip, [string]$filePath, [string]$entryName) {
    $entry = $zip.CreateEntry($entryName)
    $entryStream = $entry.Open()
    try {
        $fileStream = [System.IO.File]::OpenRead($filePath)
        try {
            $fileStream.CopyTo($entryStream)
        } finally {
            $fileStream.Dispose()
        }
    } finally {
        $entryStream.Dispose()
    }
}

function Command-Export([string[]]$cmdArgs) {
    $parsed = Parse-Args $cmdArgs
    $name    = $parsed['_positional'][0]
    $outPath = $parsed['out']

    if ([string]::IsNullOrWhiteSpace($name)) {
        Write-Err "Nome profilo mancante. Uso: ccprofile export <nome> [--out percorso.zip]"
        return
    }

    Assert-ProfileName $name

    $reg = Read-Registry
    if ($null -eq $reg.PSObject.Properties[$name]) {
        Write-Err "Profilo '$name' non trovato."
        return
    }

    if ([string]::IsNullOrWhiteSpace($outPath)) {
        $date = (Get-Date).ToString("yyyyMMdd")
        $outPath = Join-Path (Get-Location) "ccprofile-$name-$date.zip"
    }

    if (Test-Path $outPath) {
        Remove-Item $outPath -Force
    }

    $profileDir = Get-ProfileDir $name

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $zip = [System.IO.Compression.ZipFile]::Open($outPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $settingsPath = Join-Path $profileDir "settings.json"
        if (Test-Path $settingsPath) {
            Add-ZipEntry $zip $settingsPath "settings.json"
        }

        $origEntry = $reg.PSObject.Properties[$name].Value | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        if ($null -ne $origEntry.PSObject.Properties['api_key']) {
            $origEntry.api_key = "REDACTED"
        }
        $meta = [PSCustomObject]@{
            name    = $name
            profile = $origEntry
        }
        $metaJson = $meta | ConvertTo-Json -Depth 10

        $metaEntry = $zip.CreateEntry("ccprofile-meta.json")
        $writer = [System.IO.StreamWriter]::new($metaEntry.Open(), [System.Text.Encoding]::UTF8)
        try {
            $writer.Write($metaJson)
        } finally {
            $writer.Dispose()
        }
    } finally {
        $zip.Dispose()
    }

    Write-Ok "Profilo '$name' esportato in: $outPath"
}

function Command-Import([string[]]$cmdArgs) {
    $parsed = Parse-Args $cmdArgs
    $zipPath = $parsed['_positional'][0]
    $newName = $parsed['name']

    if ([string]::IsNullOrWhiteSpace($zipPath)) {
        Write-Err "Percorso zip mancante. Uso: ccprofile import <percorso.zip> [--name nuovo-nome]"
        return
    }

    if (-not (Test-Path $zipPath)) {
        Write-Err "File non trovato: '$zipPath'"
        return
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $tempDir = Join-Path $env:TEMP "ccprofile-import-$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $tempDir)

        $metaPath = Join-Path $tempDir "ccprofile-meta.json"
        if (-not (Test-Path $metaPath)) {
            Write-Err "Il file zip non contiene ccprofile-meta.json. Non e' un export ccprofile valido."
            return
        }

        $settingsPath = Join-Path $tempDir "settings.json"
        if (-not (Test-Path $settingsPath)) {
            Write-Err "Il file zip non contiene settings.json."
            return
        }

        $meta = Get-Content $metaPath -Encoding UTF8 -Raw | ConvertFrom-Json
        $finalName = if (-not [string]::IsNullOrWhiteSpace($newName)) { $newName } else { $meta.name }

        Assert-ProfileName $finalName

        $reg = Read-Registry
        if ($null -ne $reg.PSObject.Properties[$finalName]) {
            $confirm = Read-Host "Profilo '$finalName' esiste gia'. Sovrascrivere? (s/n)"
            if ($confirm -notmatch '^[sS]') {
                Write-Host "Import annullato."
                return
            }
            $oldDir = Get-ProfileDir $finalName
            if (Test-Path $oldDir) {
                Remove-Item $oldDir -Recurse -Force
            }
            $reg.PSObject.Properties.Remove($finalName)
        }

        $profileDir = Get-ProfileDir $finalName
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        Copy-Item $settingsPath $profileDir -Force

        $entry = $meta.profile
        $reg | Add-Member -NotePropertyName $finalName -NotePropertyValue $entry
        Write-Registry $reg

        if ($entry.api_key -eq 'REDACTED') {
            Write-Warn "La API key e' REDACTED. Aggiornala con: ccprofile set-key $finalName --key <nuova-key>"
        }

        Write-Ok "Profilo '$finalName' importato."
    } finally {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Command-SetKey([string[]]$cmdArgs) {
    $parsed = Parse-Args $cmdArgs
    $name = $parsed['_positional'][0]
    $key  = $parsed['key']

    if ([string]::IsNullOrWhiteSpace($name)) {
        Write-Err "Nome profilo mancante. Uso: ccprofile set-key <nome> --key sk-ant-..."
        return
    }
    if ([string]::IsNullOrWhiteSpace($key)) {
        Write-Err "API key mancante. Usa --key sk-ant-..."
        return
    }

    Assert-ProfileName $name

    $reg = Read-Registry
    if ($null -eq $reg.PSObject.Properties[$name]) {
        Write-Err "Profilo '$name' non trovato."
        return
    }

    $profile = $reg.PSObject.Properties[$name].Value
    if ($profile.type -ne 'apikey') {
        Write-Err "Il profilo '$name' non e' di tipo apikey."
        return
    }

    if (-not (Test-ApiKeyFormat $key)) {
        Write-Warn "La API key non corrisponde al formato atteso (sk-ant-...). Procedo comunque."
    }

    if ($null -ne $profile.PSObject.Properties['api_key']) {
        $profile.api_key = $key
    } else {
        $profile | Add-Member -NotePropertyName 'api_key' -NotePropertyValue $key
    }
    Write-Registry $reg

    $active = Read-ActiveProfile
    if ($active -eq $name) {
        Set-EnvApiKey $key
        Write-Ok "API key aggiornata e applicata alla sessione corrente."
    } else {
        Write-Ok "API key aggiornata per il profilo '$name'."
    }
}

function Command-SetUrl([string[]]$cmdArgs) {
    $parsed = Parse-Args $cmdArgs
    $name  = $parsed['_positional'][0]
    $url   = $parsed['url']
    $clear = $parsed['clear']

    if ([string]::IsNullOrWhiteSpace($name)) {
        Write-Err "Nome profilo mancante. Uso: ccprofile set-url <nome> --url <url> | --clear"
        return
    }
    if ([string]::IsNullOrWhiteSpace($url) -and -not $clear) {
        Write-Err "Specifica --url <url> oppure --clear."
        return
    }

    Assert-ProfileName $name

    $reg = Read-Registry
    if ($null -eq $reg.PSObject.Properties[$name]) {
        Write-Err "Profilo '$name' non trovato."
        return
    }

    $profile = $reg.PSObject.Properties[$name].Value
    $active  = Read-ActiveProfile

    if ($clear) {
        $profile.PSObject.Properties.Remove('base_url')
        Write-Registry $reg
        if ($active -eq $name) { Clear-EnvBaseUrl }
        Write-Ok "base_url rimossa dal profilo '$name'."
    } else {
        if ($null -ne $profile.PSObject.Properties['base_url']) {
            $profile.base_url = $url
        } else {
            $profile | Add-Member -NotePropertyName 'base_url' -NotePropertyValue $url
        }
        Write-Registry $reg
        if ($profile.type -eq 'pro') {
            Write-Warn "base_url impostato su profilo pro. Le credenziali OAuth sono Anthropic-specifiche."
        }
        if ($active -eq $name) { Set-EnvBaseUrl $url }
        Write-Ok "base_url impostata per il profilo '$name': $url"
    }
}

function Command-Help([string[]]$cmdArgs) {
    Write-Host @"

ccprofile -- Gestore profili Claude Code

COMANDI:
  list                                Elenca tutti i profili
  use <nome>                          Attiva un profilo
  add <nome> --type pro|apikey        Crea un nuovo profilo
       [--key sk-ant-...]             API key (richiesta per tipo apikey)
       [--base-url <url>]             URL base personalizzato (es. Ollama)
  delete <nome>                       Elimina un profilo (non puo' essere attivo)
  current                             Mostra il nome del profilo attivo
  status                              Mostra dettagli del profilo attivo
  rename <vecchio> <nuovo>            Rinomina un profilo
  edit [<nome>]                       Apre settings.json nell'editor predefinito
  export <nome> [--out percorso.zip]  Esporta profilo in zip (senza credenziali)
  import <percorso.zip> [--name N]    Importa profilo da zip
  set-key <nome> --key sk-ant-...     Aggiorna la API key di un profilo apikey
  set-url <nome> --url <url>          Imposta URL base per un profilo
  set-url <nome> --clear              Rimuove URL base da un profilo
  help                                Mostra questo messaggio

TIPI DI PROFILO:
  pro     Usa credenziali OAuth ($HOME\.claude\.credentials.json)
  apikey  Usa la variabile d'ambiente ANTHROPIC_API_KEY

DIRECTORY:
  Profili: $script:PROFILES_BASE
  Claude:  $script:CLAUDE_DIR

"@
}
#endregion

#region Dispatcher
function Invoke-Ccprofile([string[]]$cmdArgs) {
    Initialize-Dirs

    if ($cmdArgs.Count -eq 0) {
        Command-Help @()
        return
    }

    $cmd  = $cmdArgs[0]
    $rest = if ($cmdArgs.Count -gt 1) { $cmdArgs[1..($cmdArgs.Count - 1)] } else { @() }

    try {
        switch ($cmd) {
            "list"    { Command-List $rest }
            "use"     { Command-Use $rest }
            "add"     { Command-Add $rest }
            "delete"  { Command-Delete $rest }
            "current" { Command-Current $rest }
            "status"  { Command-Status $rest }
            "rename"  { Command-Rename $rest }
            "edit"    { Command-Edit $rest }
            "export"  { Command-Export $rest }
            "import"  { Command-Import $rest }
            "set-key" { Command-SetKey $rest }
            "set-url" { Command-SetUrl $rest }
            "help"    { Command-Help $rest }
            default   {
                Write-Err "Comando sconosciuto: '$cmd'. Usa 'ccprofile help'."
                exit 1
            }
        }
    } catch {
        Write-Err "Errore interno: $_"
        exit 1
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Ccprofile @($args)
}
#endregion
