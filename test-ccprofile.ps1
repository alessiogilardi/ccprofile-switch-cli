#Requires -Version 7.0

$ErrorActionPreference = 'Stop'

$script:passed  = 0
$script:failed  = 0
$script:realHome    = $HOME
$script:realProfile = $PROFILE

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

# Isolamento: override $PROFILE per non toccare il profilo PowerShell reale
# (i comandi alias-* lo leggono a runtime, non a dot-source time)
Set-Variable -Name PROFILE -Value (Join-Path $testRoot "Microsoft.PowerShell_profile.ps1") -Scope Global -Force

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

    Invoke-Test "13. switch a apikey rimuove oauthAccount da .claude.json" {
        $claudeJsonPath = Join-Path $testRoot ".claude.json"
        $mockOAuth = [PSCustomObject]@{ accountUuid = "test-uuid"; emailAddress = "test@example.com" }
        [PSCustomObject]@{ oauthAccount = $mockOAuth } | ConvertTo-Json -Depth 5 |
            Set-Content $claudeJsonPath -Encoding UTF8

        Command-Add @("testpro2", "--type", "pro")
        Command-Use @("testpro2")
        Command-Use @("testkey-renamed")

        $claudeData = Get-Content $claudeJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $claudeData.oauthAccount) {
            throw "oauthAccount non rimossa dopo switch a apikey: $($claudeData.oauthAccount)"
        }
    }

    Invoke-Test "14. switch a pro ripristina oauthAccount in .claude.json" {
        $claudeJsonPath = Join-Path $testRoot ".claude.json"
        Command-Use @("testpro2")
        $claudeData = Get-Content $claudeJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $claudeData.oauthAccount) {
            throw "oauthAccount non ripristinata dopo switch a pro"
        }
        if ($claudeData.oauthAccount.emailAddress -ne "test@example.com") {
            throw "oauthAccount.emailAddress = '$($claudeData.oauthAccount.emailAddress)'"
        }
    }

    Invoke-Test "15. use --start lancia claude dopo lo switch" {
        if ((Read-ActiveProfile) -ne "testpro2") { throw "Precondizione non soddisfatta: attivo != testpro2" }

        $script:startCallCount = 0
        function Start-Claude { $script:startCallCount++ }

        Command-Use @("testkey-renamed", "--start")
        if ($script:startCallCount -ne 1) {
            throw "Start-Claude non invocata dopo switch (count=$script:startCallCount)"
        }
        if ((Read-ActiveProfile) -ne "testkey-renamed") {
            throw "Switch non avvenuto: attivo = '$(Read-ActiveProfile)'"
        }
    }

    Invoke-Test "16. use --start su profilo gia' attivo lancia comunque claude" {
        if ((Read-ActiveProfile) -ne "testkey-renamed") { throw "Precondizione non soddisfatta: attivo != testkey-renamed" }

        $script:startCallCount = 0
        function Start-Claude { $script:startCallCount++ }

        Command-Use @("testkey-renamed", "--start")
        if ($script:startCallCount -ne 1) {
            throw "Start-Claude non invocata su profilo gia' attivo (count=$script:startCallCount)"
        }
    }

    Invoke-Test "17. use su profilo gia' attivo riconcilia comunque le env var" {
        Command-Use @("testpro2")
        if ((Read-ActiveProfile) -ne "testpro2") { throw "Precondizione non soddisfatta: attivo != testpro2" }

        # Simula un ANTHROPIC_API_KEY residuo ereditato da un processo padre,
        # indipendente da cio' che 'active' registra
        $env:ANTHROPIC_API_KEY = "sk-ant-stale-leftover-from-parent-process"

        Command-Use @("testpro2")

        if (-not [string]::IsNullOrEmpty($env:ANTHROPIC_API_KEY)) {
            throw "ANTHROPIC_API_KEY residuo non ripulito su profilo gia' attivo: '$env:ANTHROPIC_API_KEY'"
        }
    }

    Invoke-Test "18. alias add con nome di default (= nome profilo)" {
        Command-AliasAdd @("testkey-renamed")

        $aliases = Read-Aliases
        if ($aliases['testkey-renamed'] -ne 'testkey-renamed') {
            throw "aliases.json non contiene 'testkey-renamed' -> 'testkey-renamed'"
        }

        $profileContent = Get-Content $PROFILE -Raw -Encoding UTF8
        if ($profileContent -notmatch [regex]::Escape('# BEGIN ccprofile-alias:testkey-renamed')) {
            throw "Blocco alias non trovato in `$PROFILE"
        }
        if ($profileContent -notmatch [regex]::Escape('function testkey-renamed { ccprofile use testkey-renamed --start }')) {
            throw "Funzione alias con contenuto inatteso in `$PROFILE"
        }
    }

    Invoke-Test "19. alias add con nome personalizzato (--as)" {
        Command-AliasAdd @("testpro2", "--as", "claude-work")

        $aliases = Read-Aliases
        if ($aliases['claude-work'] -ne 'testpro2') {
            throw "aliases.json non contiene 'claude-work' -> 'testpro2'"
        }

        $profileContent = Get-Content $PROFILE -Raw -Encoding UTF8
        if ($profileContent -notmatch [regex]::Escape('function claude-work { ccprofile use testpro2 --start }')) {
            throw "Funzione alias 'claude-work' non trovata in `$PROFILE"
        }
    }

    Invoke-Test "20. alias-list elenca gli alias configurati" {
        $out = & { Command-AliasList @() } 6>&1 | Out-String
        if ($out -notmatch 'testkey-renamed -> testkey-renamed') { throw "Output non contiene l'alias 'testkey-renamed': $out" }
        if ($out -notmatch 'claude-work -> testpro2') { throw "Output non contiene l'alias 'claude-work': $out" }
    }

    Invoke-Test "21. alias add su nome gia' in uso da un altro profilo fallisce" {
        $before = Read-Aliases
        # Write-Err + return: non lancia eccezione
        Command-AliasAdd @("testkey-renamed", "--as", "claude-work")
        $after = Read-Aliases
        if ($after['claude-work'] -ne $before['claude-work']) { throw "aliases.json modificato nonostante l'errore" }
    }

    Invoke-Test "22. alias remove rimuove l'alias" {
        Command-AliasRemove @("claude-work")

        $aliases = Read-Aliases
        if ($aliases.ContainsKey('claude-work')) { throw "'claude-work' ancora in aliases.json" }

        $profileContent = Get-Content $PROFILE -Raw -Encoding UTF8
        if ($profileContent -match [regex]::Escape('ccprofile-alias:claude-work')) {
            throw "Blocco alias 'claude-work' ancora presente in `$PROFILE"
        }
        if ($profileContent -notmatch [regex]::Escape('ccprofile-alias:testkey-renamed')) {
            throw "Blocco alias 'testkey-renamed' rimosso per errore"
        }
    }

    Invoke-Test "23. alias remove su alias inesistente non modifica lo stato" {
        $keysBefore = (Read-Aliases).Keys | Sort-Object
        # Write-Err + return: non lancia eccezione
        Command-AliasRemove @("non-esiste")
        $keysAfter = (Read-Aliases).Keys | Sort-Object
        if (($keysBefore -join ',') -ne ($keysAfter -join ',')) {
            throw "aliases.json modificato nonostante l'errore"
        }
    }

    Invoke-Test "24. dispatcher 'ccprofile alias' instrada add/list/remove" {
        Command-Alias @("add", "testpro2", "--as", "claude-dispatch")
        $aliases = Read-Aliases
        if ($aliases['claude-dispatch'] -ne 'testpro2') { throw "'alias add' via dispatcher non ha creato l'alias" }

        $out = & { Command-Alias @("list") } 6>&1 | Out-String
        if ($out -notmatch 'claude-dispatch -> testpro2') { throw "'alias list' via dispatcher non elenca l'alias: $out" }

        Command-Alias @("remove", "claude-dispatch")
        $aliases = Read-Aliases
        if ($aliases.ContainsKey('claude-dispatch')) { throw "'alias remove' via dispatcher non ha rimosso l'alias" }
    }

    Invoke-Test "25. dispatcher 'ccprofile alias' con sottocomando sconosciuto non lancia eccezione" {
        # Write-Err + return: non lancia eccezione
        Command-Alias @("bogus")
    }

} finally {
    Set-Variable -Name HOME -Value $script:realHome -Scope Global -Force
    Set-Variable -Name PROFILE -Value $script:realProfile -Scope Global -Force

    if (Test-Path $testRoot) {
        Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ""
    $color = $script:failed -eq 0 ? 'Green' : 'Red'
    Write-Host "Risultati: $script:passed PASS, $script:failed FAIL su $($script:passed + $script:failed) test totali" -ForegroundColor $color

    if ($script:failed -gt 0) { exit 1 }
}
