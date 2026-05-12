#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

$script:passed  = 0
$script:failed  = 0
$script:realHome = $HOME

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        Write-Host "PASS: $Name" -ForegroundColor Green
        $script:passed++
    } catch {
        Write-Host "FAIL: $Name -- $_" -ForegroundColor Red
        $script:failed++
    }
}

# Isolamento: override $HOME con directory temporanea
$testRoot = Join-Path $env:TEMP "ccprofile-test-$(Get-Random)"
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
Write-Host "Test root: $testRoot" -ForegroundColor Cyan

Set-Variable -Name HOME -Value $testRoot -Scope Global -Force

# Dot-source: costanti ricalcolate contro $testRoot, dispatcher non eseguito
. "$PSScriptRoot\ccprofile.ps1"

# Inizializza struttura directory nel testRoot
Initialize-Dirs

$mockCredsContent = '{"oauth_token":"mock-token-for-testing"}'

try {
    Invoke-Test "1. add profilo apikey" {
        Command-Add @("testkey", "--type", "apikey", "--key", "sk-ant-testkey1234567890abcdefghij")
        $reg = Read-Registry
        if ($null -eq $reg.PSObject.Properties['testkey']) { throw "Profilo 'testkey' non nel registro" }
        if ($reg.PSObject.Properties['testkey'].Value.type -ne 'apikey') { throw "Tipo atteso 'apikey'" }
    }

    Invoke-Test "2. list mostra il profilo" {
        $out = & { Command-List @() } 6>&1 | Out-String
        if ($out -notmatch 'testkey') { throw "Output non contiene 'testkey': $out" }
    }

    Invoke-Test "3. use attiva profilo e imposta env var" {
        Command-Use @("testkey")
        if ($env:ANTHROPIC_API_KEY -ne "sk-ant-testkey1234567890abcdefghij") {
            throw "ANTHROPIC_API_KEY = '$env:ANTHROPIC_API_KEY'"
        }
        if ((Read-ActiveProfile) -ne "testkey") {
            throw "Active profile = '$(Read-ActiveProfile)'"
        }
    }

    Invoke-Test "4. add profilo pro (con mock credentials)" {
        Set-Content (Join-Path $script:CLAUDE_DIR ".credentials.json") -Value $mockCredsContent -Encoding UTF8
        Command-Add @("testpro", "--type", "pro")
        $reg = Read-Registry
        if ($null -eq $reg.PSObject.Properties['testpro']) { throw "Profilo 'testpro' non nel registro" }
        if ($reg.PSObject.Properties['testpro'].Value.type -ne 'pro') { throw "Tipo atteso 'pro'" }
        $credPath = Join-Path (Get-ProfileDir "testpro") ".credentials.json"
        if (-not (Test-Path $credPath)) { throw ".credentials.json non copiato nella dir profilo" }
    }

    Invoke-Test "5. use profilo pro rimuove env var" {
        Command-Use @("testpro")
        if (-not [string]::IsNullOrEmpty($env:ANTHROPIC_API_KEY)) {
            throw "ANTHROPIC_API_KEY non rimossa: '$env:ANTHROPIC_API_KEY'"
        }
        $credsInClaude = Join-Path $script:CLAUDE_DIR ".credentials.json"
        if (-not (Test-Path $credsInClaude)) {
            throw ".credentials.json non presente in CLAUDE_DIR dopo switch a pro"
        }
    }

    Invoke-Test "6. rename profilo" {
        Command-Use @("testkey")
        Command-Rename @("testkey", "testkey-renamed")
        $reg = Read-Registry
        if ($null -eq $reg.PSObject.Properties['testkey-renamed']) {
            throw "Profilo 'testkey-renamed' non nel registro"
        }
        if ($null -ne $reg.PSObject.Properties['testkey']) {
            throw "Profilo 'testkey' ancora nel registro"
        }
        if (-not (Test-Path (Get-ProfileDir "testkey-renamed"))) {
            throw "Directory 'testkey-renamed' non trovata"
        }
        if ((Read-ActiveProfile) -ne "testkey-renamed") {
            throw "Active profile non aggiornato dopo rename"
        }
    }

    Invoke-Test "7. delete profilo non attivo" {
        Command-Delete @("testpro")
        $reg = Read-Registry
        if ($null -ne $reg.PSObject.Properties['testpro']) {
            throw "Profilo 'testpro' ancora nel registro"
        }
        if (Test-Path (Get-ProfileDir "testpro")) {
            throw "Directory 'testpro' ancora su disco"
        }
    }

    Invoke-Test "8. delete profilo attivo fallisce" {
        $activeBefore = Read-ActiveProfile
        # Write-Err + return: non lancia eccezione
        Command-Delete @($activeBefore)
        $reg = Read-Registry
        if ($null -eq $reg.PSObject.Properties[$activeBefore]) {
            throw "Profilo attivo '$activeBefore' eliminato -- non doveva succedere"
        }
    }

    Invoke-Test "9. export/import round-trip" {
        $zipPath = Join-Path $env:TEMP "ccprofile-test-export-$(Get-Random).zip"
        try {
            $origSettings = Get-Content (Join-Path (Get-ProfileDir "testkey-renamed") "settings.json") -Raw -Encoding UTF8

            Command-Export @("testkey-renamed", "--out", $zipPath)
            if (-not (Test-Path $zipPath)) { throw "File zip non creato: $zipPath" }

            Command-Import @($zipPath, "--name", "testkey-imported")

            $reg = Read-Registry
            if ($null -eq $reg.PSObject.Properties['testkey-imported']) {
                throw "Profilo 'testkey-imported' non nel registro dopo import"
            }

            $importedSettings = Get-Content (Join-Path (Get-ProfileDir "testkey-imported") "settings.json") -Raw -Encoding UTF8
            if ($importedSettings -ne $origSettings) {
                throw "settings.json non corrisponde: orig='$origSettings' imported='$importedSettings'"
            }

            # Verifica api_key REDACTED nel registro (non la key originale)
            $importedProfile = $reg.PSObject.Properties['testkey-imported'].Value
            if ($importedProfile.api_key -ne 'REDACTED') {
                throw "api_key non REDACTED nell'importato: '$($importedProfile.api_key)'"
            }
        } finally {
            if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        }
    }

    Invoke-Test "10. nome profilo invalido lancia eccezione" {
        $threw = $false
        try {
            Assert-ProfileName "bad name!"
        } catch {
            $threw = $true
        }
        if (-not $threw) { throw "Assert-ProfileName non ha lanciato eccezione" }
    }

    Invoke-Test "11. set-url imposta env var per profilo attivo" {
        # testkey-renamed e' attivo
        $active = Read-ActiveProfile
        Command-SetUrl @($active, "--url", "http://localhost:11434")

        $reg = Read-Registry
        if ($reg.PSObject.Properties[$active].Value.base_url -ne "http://localhost:11434") {
            throw "base_url non nel registro"
        }
        if ($env:ANTHROPIC_BASE_URL -ne "http://localhost:11434") {
            throw "ANTHROPIC_BASE_URL = '$env:ANTHROPIC_BASE_URL'"
        }
    }

    Invoke-Test "12. set-url --clear rimuove env var per profilo attivo" {
        $active = Read-ActiveProfile
        Command-SetUrl @($active, "--clear")

        $reg = Read-Registry
        $profileProps = $reg.PSObject.Properties[$active].Value.PSObject.Properties
        if ($null -ne ($profileProps | Where-Object { $_.Name -eq 'base_url' })) {
            throw "base_url ancora nel registro dopo clear"
        }
        if (-not [string]::IsNullOrEmpty($env:ANTHROPIC_BASE_URL)) {
            throw "ANTHROPIC_BASE_URL non rimossa: '$env:ANTHROPIC_BASE_URL'"
        }
    }

} finally {
    Set-Variable -Name HOME -Value $script:realHome -Scope Global -Force

    if (Test-Path $testRoot) {
        Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ""
    $color = if ($script:failed -eq 0) { 'Green' } else { 'Red' }
    Write-Host "Risultati: $script:passed PASS, $script:failed FAIL su $($script:passed + $script:failed) test totali" -ForegroundColor $color

    if ($script:failed -gt 0) { exit 1 }
}
