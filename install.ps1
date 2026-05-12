#Requires -Version 5.1

param([switch]$Uninstall)

$installBase  = Join-Path $HOME ".claude-profiles"
$binDir       = Join-Path $installBase "bin"
$scriptDest   = Join-Path $binDir "ccprofile.ps1"
$scriptSrc    = Join-Path $PSScriptRoot "ccprofile.ps1"
$markerBegin  = "# BEGIN ccprofile"
$markerEnd    = "# END ccprofile"

if ($Uninstall) {
    Write-Host "Disinstallazione ccprofile..."

    if (Test-Path $scriptDest) {
        Remove-Item $scriptDest -Force
        Write-Host "Script rimosso: $scriptDest"
    }

    if (Test-Path $PROFILE) {
        $content = Get-Content $PROFILE -Raw -Encoding UTF8
        if ($null -ne $content -and $content -match [regex]::Escape($markerBegin)) {
            $pattern    = "(?s)\r?\n?$([regex]::Escape($markerBegin)).*?$([regex]::Escape($markerEnd))\r?\n?"
            $newContent = $content -replace $pattern, ''
            Set-Content $PROFILE -Value $newContent -Encoding UTF8
            Write-Host "Alias rimosso da: $PROFILE"
        }
    }

    Write-Host ""
    Write-Host "OK: Disinstallazione completata."
    exit 0
}

# Verifica script sorgente
if (-not (Test-Path $scriptSrc)) {
    Write-Error "ERRORE: ccprofile.ps1 non trovato in $PSScriptRoot"
    exit 1
}

# Crea directory
foreach ($dir in @($binDir, (Join-Path $installBase "profiles"))) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "Creata directory: $dir"
    }
}

# Copia script
Copy-Item $scriptSrc $scriptDest -Force
Write-Host "Script installato in: $scriptDest"

# Gestione $PROFILE (CurrentUserCurrentHost)
$profileDir = Split-Path $PROFILE -Parent
if (-not (Test-Path $profileDir)) {
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
}
if (-not (Test-Path $PROFILE)) {
    New-Item -ItemType File -Path $PROFILE -Force | Out-Null
}

$profileContent = Get-Content $PROFILE -Raw -Encoding UTF8
if ($null -eq $profileContent) { $profileContent = '' }

if ($profileContent -match [regex]::Escape($markerBegin)) {
    Write-Host "Alias gia' presente in $PROFILE -- skip."
} else {
    $block = @"

$markerBegin
function ccprofile { & "$scriptDest" @args }
$markerEnd
"@
    Add-Content $PROFILE -Value $block -Encoding UTF8
    Write-Host "Alias aggiunto in: $PROFILE"
}

Write-Host ""
Write-Host "OK: Installazione completata."
Write-Host "Riavvia PowerShell oppure esegui: . `"$PROFILE`""
