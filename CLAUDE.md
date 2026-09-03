# CLAUDE.md

UT99 (v469) server-side mod: HWID-persistent player mutes. See `Readme.md` for
features, commands, and installation. This file orients future Claude sessions.

## Key Files

| File | Description |
|---|---|
| `PersistentMute/Classes/PersistentMuteMut.uc` | Main mutator (ServerActor): player tracking, ACE HWID polling via `IACECheck`, mute application, all `!pm` admin-command logic (incl. offline mute via HWID-shape detection + seen-cache fallback), lazy-spawns the Nexgen plugin |
| `PersistentMute/Classes/PersistentMutePlugin.uc` | NexgenPlugin — the ONLY code that sees chat on a Nexgen server; blocks muted senders and routes `!pm` commands (dedupes Nexgen's per-receiver hook calls) |
| `PersistentMute/Classes/PersistentMuteStore.uc` | Persistence layer: pipe-delimited mute records (7 fields incl. optional reason) + last-seen cache (`Seen=`, cap 200) in `System\PersistentMute.ini`; auto-expiry, alias tracking |
| `PersistentMute/PersistentMute.u` | Latest compiled package (deploy this to the server's `System` dir) |
| `PersistentMute Development Log.md` | Chronological build/debug history of the project |
| `Readme.md` | User-facing documentation |
| `server.log` | Captured live server log from testing — contains real player HWIDs/IPs; gitignored, do not commit |

## Build

Local UT install: `C:\UnrealTournament\`

1. Copy `PersistentMute\Classes\*.uc` from this project to `C:\UnrealTournament\PersistentMute\Classes\` — **always copy before compiling**; a stale install copy silently builds old code.
2. Delete `C:\UnrealTournament\System\PersistentMute.u` (UCC skips already-built packages).
3. `cd C:\UnrealTournament\System && UCC.exe make`
4. Copy the fresh `.u` back to `PersistentMute\` in this project.

`EditPackages` order in the local `UnrealTournament.ini` (~line 480): `IACEv14` and `Nexgen112N` must both appear **above** `PersistentMute`.

## Hard-won constraints (do not rediscover these)

- **Nexgen owns chat.** Standard `MutatorBroadcastMessage` never fires on this server, even as head BaseMutator. Chat interception must be a registered Nexgen plugin. `ModifyPlayer` does reach a normal mutator.
- **Nexgen routes spectator chat differently from live-player chat, and doesn't strip its own prefix.** Live-player `Say`/`TeamSay` arrives via `MutatorTeamMessage` with the raw message text. Spectator chat arrives via `MutatorBroadcastMessage` with Nexgen's own `"PlayerName:"` prefix still on the front (confirmed by reading decompiled `NexgenController.uc`, `MutatorBroadcastMessage`) — Nexgen never strips it before calling plugins. Any chat-prefix command match (e.g. `!pm `) must detect `sender.IsA('Spectator')` and strip that prefix first, or it silently never matches for spectators.
- **UT99 dynamic arrays never auto-grow** on `Arr[Arr.Length] = X` (that's UT2004+). Use `Arr.Insert(Arr.Length, 1); Arr[Arr.Length-1] = X;` — this bug bit twice (`Tracked`, `Records`).
- **ACE HWID**: read the per-player `IACEv14.IACECheck` actor (`A.PlayerID == PRI.PlayerID` → `A.HWHash`). ACE validates asynchronously, so the first polls return "" — keep polling. The event-handler (`IACEEventHandler`) approach is a dead end on ACEv13p/v14e. The IACE package name is baked into the compiled `.u` via the typed `class'IACEvNN.IACECheck'` literal — a future ACE major-version bump requires retargeting this literal (and `EditPackages`) or the whole package fails to load silently.
- **UCC.exe quirks**: no ternary inside `$`-concatenation, no `Class.Package`, no `NotifyEndGame` on Mutator (poll `Level.Game.bGameEnded` from `Timer()`), ASCII-only string literals, `AddMutator` is a `Mutator` member not `GameInfo`.
- **ServerActor registration**: the mod loads via `ServerActors=` (listed above Nexgen) and splices itself in as head BaseMutator in `PostBeginPlay` (the `?mutator=` list claims BaseMutator before ServerActors run, so prepend, don't append).

## Deployment target

NFOservers-hosted UT99 v469e DM server. `PersistentMute.u` is server-side only —
never add it to `ServerPackages` or the `?mutator=` line (ServerActors only).
The live server's `-log=server.log` **overwrites on restart** and is 32KB
block-buffered; to capture recent lines, play through a map change first.
