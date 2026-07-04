# PersistentMute

A server-side mute mod for Unreal Tournament 1999 (v469) that **persists across map changes, reconnects, and server restarts**. Mutes are keyed to a player's hardware ID (HWID) supplied by [ACE](https://www.utgl.net/ACE) — changing name, IP, or reinstalling the game does not evade a mute.

Built for servers running **Nexgen 112N** and **ACE v1.3p**. No client-side download required.

## Features

- **HWID-based mutes** — sourced live from ACE's per-player check actor; survives name/IP changes
- **Three mute durations** — permanent, until a calendar date, or for a number of games
- **Persistent** — records are written to `System\PersistentMute.ini` on the server and reapplied automatically when the player returns
- **Silent blocking** — other players never see the muted player's chat; the muted player gets a private notice stating their mute duration
- **In-chat admin commands** — no console access needed; gated by Nexgen's *Moderate* right
- **Auto-expiry** — date mutes clear once the date passes; game-count mutes tick down each time a match ends

## Admin commands

Type in normal chat (requires the Nexgen **R_Moderate** right, right code "G"):

| Command | Effect |
|---|---|
| `!pm mute <name> forever` | Permanent mute |
| `!pm mute <name> until YYYY-MM-DD` | Mute until the given date (inclusive) |
| `!pm mute <name> games N` | Mute for the next N completed games |
| `!pm mute-hwid <HWID> forever\|until YYYY-MM-DD\|games N` | Mute a raw HWID (works for offline players) |
| `!pm unmute <name>` | Lift a mute by player name (player must be online) |
| `!pm unmute-hwid <HWID>` | Lift a mute by HWID (works for offline players) |
| `!pm list` | List all active mute records |

`<name>` is a case-insensitive substring match against connected players. Commands are never broadcast — only the issuing admin sees the response.

The muted player sees, on being muted / on joining / on any blocked chat line:
- `You are muted on this server forever`
- `You are muted on this server until YYYY-MM-DD.`
- `You are muted on this server for N games`

## Requirements

- UT99 dedicated server v469 (tested on v469e)
- **Nexgen 112N** running as a ServerActor (chat interception is done via a Nexgen plugin — plain mutator chat hooks never fire on a Nexgen server)
- **ACE v1.3p** with the `IACEv13` package (provides the HWID)

Note: HWIDs are unavailable for clients running under Wine/Linux (ACE reports `bWine`); those players cannot be HWID-muted.

## Installation

1. Copy `PersistentMute.u` to the server's `System` directory. No client package download is needed (server-side only).
2. Add to `ServerActors` in the server's `UnrealTournament.ini`, **above** the Nexgen line:
   ```ini
   ServerActors=PersistentMute.PersistentMuteMut
   ServerActors=Nexgen112N.NexgenActor
   ```
3. Make sure `PersistentMute.PersistentMuteMut` is **not** also listed in the `?mutator=` command line (it would double-spawn).
4. Restart the server. Nexgen's log will show `Loading PersistentMute 1.0...` when the plugin registers.

Mute records live in `System\PersistentMute.ini` on the server (created on first mute). Each record is a pipe-delimited string: `HWID|PlayerName|MuteType|ExpiryValue|AdminName|DateAdded`.

## Building from source

Compiled with the stock UT99 v469 `UCC.exe`:

1. Copy the `PersistentMute\Classes\*.uc` sources into `<UT>\PersistentMute\Classes\`.
2. In `<UT>\System\UnrealTournament.ini`, ensure these lines appear in `[Editor.EditorEngine]`, in this order (both dependency packages must be present in `System`):
   ```ini
   EditPackages=IACEv13
   EditPackages=Nexgen112N
   EditPackages=PersistentMute
   ```
3. Delete any existing `System\PersistentMute.u`, then run `UCC.exe make` from the `System` directory.

## How it works

- **`PersistentMuteMut`** (Mutator, loaded as a ServerActor) tracks joining players via `ModifyPlayer`, polls ACE's per-player `IACECheck` actor every 2 seconds until a HWID is returned, and applies any stored mute. It also hosts all admin-command and persistence logic, and lazy-spawns the Nexgen plugin once `NexgenController` exists.
- **`PersistentMutePlugin`** (NexgenPlugin) is the only component that actually sees chat — Nexgen owns the chat path on servers where it runs, so blocking happens in the plugin's `mutatorTeamMessage` / `mutatorBroadcastMessage` hooks. It defers all decisions to the mutator.
- **`PersistentMuteStore`** (Info, `config(PersistentMute)`) owns the record array and `SaveConfig()` persistence, including auto-expiry of date and game-count mutes.

## Credits

Written by perdition007, with Claude Code. Chat interception approach and ACE HWID integration worked out against Nexgen 112N and ACE v1.3p on a live NFOservers UT99 v469e instagib server.
