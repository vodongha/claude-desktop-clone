# claude-desktop-clone

Run **multiple isolated instances of the Claude Desktop app on Windows** — one
per account (e.g. *Work* and *Personal*) — side by side, each with its own
login, history, and settings.

The official Claude Desktop app (installed from the Microsoft Store / claude.ai)
only supports **one account at a time** and refuses to open a second window.
This repo works around that with a tiny, dependency-free launcher.

> 🇻🇳 Bản tóm tắt tiếng Việt ở [cuối README](#tiếng-việt--quickstart).

---

## How it works

The Claude Desktop app is an **Electron / Chromium** application. Chromium
accepts the standard `--user-data-dir` flag, and it keys its *single-instance
lock* on that directory. So:

> **Different `--user-data-dir` → different lock → a second instance runs,
> signed into a different account.**

The only Windows-specific wrinkle is that the app is shipped as an **MSIX
package**, so its executable lives under a versioned, permission-restricted
path:

```
C:\Program Files\WindowsApps\Claude_<version>_x64__<hash>\app\Claude.exe
```

The launcher resolves that path at runtime via `Get-AppxPackage` (so it survives
app updates) and starts it with a chosen data directory:

```powershell
Claude.exe --user-data-dir="C:\Users\<you>\ClaudeProfiles\personal"
```

That's the whole trick. No patching, no copying the app, no admin rights.

> **Credit:** the `--user-data-dir` technique for Claude is from
> [Zoltak-Dev/ai-multi-instance](https://github.com/Zoltak-Dev/ai-multi-instance).
> This repo is a small, native (PowerShell + VBScript) reimplementation focused
> on Claude only, with desktop shortcuts and a one-command setup.

---

## Requirements

- Windows 10/11
- The official **Claude Desktop app** installed
  ([claude.ai/download](https://claude.ai/download) or Microsoft Store)
- No admin rights, no Python, no extra dependencies

---

## Quick start

```powershell
git clone https://github.com/vodongha/claude-desktop-clone.git
cd claude-desktop-clone

# Create "Claude (Work)" + "Claude (Personal)" shortcuts on your Desktop.
# -ReuseDefaultForWork keeps your already-signed-in account for "Work".
powershell -ExecutionPolicy Bypass -File scripts\Setup.ps1 -ReuseDefaultForWork
```

Then:

1. Double-click **Claude (Work)** → your existing account (no re-login).
2. Double-click **Claude (Personal)** → a fresh window; sign in to the other
   account.

Both windows now run at the same time, fully isolated.

### Custom profiles

```powershell
# Any names you like; each gets its own isolated login + shortcut.
powershell -ExecutionPolicy Bypass -File scripts\Setup.ps1 -Profile Personal,ClientA,ClientB
```

### Different install location

```powershell
powershell -ExecutionPolicy Bypass -File scripts\Setup.ps1 -InstallDir "D:\ClaudeProfiles"
```

### Isolate Claude Code / Cowork memory per profile

By default, instances only isolate the **login** (Chromium `--user-data-dir`).
The embedded **Claude Code / Cowork** still uses the shared `~/.claude` config
(memory, settings). To give a profile its *own* memory store too, point its
`CLAUDE_CONFIG_DIR` at a dedicated directory via `-ConfigDir`:

```powershell
# NOTE: a real hashtable -> call the script directly (not via -File):
& .\scripts\Setup.ps1 -ConfigDir @{ Personal = "$env:USERPROFILE\.claude-personal" }
```

Now the **Personal** instance's Claude Code memory lives in
`~/.claude-personal\projects\<dir>\memory\`, fully separate from the work
account — and it's the same store the `claude-personal` CLI uses (if you set one
up). Manual equivalent for any launcher:

```text
wscript.exe launch.vbs "<profile-data-dir>" "<claude-config-dir>"
```

---

## What gets created

```
%USERPROFILE%\ClaudeProfiles\
└── bin\
    ├── Launch-Claude.ps1     # resolves the MSIX exe, launches with --user-data-dir
    ├── launch.vbs            # runs the .ps1 hidden (no console flash)
    └── claude.ico            # icon extracted to a STABLE path (survives updates)

%APPDATA%\                     # profile DATA lives here (required for Cowork VM)
├── Personal\                 # isolated Chromium profile (login, history, cache, VM)
└── Work\                     # (only if not reusing the default login)

Desktop\
├── Claude (Work).lnk
└── Claude (Personal).lnk
```

The shortcuts point at the copied `bin\` scripts, so you can delete the cloned
repo afterwards and everything keeps working. Profile *data* lives under
`%APPDATA%\<name>` (not under `ClaudeProfiles\`) — this is required so Claude's
**Cowork** VM can start; see [Cowork limitations](#cowork-vm-limitations) below.

---

## Usage notes

- **Re-clicking a shortcut** focuses that profile's existing window instead of
  opening a duplicate — exactly the normal single-instance behaviour, but scoped
  per profile.
- **App updates** are handled automatically: the launcher re-resolves the exe
  path each time via `Get-AppxPackage`.
- **Shortcut icons survive updates.** `Setup.ps1` extracts the Claude icon once
  to `bin\claude.ico` (a stable path) and points every shortcut there. Pointing a
  shortcut straight at the versioned `WindowsApps\Claude_<version>\...\Claude.exe`
  would go blank after the next update deletes that folder — which is why the
  icon is copied out to a fixed location instead.
- **Switching the "main" app:** the regular Start-menu Claude icon still uses
  `%APPDATA%\Claude`, i.e. the same login as a "Work" profile created with
  `-ReuseDefaultForWork`.

---

## Optional: build a real `.exe`

If you'd rather have a single executable than a `.vbs`:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\Build-Exe.ps1
# -> dist\ClaudeLauncher.exe  (takes -ProfileDir "<path>")
```

This uses [`ps2exe`](https://github.com/MScholtes/PS2EXE). Note that unsigned
ps2exe binaries can trip SmartScreen / antivirus heuristics — the `.vbs`
launcher created by `Setup.ps1` is the recommended, friction-free option.

---

## Uninstall

```powershell
# Remove the shortcuts only:
powershell -ExecutionPolicy Bypass -File scripts\Uninstall.ps1

# Remove shortcuts AND the isolated profile data (signs you out, clears history):
powershell -ExecutionPolicy Bypass -File scripts\Uninstall.ps1 -RemoveData
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Claude Desktop app not found" | Install it from [claude.ai/download](https://claude.ai/download) and run `Setup.ps1` again. |
| Shortcut does nothing | Run `scripts\Launch-Claude.ps1 -ProfileDir <dir>` directly in PowerShell to see the error. |
| Second window won't open | Make sure the two shortcuts use **different** `--user-data-dir` paths (check shortcut *Target*). |
| Icon is blank or grey | Re-run `Setup.ps1` (current versions extract the icon to a stable `bin\claude.ico`, so it survives updates). If a stale thumbnail lingers, clear the icon cache: `ie4uinit.exe -show`, or `Stop-Process -Name explorer -Force; Start-Process explorer`. |
| **"Failed to start Claude's workspace" / `VHDX file not found`** in a cloned profile | The profile's data dir is **outside `%APPDATA%`**, so the Cowork VM service can't find `rootfs.vhdx`. Re-run `Setup.ps1` (current version puts profiles under `%APPDATA%`). To migrate an existing profile without re-login, move `ClaudeProfiles\<name>` → `%APPDATA%\<name>` and update the shortcut's first argument to `%APPDATA%\<name>`. Do **not** use a junction/symlink for `vm_bundles` — the VM service refuses to open reparse points. |
| **Cowork won't start in one profile while another is open** (`HYPERVISOR_SERVICE_ERROR`, *"a virtual machine … with the specified identifier already exists"*) | Expected — see [Cowork VM limitations](#cowork-vm-limitations). Only one profile can run the Cowork VM at a time; quit the other profile (or reboot to clear a stale VM) before launching. |

---

## Cowork VM limitations

Claude Desktop's **Cowork** feature (the agentic workspace, scheduled tasks, and
artifact storage) runs inside a per-machine **Hyper-V VM**, not just an Electron
window. Two consequences for multi-profile use:

1. **Profile data must live under `%APPDATA%`.** The native VM service resolves
   the VM image (`rootfs.vhdx`) at `%APPDATA%\<profile-name>\vm_bundles`,
   *ignoring* `--user-data-dir`. `Setup.ps1` therefore places isolated profiles
   under `%APPDATA%\<name>` (the `Work`/`-ReuseDefaultForWork` profile already
   uses `%APPDATA%\Claude`, which is why it works out of the box). A data dir
   anywhere else makes Cowork fail with `VHDX file not found`.

2. **Only one Cowork VM can run at a time.** The Hyper-V compute system is *not*
   scoped per profile, so launching Cowork in a second profile while another's
   VM is running fails with `HYPERVISOR_SERVICE_ERROR` /
   *"identifier already exists"*. You can keep both **windows** open for chat, but
   the VM-backed workspace only runs in one profile at a time — quit (or stop the
   workspace of) the other profile first. The plain chat / login isolation that
   this tool provides is unaffected.

---

## How is this different from running the app twice?

The app enforces a single instance via the Chromium singleton lock, which is
tied to the data directory. Clicking the normal icon twice hits the same lock
and just focuses the open window. Giving each instance its own data directory
gives each its own lock — and its own account.

---

## Disclaimer

This is an unofficial community tool. It does not modify, repackage, or
redistribute the Claude app — it only launches the official, installed app with
a standard Chromium command-line flag. Use in accordance with Anthropic's terms.

---

## Tiếng Việt — Quickstart

Chạy **nhiều cửa sổ Claude Desktop cùng lúc trên Windows**, mỗi cái một tài
khoản (ví dụ *Công việc* và *Cá nhân*), đăng nhập/lịch sử/cài đặt tách biệt.

App chính thức chỉ cho 1 tài khoản và không mở cửa sổ thứ hai. Repo này lách
bằng cờ `--user-data-dir` của Chromium: mỗi thư mục dữ liệu khác nhau = một khoá
instance riêng = một cửa sổ + một tài khoản chạy song song.

```powershell
git clone https://github.com/vodongha/claude-desktop-clone.git
cd claude-desktop-clone
powershell -ExecutionPolicy Bypass -File scripts\Setup.ps1 -ReuseDefaultForWork
```

- Tạo 2 icon trên Desktop: **Claude (Work)** và **Claude (Personal)**.
- `-ReuseDefaultForWork`: icon Work dùng lại tài khoản đang đăng nhập (khỏi
  login lại). Icon Personal mở cửa sổ mới để đăng nhập tài khoản còn lại.
- Bấm lại icon → focus đúng cửa sổ của tài khoản đó (không mở trùng).

Muốn tách riêng cả **bộ nhớ Claude Code / Cowork** cho từng profile (mặc định
chỉ tách login, còn `~/.claude` thì dùng chung), trỏ `CLAUDE_CONFIG_DIR` qua
`-ConfigDir`:

```powershell
& .\scripts\Setup.ps1 -ConfigDir @{ Personal = "$env:USERPROFILE\.claude-personal" }
```

Gỡ: `scripts\Uninstall.ps1` (thêm `-RemoveData` để xoá luôn dữ liệu/đăng nhập).

Yêu cầu: Windows 10/11 + đã cài app Claude Desktop. Không cần quyền admin,
không cần Python.

---

## Contributing

`develop` is the integration branch; `master` is the stable, published state. Branch `feature/*`
or `bug/*` off `develop` and PR into `develop`; branch `hotfix/*` off `master` for urgent fixes.
Merging `develop → master` releases, and `sync-develop.yml` merges `master` back into `develop`.
CI runs PSScriptAnalyzer on every PR. See [CLAUDE.md](CLAUDE.md#git-workflow) for details.

## License

[MIT](LICENSE)

---

## Built with

[Claude Code](https://claude.ai/code) by Anthropic. 🤖
