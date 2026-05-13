# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

Run tests:
```powershell
pwsh -File test-ccprofile.ps1
```

Install (adds `ccprofile` function to `$PROFILE`):
```powershell
pwsh -File install.ps1
```

Uninstall:
```powershell
pwsh -File install.ps1 -Uninstall
```

## Architecture

Single-script CLI (`ccprofile.ps1`) with no external dependencies. All logic lives in one file, structured in regions.

**Data layout on disk:**
```
~/.claude-profiles/
├── bin/ccprofile.ps1          ← installed copy
├── profiles/<name>/
│   ├── settings.json          ← always present
│   ├── .credentials.json      ← pro profiles only
│   └── oauth-account.json     ← pro profiles only (oauthAccount from ~/.claude.json)
├── profiles.json              ← registry: { name: { type, api_key?, base_url?, created } }
└── active                     ← plain text: active profile name

~/.claude/
├── settings.json              ← active profile's file (swapped on use)
└── .credentials.json          ← active profile's file (pro only, removed on apikey switch)

~/.claude.json                 ← oauthAccount field patched on profile switch
```

**Profile types:**
- `pro` — OAuth credentials; `~/.claude/.credentials.json` and `oauth-account.json` swapped; `ANTHROPIC_API_KEY` cleared on activation
- `apikey` — API key stored in registry; `ANTHROPIC_API_KEY` set on activation; optional `base_url` for Ollama/local endpoints

**Key invariants:**
- `~/.claude/` always holds the active profile's files
- `Save-CurrentFiles` saves the active profile before every switch
- `Apply-ProfileFiles-Safe` wraps the file swap with backup/rollback in `~/.claude/.ccprofile-backup/`
- When switching to `apikey`: `oauthAccount` removed from `~/.claude.json`; when switching to `pro`: restored from `profiles/<name>/oauth-account.json`
- `ANTHROPIC_BASE_URL` is always set/cleared in sync with the active profile's `base_url` field

**Script guard for test isolation:**
```powershell
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Ccprofile @($args)
}
```
The dispatcher does not run when the file is dot-sourced (used by `test-ccprofile.ps1`). Constants (`$script:PROFILES_BASE`, `$script:CLAUDE_JSON`, etc.) are computed at dot-source time using `$HOME`, so overriding `$HOME` before dot-sourcing redirects all I/O to a temp directory.

**`?.` operator gotcha:** PS7's null-conditional `?.` does not traverse the PowerShell Extended Type System — it cannot see NoteProperties added by `ConvertFrom-Json` or `Add-Member`. Use explicit null checks (`$null -eq $obj -or $null -eq $obj.prop`) for PSCustomObject properties.
