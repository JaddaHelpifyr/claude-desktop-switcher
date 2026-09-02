# Claude Desktop Account Switcher (Windows)

Keep two Claude accounts signed in at once and switch between them without
re-authenticating. Optionally fail over automatically when one hits its rate
limit, carrying the conversation across.

Built for the **Claude desktop app on Windows**. If you use the Claude Code CLI
instead, use [claude-swap](https://github.com/realiti4/claude-swap) — it targets
the CLI and VS Code extension, does far more, and is cross-platform. This project
exists because the desktop app stores its auth differently and claude-swap
doesn't reach it.

---

## What it does

- **Switch accounts in ~1 second**, no re-login
- **Move a conversation between accounts** and continue it where you left off
- **Watch for rate limits** and fail over automatically when one is exhausted
- **A GUI**, so none of this needs a terminal

## Requirements

- Windows 10 or 11
- Claude desktop app, **MSIX/Store build** (the one that installs to
  `Program Files\WindowsApps`). A standalone-installer build won't work — paths
  and relaunch differ.
- Windows PowerShell 5.1 (ships with Windows)
- Two Claude accounts, each with its own subscription

## Install

Put all five files in one folder, e.g. `Documents\claude-switcher`:

```
claude-switcher-gui.ps1     the GUI
claude-profile.ps1          account switching
claude-sessions.ps1         moving conversations
claude-autoswitch.ps1       rate-limit watcher
README.md
```

They must stay together — the GUI resolves the others relative to itself.

Then, in PowerShell:

```powershell
cd path\to\claude-switcher
powershell -ExecutionPolicy Bypass -STA -File .\claude-switcher-gui.ps1
```

Make a Desktop shortcut so you never type that again:

```powershell
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut("$([Environment]::GetFolderPath('Desktop'))\Claude Account Switcher.lnk")
$lnk.TargetPath = (Get-Command powershell.exe).Source
$lnk.Arguments  = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PWD\claude-switcher-gui.ps1`""
$lnk.WorkingDirectory = "$PWD"
$lnk.Save()
```

## First run

1. Open the GUI while signed into your **first** account
2. **Accounts** tab → *Save current as…* → name it (e.g. `personal`)
3. *Set label…* → your email, so you can tell them apart
4. *Add account…* → follow the prompts: it opens Claude, you log out and sign in
   as the second account, then it saves that one too

After that, **double-click an account to switch to it**.

## Auto-switching (optional)

On the **Auto-switch** tab:

- **Dry run** — detect and log, never switch. *Leave this on until you've seen it
  fire correctly once.*
- **Also switch on 5-hour limits** — off by default; it spends the other
  account's weekly budget to skip a wait. When on, it only switches if the
  window resets more than **N minutes** away (default 30) — a limit that clears
  in ten minutes is cheaper to wait out.
- **Start watcher** / **Stop watcher** — run it now
- **Run on login** — install a Startup entry so it runs hidden at every login

When a limit is hit, the watcher:

1. records the account's cooldown from `resetsAt`
2. copies the session's index entry to the other account
3. switches profiles (Claude closes)
4. relaunches through `claude://resume?session=<id>`, so the app opens straight
   into the conversation, then drops the copied entry if the app's own import
   succeeded
5. raises a Windows toast saying what happened and which account you're on now

The turn that hit the limit is lost — re-send it. If every account is limited it
stays put and toasts the earliest reset time.

Everything it sees goes to `%USERPROFILE%\.claude-profiles\autoswitch.log`.

## How it works

Your login lives in six places. Switching accounts swaps all six and restarts
the app:

| Path | Holds |
|---|---|
| `%APPDATA%\Claude\config.json` | `oauth:tokenCacheV2`, `lastKnownAccountUuid` |
| `%APPDATA%\Claude\Local State` | DPAPI-wrapped AES key for the cookies |
| `%APPDATA%\Claude\Network\` | cookie database |
| `%APPDATA%\Claude\Local Storage\` | web session state |
| `%APPDATA%\Claude\Session Storage\` | web session state |
| `%USERPROFILE%\.claude.json` | Claude Code CLI config |

Profiles are saved under `%USERPROFILE%\.claude-profiles\<name>\`.

Two things worth knowing:

**Conversation transcripts are already shared between accounts.** They live in
`%USERPROFILE%\.claude\projects\<project>\<cliSessionId>.jsonl`, which is not
account-scoped. Only the *session index* under
`%APPDATA%\Claude\claude-code-sessions\<accountUuid>\<orgUuid>\` is per-account.
So moving a conversation copies one small JSON file — the history itself never
moves, and both accounts read the same file.

**Rate-limit detection is reactive.** Claude Code writes a `quotaLimits` record
into the session transcript when a request is refused:

```json
{"status":"rejected","resetsAt":1788223800,"rateLimitType":"seven_day"}
```

That's the only local signal — nothing on disk reports how much of your quota is
spent, so a limit can only be seen *after* a request is refused. The turn that
triggers it is lost and must be re-sent after the switch.

## Limitations

- **Windows only.** Cookie encryption is DPAPI-bound.
- **Profiles are not portable.** They only decrypt for the same Windows user on
  the same machine, so they can't be exported, synced, or backed up elsewhere.
- **MSIX builds only.**
- **One account at a time.** The desktop app has no multi-account support —
  `lastKnownAccountUuid` is singular. This swaps the whole session; it doesn't
  run two at once.
- **Switching closes the app.** About a second, plus relaunch.
- **The app's own account menu switches only the Chat/Cowork session**, not
  Claude Code. They authenticate separately. Use a full Log out to move both.
- Detection matches a private, undocumented record shape and could break with an
  app update. It fails loudly rather than silently.

## A note on rate limits

Automated failover to a second account when the first is exhausted is plausibly
the kind of thing Anthropic's policy language about circumventing rate limits is
aimed at. Two accounts you pay for, each used within its own limits, isn't
fraud — but the automation is the part that reads as evasion rather than "I have
a work account and a personal one."

Manual switching is far less ambiguous. Auto-switching is opt-in and ships in dry
run for that reason. Your call.

## Commands

The GUI covers everything, but each script runs standalone:

```powershell
.\claude-profile.ps1 list|whoami|doctor
.\claude-profile.ps1 switch <name>
.\claude-profile.ps1 save <name>
.\claude-profile.ps1 label <name> <text>
.\claude-profile.ps1 rename <old> <new>
.\claude-profile.ps1 delete <name>

.\claude-sessions.ps1 accounts
.\claude-sessions.ps1 list <account>
.\claude-sessions.ps1 copy <sessionId> <account>

.\claude-autoswitch.ps1 status|test|reset
.\claude-autoswitch.ps1 run [-DryRun] [-IncludeFiveHour] [-MinFiveHourWaitMinutes N]
.\claude-autoswitch.ps1 stop
.\claude-autoswitch.ps1 install-startup [-DryRun] [-IncludeFiveHour] [-MinFiveHourWaitMinutes N]
.\claude-autoswitch.ps1 uninstall-startup
```

`doctor` prints resolved paths and whether each source file is readable — start
there if something doesn't work.

## Credits

Inspired by [claude-swap](https://github.com/realiti4/claude-swap), which does
this properly for the CLI.
