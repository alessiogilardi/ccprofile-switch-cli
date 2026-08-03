# ccprofile

A PowerShell CLI for managing multiple [Claude Code](https://claude.ai/code) profiles on Windows. Switch between a Pro (OAuth) account and one or more API-key accounts — or point Claude Code at a local Ollama instance — without touching config files by hand.

## Requirements

- PowerShell 7.0+
- Windows (paths use `~/.claude/` as Claude Code does)

## Installation

```powershell
pwsh -File install.ps1
```

Then restart PowerShell (or run `. $PROFILE`). The installer copies `ccprofile.ps1` to `~/.claude-profiles/bin/` and injects a `ccprofile` function into your `$PROFILE`.

To uninstall:

```powershell
pwsh -File install.ps1 -Uninstall
```

## Profile types

| Type | Credentials | `ANTHROPIC_API_KEY` |
|------|-------------|---------------------|
| `pro` | OAuth — reads/writes `~/.claude/.credentials.json` | cleared on activation |
| `apikey` | Stored in registry | set on activation |

Both types support an optional `base_url` (e.g. for a local Ollama endpoint), which maps to `ANTHROPIC_BASE_URL`.

## Usage

```
ccprofile <command> [arguments]
```

### Commands

| Command | Description |
|---------|-------------|
| `list` | List all profiles (`*` marks the active one) |
| `use <name> [--start]` | Switch to a profile (with `--start`, also launches `claude` afterwards) |
| `alias add <name> [--as <alias>]` | Create a PowerShell function that runs `use <name> --start` (alias defaults to the profile name) |
| `alias list` | List configured aliases |
| `alias remove <alias>` | Remove an alias |
| `add <name> --type pro\|apikey [--key sk-ant-...] [--base-url <url>]` | Create a new profile |
| `delete <name>` | Delete a profile (cannot delete the active profile) |
| `current` | Print the active profile name |
| `status` | Show details of the active profile |
| `rename <old> <new>` | Rename a profile |
| `edit [<name>]` | Open `settings.json` in the default editor |
| `export <name> [--out file.zip]` | Export a profile to a zip (credentials excluded) |
| `import <file.zip> [--name <name>]` | Import a profile from a zip |
| `set-key <name> --key sk-ant-...` | Update the API key of an `apikey` profile |
| `set-url <name> --url <url>` | Set a custom base URL for a profile |
| `set-url <name> --clear` | Remove the custom base URL |
| `help`, `-h`, `--help` | Show help |

### Examples

```powershell
# Add a Pro account (copies current ~/.claude/.credentials.json)
ccprofile add work --type pro

# Add an API key account
ccprofile add personal --type apikey --key sk-ant-api03-...

# Add an account pointing to a local Ollama instance
ccprofile add ollama --type apikey --key ollama --base-url http://localhost:11434

# Switch profiles
ccprofile use work

# Switch profiles and immediately launch claude
ccprofile use work --start

# Create a shortcut: typing "work" switches to the profile and launches claude
ccprofile alias add work

# Create a shortcut with a custom name
ccprofile alias add personal --as claude-personal

# List / remove shortcuts
ccprofile alias list
ccprofile alias remove claude-personal

# Check what's active
ccprofile status

# Export for sharing (credentials are redacted)
ccprofile export work --out work-profile.zip

# Import on another machine
ccprofile import work-profile.zip --name work
ccprofile set-key work --key sk-ant-api03-...
```

## What gets swapped on profile switch

- `~/.claude/settings.json`
- `~/.claude/.credentials.json` (pro profiles only; removed when switching to apikey)
- `oauthAccount` field in `~/.claude.json` (restored for pro, removed for apikey)
- `ANTHROPIC_API_KEY` environment variable (process + User scope)
- `ANTHROPIC_BASE_URL` environment variable (if `base_url` is configured)

Profile files are stored under `~/.claude-profiles/profiles/<name>/`. The switch is atomic: a backup is taken before the swap and restored on failure.

## Shell aliases

`ccprofile alias add <name>` injects a small PowerShell function into your `$PROFILE`, delimited by `# BEGIN ccprofile-alias:<alias>` / `# END` markers (same pattern the installer uses for the `ccprofile` function itself):

```powershell
# BEGIN ccprofile-alias:work
function work { ccprofile use work --start }
# END ccprofile-alias:work
```

The alias-to-profile mapping is also tracked in `~/.claude-profiles/aliases.json` so `alias list`/`alias remove` don't need to parse `$PROFILE`. Restart PowerShell (or run `. $PROFILE`) after creating or removing an alias.

## Running tests

```powershell
pwsh -File test-ccprofile.ps1
```

25 end-to-end tests run in an isolated temp directory (overrides `$HOME` and `$PROFILE`).
