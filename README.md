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

### Giving the shortcut the Claude icon (optional)

Generate an icon file **once** from the installed package, then point the
shortcut at that file:

```powershell
Add-Type -AssemblyName System.Drawing
$src = Join-Path (Get-AppxPackage -Name 'Claude').InstallLocation 'assets\Square150x150Logo.scale-200.png'
$img = [System.Drawing.Image]::FromFile($src); $out = "$PWD\claude-switcher.ico"
$pngs = @(); foreach ($s in 256,48,32,16) {
  $b = New-Object System.Drawing.Bitmap($s,$s); $g = [System.Drawing.Graphics]::FromImage($b)
  $g.InterpolationMode='HighQualityBicubic'; $g.DrawImage($img,0,0,$s,$s); $g.Dispose()
  $ms = New-Object System.IO.MemoryStream; $b.Save($ms,[System.Drawing.Imaging.ImageFormat]::Png)
  $pngs += ,@($s,$ms.ToArray()); $b.Dispose(); $ms.Dispose()
}
$img.Dispose(); $fs=[System.IO.File]::Create($out); $bw=New-Object System.IO.BinaryWriter($fs)
$bw.Write([uint16]0);$bw.Write([uint16]1);$bw.Write([uint16]$pngs.Count); $off=6+16*$pngs.Count
foreach($p in $pngs){ $d = if($p[0] -ge 256){0}else{$p[0]}
  $bw.Write([byte]$d);$bw.Write([byte]$d);$bw.Write([byte]0);$bw.Write([byte]0)
  $bw.Write([uint16]1);$bw.Write([uint16]32);$bw.Write([uint32]$p[1].Length);$bw.Write([uint32]$off);$off+=$p[1].Length }
foreach($p in $pngs){ $bw.Write($p[1]) }; $bw.Close(); $fs.Close()

$ws = New-Object -ComObject WScript.Shell
$s = $ws.CreateShortcut("$([Environment]::GetFolderPath('Desktop'))\Claude Account Switcher.lnk")
$s.IconLocation = "$out,0"; $s.Save()
```

**Do not point `IconLocation` at `claude.exe` inside `Program Files\WindowsApps`.**
That path contains the app's version number, so the next Claude update deletes it
and the shortcut silently reverts to a blank white page icon. The generated
`.ico` lives beside the scripts and survives updates. It is gitignored — it's
Anthropic's artwork, so generate it locally rather than committing it.

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
2. copies **every session you were working in** to the other account — not just
   the one that made the rejected request. A rate limit blocks the whole
   account, so any session touched in the last `-CarryOverMinutes` (default 60)
   comes across; the session that triggered the limit is always included
3. switches profiles (Claude closes)
4. relaunches through `claude://resume?session=<id>`, so the app opens straight
   into the conversation, then drops the copied entry if the app's own import
   succeeded
5. raises a Windows toast saying what happened and which account you're on now

The turn that hit the limit is lost — re-send it. If every account is limited it
stays put and toasts the earliest reset time.

Everything it sees goes to `%USERPROFILE%\.claude-profiles\autoswitch.log`.

### Start it from the shortcut, not from inside Claude

Launch the watcher from the **GUI's Start button**, the **Desktop shortcut**, or the
**login entry** — never from a shell hosted inside the Claude app itself.

A switch force-kills every `claude.exe` process. Anything launched *from* a
session inside Claude is owned by that session, so the switch can take the
watcher (or the GUI) down with it. The symptom is confusing: the app comes back
on the new account and looks fine, but the watcher is silently gone and nothing
is logged, because it was killed rather than exiting.

To check what owns a running watcher:

```powershell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*claude-autoswitch*' } |
  Select-Object ProcessId, ParentProcessId, CreationDate
```

A healthy watcher's parent is `explorer` (Desktop/login shortcut) or the GUI —
not `claude`.

### Reading the log

| Line | Meaning |
|---|---|
| `Watching N transcript(s). Live account: <uuid>` | a watcher **started**. `N` should be > 0 — `Watching 0` means it started blind |
| `alive - watching N transcript(s), on <uuid>` | heartbeat, every 30 min. Also the easiest way to see an account change |
| `New transcript: <file>` | a session created after the watcher started |
| `<type> limit hit on <uuid>... - cooling down until <time>` | a genuine rejection was detected |
| `DRY RUN: would switch to ...` | detected but not acting (dry run) |
| `Switched to <account>. Re-send your last message.` | failover completed |
| `resets in N min (< M) - waiting ...` | five-hour limit too short to be worth switching |
| `POSSIBLE FORMAT CHANGE ...` | a Claude API-error record no longer matches the known shape — run `selftest` |
| `watch-loop error (continuing): ...` | a transient error was survived, not fatal |
| `The switcher scripts changed on disk ...` | the running watcher is on stale code; restart it |

A gap in the heartbeats with no other line means the watcher was **killed**
(see above) rather than failing — it always logs its own errors.

To confirm a switch actually landed, don't rely on the log alone:

```powershell
.\claude-profile.ps1 whoami          # live account + matching profile
.\claude-profile.ps1 doctor          # paths, and any pending repair
```

## Keeping usage windows warm (optional)

A 5-hour window opens on **first use**, so if you start work at 09:00 your window
runs 09:00–14:00. Anchoring it earlier — while you're away — puts the window
boundaries where you want them during the working day, and means a second
account is ready to take over rather than starting cold.

Warming sends one tiny prompt per account, headlessly, using the bundled Claude
Code CLI:

```powershell
.\claude-autoswitch.ps1 warm-login personal      # one-time, per profile
.\claude-autoswitch.ps1 warm-login work
.\claude-autoswitch.ps1 warm-status              # what it would do; spends nothing
.\claude-autoswitch.ps1 warm-now personal        # prime one account immediately
```

Then enable it on the watcher:

```powershell
.\claude-autoswitch.ps1 install-startup -IncludeFiveHour -WarmWindows
```

**It only fires when all of these hold:**

- you've been idle for `-WarmIdleMinutes` (default 20; `0` disables the gate)
- that account's window is actually **closed** — no activity for 5 hours, so
  warming achieves something rather than being a no-op
- the account isn't rate limited
- at least `-WarmStaggerMinutes` (default 150) since the last account was warmed,
  so the two windows don't open *and expire* together

Because the windows are staggered, when the first account runs dry mid-morning
the second still has hours left on its window.

### Why this doesn't touch your credentials

Each account gets its own CLI config directory under `%USERPROFILE%\.claude-cli\`
via `CLAUDE_CONFIG_DIR`. That means:

- **No credential is ever read, copied or moved by this tool.** Each account's
  CLI credentials are created by Claude Code's own login and stay put; nothing
  enters the profile store and the switch set is unchanged.
- **No account switching to warm.** The CLI acts as whichever account we point
  it at regardless of which account the desktop app is on, so warming never
  closes the app or interrupts what you're doing.
- **No keystroke or focus automation.** It's a headless process, so it works
  whether the desktop is idle, locked or asleep.
- Warm sessions live in the isolated config directory, so they don't clutter
  your real session list and the watcher can't mistake them for activity.

Note the weekly windows are per-model (`seven_day_opus`, `seven_day_sonnet`), so
`-WarmModel` with a cheaper model may not anchor the window you actually care
about. Left unset it uses the CLI default.

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

## Robustness

Switching mutates a live credential store the app doesn't know is being touched,
so the tool guards the failure modes that come with that:

- **One switch at a time.** A cross-process lock stops the watcher and a manual
  switch from mutating the same files at once (which could corrupt the store).
- **Crash recovery.** A switch that dies mid-copy (power loss, killed process)
  is detected at next launch and repaired by re-applying the target profile,
  which stays intact in the store. `doctor` shows a pending repair.
- **Integrity checks.** A profile is only "ok" if its `config.json` parses with
  an account UUID and its cookie DB is non-empty — not merely that files exist.
- **Format-drift tripwire.** If a rate-limit line appears that the watcher
  doesn't recognise (e.g. after an app update changes the record), it warns and
  toasts instead of going silently blind. `selftest` proves the detector still
  works on demand.
- **Dead-session check.** After a switch it confirms the app stayed on the new
  account; if a saved session has expired it says so rather than looping.
- **Large-session guard.** Very large transcripts skip the resume deep link (it
  rewrites the file) and relaunch normally instead.
- **Heartbeat.** The watcher logs an "alive" line periodically, so a hung one is
  visible in the log rather than looking healthy.

None of this removes the underlying fragility below — it makes the failures
loud and recoverable instead of silent.

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
  app update. The format-drift tripwire makes that loud rather than silent, but
  it can only warn *after* an unrecognised limit line appears — run `selftest`
  after any Claude update to confirm the detector still works.
- **A saved session can still go stale.** If you sign into an account directly in
  the app (not through this tool) it rotates that account's token, leaving the
  saved profile's token dead until you re-save. Refresh tokens also expire with
  age. The dead-session check catches this after a switch, but the fix is to
  re-save the profile while signed into it.

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

.\claude-autoswitch.ps1 status|test|selftest|reset
.\claude-autoswitch.ps1 warm-status|warm-login <profile>|warm-now <profile>
.\claude-autoswitch.ps1 run [-DryRun] [-IncludeFiveHour] [-MinFiveHourWaitMinutes N] [-CarryOverMinutes N]
.\claude-autoswitch.ps1 stop
.\claude-autoswitch.ps1 install-startup [-DryRun] [-IncludeFiveHour] [-MinFiveHourWaitMinutes N] [-CarryOverMinutes N]
.\claude-autoswitch.ps1 uninstall-startup
```

`doctor` prints resolved paths and whether each source file is readable — start
there if something doesn't work.

## Credits

Inspired by [claude-swap](https://github.com/realiti4/claude-swap), which does
this properly for the CLI.
