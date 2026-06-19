# CLAUDE.md — claude-desktop-clone

Guidance for Claude Code (or any AI assistant) working in this repository.

## What this project is

A small Windows tool to run **multiple isolated instances of the Claude Desktop
app**, one per account. It does **not** modify or repackage the Claude app — it
only launches the officially installed MSIX app with Chromium's
`--user-data-dir` flag so each instance gets its own single-instance lock and
its own login.

## Core mechanism (do not break this)

1. **Resolve the exe dynamically.** The app is an MSIX package at
   `C:\Program Files\WindowsApps\Claude_<version>_x64__<hash>\app\Claude.exe`.
   The version segment changes on every update, and that folder is
   permission-restricted for directory listing. Always resolve the path via
   `Get-AppxPackage -Name '*Claude*'` and read `.InstallLocation`. Only fall
   back to a `WindowsApps\Claude_*__*\app\Claude.exe` glob if the Appx query
   fails. **Never hard-code the versioned path** — it will break on the next
   update.

2. **Isolation = a distinct `--user-data-dir`.** This is the entire trick. Two
   shortcuts must point at two different data directories. Don't "optimize" by
   sharing a directory — that re-merges the accounts and defeats the tool.

3. **Launch directly via the exe**, not via MSIX shell activation. MSIX
   activation (`shell:AppsFolder\...!Claude`) does not reliably forward the
   `--user-data-dir` argument; launching the exe path does.

4. **Icons must point at a stable path, never the versioned exe.** `Setup.ps1`
   extracts the Claude icon once into `bin\claude.ico` and sets every shortcut's
   `IconLocation` to that file. Setting `IconLocation` to the versioned
   `WindowsApps\Claude_<version>\...\Claude.exe` makes icons go blank after the
   next update deletes that folder. Extract via `PrivateExtractIcons` → render to
   a `Bitmap` → write a 32-bit **PNG-based `.ico`** by hand. Do **not** use
   `Icon.Save()`: saving an icon built from an `HICON` drops the colour plane and
   writes only the 1-bit mask, producing a grey icon.

## Optional second isolation layer (`CLAUDE_CONFIG_DIR`)

`--user-data-dir` isolates the **Claude Desktop login** only. The embedded
**Claude Code / Cowork** still reads the shared `~/.claude` store (memory,
settings) regardless of which profile launched it. To isolate that too, a
profile can point `CLAUDE_CONFIG_DIR` at a dedicated directory:

- `Launch-Claude.ps1 -ConfigDir <path>` sets `$env:CLAUDE_CONFIG_DIR` before
  `Start-Process`. The child app (and any `claude-code` it spawns) inherits it.
- `launch.vbs` forwards an optional **2nd argument** as that config dir.
- `Setup.ps1 -ConfigDir @{ Personal = '<path>' }` (a hashtable) wires a profile's
  shortcut to pass the 3rd `wscript` argument.

This is **additive and optional** — omitting it keeps the shared `~/.claude`
store, which is the default. Don't make it mandatory or hard-code a path.

## Layout

```
scripts/
  Launch-Claude.ps1   # resolve exe + Start-Process with --user-data-dir; optional -ConfigDir sets CLAUDE_CONFIG_DIR
  launch.vbs          # run the .ps1 hidden (no console window); finds the .ps1 next to itself; optional 2nd arg = config dir
  Setup.ps1           # installer: copies scripts to %USERPROFILE%\ClaudeProfiles\bin, extracts a stable bin\claude.ico, makes profiles + desktop shortcuts; -ConfigDir hashtable maps a profile to its own memory store
  Uninstall.ps1       # removes shortcuts (and optionally profile data)
  Build-Exe.ps1       # optional: wrap Launch-Claude.ps1 into an .exe via ps2exe
```

## Conventions

- **PowerShell** is the primary language. Keep scripts dependency-free — only
  built-in cmdlets and `WScript.Shell` COM. The only optional external piece is
  `ps2exe` in `Build-Exe.ps1`.
- Scripts must run **without admin rights**.
- Keep everything **idempotent**: re-running `Setup.ps1` should just refresh.
- Resolve user paths via `$env:USERPROFILE`, `$env:APPDATA`, and
  `[Environment]::GetFolderPath('Desktop')` — never hard-code `C:\Users\<name>`.
- Use comment-based help (`.SYNOPSIS` / `.PARAMETER`) on every script.

## Testing changes

There is no automated test suite (it's OS/GUI integration). To verify by hand:

```powershell
# 1) Resolve + launch an isolated instance:
.\scripts\Launch-Claude.ps1 -ProfileDir "$env:TEMP\claude-test"

# 2) Confirm it launched with the right flag:
Get-CimInstance Win32_Process -Filter "Name='Claude.exe'" |
    Where-Object { $_.CommandLine -like '*claude-test*' } |
    Select-Object ProcessId, CommandLine
```

A successful run shows `Claude.exe --user-data-dir=...\claude-test` and creates
a populated `claude-test` folder (Local Storage, lockfile, etc.).

To verify config isolation, add `-ConfigDir` and confirm the env var reaches the
child process:

```powershell
.\scripts\Launch-Claude.ps1 -ProfileDir "$env:TEMP\claude-test" -ConfigDir "$env:TEMP\claude-cfg-test"
# The launched process inherits CLAUDE_CONFIG_DIR=...\claude-cfg-test;
# the directory is created if missing.
```

## Git workflow

Two long-lived branches, mirroring the `vodongha-personal` setup.

```
feature/* ──┐
bug/*    ──→  develop  →  PR → develop (merged)  →  PR → master
hotfix/* ──────────────────────────────────────→  PR → master
                                                        ↓
                                          develop ← auto-synced by sync-develop.yml
```

| Branch type | Base branch | PR target | When to use |
|---|---|---|---|
| `feature/short-description` | `develop` | `develop` | New feature |
| `bug/short-description` | `develop` | `develop` | Non-urgent fix |
| `hotfix/short-description` | `master` | `master` | Urgent fix |

- **`master` is the stable branch — never commit directly.** Feature/bug work goes through
  `develop`; merge `develop → master` to release. Hotfixes branch from `master` and PR straight to
  it; `develop` picks them up via `sync-develop.yml` (merges `master → develop` after every push to
  `master`). There is no deploy — `master` is just the published, stable state.
- `ci.yml` runs **PSScriptAnalyzer** (errors only) on pushes to `develop` and PRs to `master`.
- Merge with **merge commits** (no squash/rebase). Personal repo — set the identity locally
  (`git config --local user.email "vodongha@hotmail.com"`). AI-assisted commits are **authored by
  `vodongha`** with **Claude as the committer**:
  ```bash
  GIT_COMMITTER_NAME="Claude Opus 4.8" GIT_COMMITTER_EMAIL="noreply@anthropic.com" \
    git commit --author="vodongha <vodongha@hotmail.com>" -m "..."
  ```

## Out of scope

- Codex / other apps (this repo is Claude-only by design).
- Modifying the Claude app's files or signing/repackaging it.
- Anything requiring admin elevation.
