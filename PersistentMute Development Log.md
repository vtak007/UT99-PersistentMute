---
tags:
  - UT99
  - UnrealScript
  - modding
  - PersistentMute
  - development-log
created: 2026-07-01
status: in-progress
project: PersistentMute
---

# PersistentMute — Development Log

## Project Overview

A server-side UT99 mutator that permanently mutes players across map changes and server restarts, keyed to the **ACE v1.3p hardware ID (HWID)** rather than name or IP. Three mute duration modes: permanent, until a specified date, or for N games.

**Server environment:**
- Unreal Tournament 1999 v469e — Deathmatch
- Hosted on NFOservers VPS
- IG+ (`InstaGibPlus_master-3e878ccf`)
- ACE v1.3p (`ACEv13p_S`, `ACEv13p_EH`, `ACEv13p_C`, `IACEv13`)
- Nexgen112N (admin/management mod — loads as ServerActor)

**Source location (local):**
```
D:\Dropbox\Computing1\BatchFiles_Scripts\Claude Projects\UT99 PersistentMute\
  PersistentMute\
    Classes\
      PersistentMuteStore.uc
      PersistentMuteMut.uc
```

**UT install for compiling:** `C:\UnrealTournament\`
**Compile command:** `cd C:\UnrealTournament\System && UCC.exe make`
**Output:** `C:\UnrealTournament\System\PersistentMute.u`

---

## Architecture

Two classes in one package:

| Class | Role |
|---|---|
| `PersistentMuteStore` | Config persistence — reads/writes `System\PersistentMute.ini` via `SaveConfig()`. Survives map changes and server restarts. |
| `PersistentMuteMut` | Main mutator — hooks chat, tracks players, polls ACE for HWIDs, handles admin commands. |

### Record Format

Mute records stored in `PersistentMute.ini` as pipe-delimited strings:

```
[0]HWID | [1]PlayerName | [2]MuteType | [3]ExpiryValue | [4]AdminName | [5]DateAdded
```

| MuteType | ExpiryValue |
|---|---|
| 0 = Permanent | `"0"` |
| 1 = Until date | `"YYYY-MM-DD"` |
| 2 = Games remaining | integer string |

### Admin Commands (type in chat — requires `bAdmin=true`)

```
!pm mute <name> forever
!pm mute <name> until YYYY-MM-DD
!pm mute <name> games N
!pm mute-hwid <HWID> forever|until YYYY-MM-DD|games N
!pm unmute <name>
!pm unmute-hwid <HWID>
!pm list
!pm debug-ace
```

> [!note] Why chat prefix instead of `mutate`?
> Nexgen intercepts the UT99 `Mutate` command chain and does not forward it. Admin commands are routed through `MutatorBroadcastMessage` using the `!pm` chat prefix instead. The `!pm` prefix is silently stripped and never appears in public chat.

### HWID Source — ACE v1.3p

ACE validates players asynchronously after they join. The mutator polls every 2 seconds via `Timer()` using `QueryACEHWID()`, which uses `GetPropertyText()` for dynamic property access — **no compile-time dependency on the ACE package.**

---

## Design Decisions

### Silent mute
Muted players receive a private `ClientMessage` only. Other players see nothing. This prevents the muted player from knowing exactly when to switch accounts.

### HWID async timing
ACE doesn't validate instantly. Players are tracked in a `Tracked[]` array with `bConfirmed=false` until ACE returns a HWID. Chat is allowed during this window (typically 5–10 seconds). Once confirmed, `ApplyMuteCheck()` runs and applies the mute if the HWID is in the store.

### Game-end detection
`NotifyEndGame` does not exist on the `Mutator` base class in UT99. Game end is detected by polling `Level.Game.bGameEnded` in `Timer()` with a `bGameEndProcessed` guard flag.

### Date handling
`Level.Year`, `Level.Month`, `Level.Day` are native fields on `LevelInfo` in UT99. `TodayStr()` builds a `YYYY-MM-DD` string from these for ISO date comparison. String comparison works correctly for ISO dates (`"2026-09-01" <= "2026-12-31"`).

### Nexgen chain workaround
Nexgen loads as a `ServerActor` and calls `Level.Game.AddMutator(self)` in `PostBeginPlay`, becoming `BaseMutator`. It does **not** forward `ModifyPlayer` or `MutatorBroadcastMessage` to `NextMutator`. Any mutator in `?mutator=` sits behind Nexgen and receives nothing.

**Fix:** Load PersistentMute as a `ServerActor` listed **before** Nexgen in `[Engine.GameEngine]`. `PostBeginPlay` calls `Level.Game.AddMutator(self)` explicitly, making PersistentMute `BaseMutator` before Nexgen registers. PersistentMute must be **removed** from `?mutator=` to prevent double-spawning.

---

## Compilation Errors Encountered & Fixes

### Error 1 — Type mismatch in ternary
```
PersistentMuteMut.uc(472) : Error, Type mismatch in '='
```
**Cause:** UT99's UCC cannot resolve the result type of `("0"$Level.Month)` vs `string(Level.Month)` in a ternary expression inside a `$` chain.

**Fix:** Replace ternary with `if/else`:
```unrealscript
// BAD
M = (Level.Month < 10) ? ("0"$Level.Month) : string(Level.Month);

// GOOD
if (Level.Month < 10) M = "0"$Level.Month;
else                  M = string(Level.Month);
```

### Error 2 — NotifyEndGame not on Mutator
```
PersistentMuteMut.uc(174) : Error, Unrecognized member 'NotifyEndGame' in class 'Mutator'
```
**Cause:** `NotifyEndGame` is not a member of the `Mutator` base class in UT99.

**Fix:** Poll `Level.Game.bGameEnded` in `Timer()` with a guard flag:
```unrealscript
var bool bGameEndProcessed;

function Timer()
{
    if (Level.Game != None && Level.Game.bGameEnded && !bGameEndProcessed)
    {
        bGameEndProcessed = true;
        ProcessGameEnd();
    }
    // ...
}
```

### Error 3 — Class.Package not valid
```
PersistentMuteMut.uc(417) : Error, Unrecognized member 'Package' in class 'Class'
```
**Cause:** `Package` is not exposed on the `Class` object in UT99's UnrealScript.

**Fix:** Use `A.Class.Name` only (package info not needed for class identification).

### Error 4 — Missing ')' in expression
```
PersistentMuteMut.uc(69) : Error, Missing ')' in expression
```
**Cause:** Complex expression inside `log()` — a ternary operator used within a `$`-concatenated log string.

**Fix:** Extract to a local variable first:
```unrealscript
// BAD
log("HasPlayer="$(PP != None ? string(PP.Player != None) : "N/A"));

// GOOD
local string HasPlayer;
if (PP != None && PP.Player != None) HasPlayer = "true";
else HasPlayer = "false";
log("HasPlayer="$HasPlayer);
```

### Warning — Non-ASCII characters in string literals
```
Warning, Found a string constant that contains non-ascii characters
```
**Cause:** Em dashes (—) used inside `ClientMessage` string literals.

**Fix:** Replace all em dashes in quoted strings with plain hyphens (`-`). Em dashes in `//` comments are harmless.

---

## Debugging Journey

### Attempt 1 — `mutate PM debug-ace`
No response at all. Established that Nexgen intercepts the `Mutate` chain.

### Attempt 2 — `!pm debug-ace` in chat
No response. Established that `MutatorBroadcastMessage` also not being called.

### Attempt 3 — `PM_DEBUG` log lines in PostBeginPlay
**Result:** `PostBeginPlay fired` and `Store spawned OK` appeared. Confirmed the mutator IS running and initialising correctly.

**But:** No `ModifyPlayer` or `MutatorBroadcastMessage` log lines appeared even after joining and chatting.

**Conclusion:** Nexgen is `BaseMutator` and does not forward these callbacks. All `?mutator=` entries sit silently behind it.

### Root cause identified
Nexgen is in `[Engine.GameEngine]` as `ServerActors=Nexgen112N.NexgenActor`. ServerActors fire `PostBeginPlay` before `GameInfo.InitGame` processes the `?mutator=` URL parameter. Nexgen calls `Level.Game.AddMutator(self)` in `PostBeginPlay` and becomes `BaseMutator` before any command-line mutators are even spawned.

### Fix applied (awaiting deployment)
Added `Level.Game.AddMutator(self)` to `PersistentMuteMut.PostBeginPlay`. Server config must add `ServerActors=PersistentMute.PersistentMuteMut` directly before `ServerActors=Nexgen112N.NexgenActor`, and remove PersistentMute from `?mutator=`.

---

## Server Configuration Notes

### NFO Server Start Command (current)
```
DM-Codex.unr?game=Botpack.DeathMatchPlus?MaxPlayers=12?mutator=MVU3.BDBMapVote,
NoInvisibility.NoInvisibility,NoUDamage.NoUDamage,WhoPushedMe.WhoPushedMe,
flames.mut,HiddenAdmin.HiddenAdmin,InstaGibPlus_master-3e878ccf.UTpure,
InstaGibPlus_master-3e878ccf.ST_Mutator,InstaGibPlus_master-3e878ccf.InstaGib,
InstaGibPlus_master-3e878ccf.IGPlus_HitFeedback,MatchLogger.MatchLogger,
PersistentMute.PersistentMuteMut
```

### Required change to start command
Remove `,PersistentMute.PersistentMuteMut` from the end.

### Required change to `[Engine.GameEngine]`
```ini
; ADD this line directly above the Nexgen line:
ServerActors=PersistentMute.PersistentMuteMut
ServerActors=Nexgen112N.NexgenActor        ; existing
```

### Do NOT add to ServerPackages
`ServerPackages` is for packages clients must download. PersistentMute is server-side only — no client downloads needed. Adding it to `ServerPackages` caused the server to fail to boot.

---

## Resume Checklist

- [ ] **Step 1** — Recompile: copy updated `.uc` to `C:\UnrealTournament\PersistentMute\Classes\`, delete old `.u`, run `UCC.exe make`
- [ ] **Step 2** — Upload fresh `PersistentMute.u` to NFO server
- [ ] **Step 3** — Add `ServerActors=PersistentMute.PersistentMuteMut` above Nexgen in `[Engine.GameEngine]`
- [ ] **Step 4** — Remove `PersistentMute.PersistentMuteMut` from `?mutator=` start command
- [ ] **Step 5** — Restart server. Verify log shows `PM_DEBUG ModifyPlayer` and `PM_DEBUG MutatorBroadcastMessage` lines
- [ ] **Step 6** — With player connected, type `!pm debug-ace` in chat. Check log for `PM_DEBUG actor class=` lines to identify ACE's HWID actor and property name
- [ ] **Step 7** — Update class name checks in `QueryACEHWID()` with confirmed ACE names. Recompile and redeploy
- [ ] **Step 8** — Remove all `PM_DEBUG` log lines from both `.uc` files. Final clean compile
- [ ] **Step 9** — End-to-end test: mute, reconnect, server restart, all three expiry types
- [ ] **Step 10** — Write `CLAUDE.md` and `Readme.md` after user sign-off

---

## Current Source Code

### PersistentMuteStore.uc

```unrealscript
// =============================================================================
// PersistentMuteStore.uc
// Config persistence layer for PersistentMute.
// Writes to System\PersistentMute.ini — survives map changes and restarts.
//
// Record format (pipe-delimited string):
//   [0] HWID         — ACE hardware ID (hex string)
//   [1] PlayerName   — display name at time of mute (informational)
//   [2] MuteType     — 0=Permanent, 1=Until date, 2=Games remaining
//   [3] ExpiryValue  — "0" | "YYYY-MM-DD" | integer string
//   [4] AdminName    — who issued the mute
//   [5] DateAdded    — YYYY-MM-DD when mute was created
// =============================================================================
class PersistentMuteStore extends Info config(PersistentMute);

var config array<string> Records;

// -----------------------------------------------------------------------------
//  Field extraction
// -----------------------------------------------------------------------------

function string GetField(string Rec, int Idx)
{
    local int i;
    local string R;

    R = Rec;
    for (i = 0; i < Idx; i++)
    {
        if (InStr(R, "|") < 0) return "";
        R = Mid(R, InStr(R, "|") + 1);
    }
    if (InStr(R, "|") >= 0)
        return Left(R, InStr(R, "|"));
    return R;
}

// -----------------------------------------------------------------------------
//  Index lookup — returns -1 if not found
// -----------------------------------------------------------------------------

function int FindIndex(string HWID)
{
    local int i;
    for (i = 0; i < Records.Length; i++)
        if (Caps(GetField(Records[i], 0)) == Caps(HWID))
            return i;
    return -1;
}

// -----------------------------------------------------------------------------
//  Write / delete
// -----------------------------------------------------------------------------

function SetMute(string HWID, string PlayerName, int MuteType,
                 string ExpiryVal, string AdminName, string DateStr)
{
    local int Idx;
    local string Rec;

    Rec = HWID$"|"$PlayerName$"|"$MuteType$"|"$ExpiryVal$"|"$AdminName$"|"$DateStr;
    Idx = FindIndex(HWID);
    if (Idx >= 0)
        Records[Idx] = Rec;
    else
        Records[Records.Length] = Rec;
    SaveConfig();
}

function bool Unmute(string HWID)
{
    local int Idx;
    Idx = FindIndex(HWID);
    if (Idx < 0) return false;
    Records.Remove(Idx, 1);
    SaveConfig();
    return true;
}

// -----------------------------------------------------------------------------
//  Status check
//  Returns: 0=not muted, 1=permanent, 2=date-muted (active), 3=games-muted (active)
//  Auto-removes expired date records.
// -----------------------------------------------------------------------------

function int GetMuteStatus(string HWID, string TodayStr)
{
    local int Idx, MType;
    local string Expiry;

    Idx = FindIndex(HWID);
    if (Idx < 0) return 0;

    MType  = int(GetField(Records[Idx], 2));
    Expiry = GetField(Records[Idx], 3);

    switch (MType)
    {
        case 0:
            return 1;

        case 1:
            if (TodayStr <= Expiry) return 2;
            // Date passed — auto-clean
            Records.Remove(Idx, 1);
            SaveConfig();
            return 0;

        case 2:
            if (int(Expiry) > 0) return 3;
            Records.Remove(Idx, 1);
            SaveConfig();
            return 0;
    }
    return 0;
}

// -----------------------------------------------------------------------------
//  Decrement game count for one HWID.
//  Returns true if the mute just expired (record has been removed).
// -----------------------------------------------------------------------------

function bool TickGames(string HWID)
{
    local int Idx, Left;
    local string Rebuilt;

    Idx = FindIndex(HWID);
    if (Idx < 0)                               return false;
    if (GetField(Records[Idx], 2) != "2")      return false;

    Left = int(GetField(Records[Idx], 3)) - 1;
    if (Left <= 0)
    {
        Records.Remove(Idx, 1);
        SaveConfig();
        return true;
    }

    Rebuilt = GetField(Records[Idx], 0) $"|"$
              GetField(Records[Idx], 1) $"|2|"$
              Left                      $"|"$
              GetField(Records[Idx], 4) $"|"$
              GetField(Records[Idx], 5);
    Records[Idx] = Rebuilt;
    SaveConfig();
    return false;
}

defaultproperties
{
    bHidden=True
}
```

### PersistentMuteMut.uc

```unrealscript
// =============================================================================
// PersistentMuteMut.uc
// Main mutator for PersistentMute.
//
// Features:
//   - HWID-based mutes sourced from ACE v1.3p (dynamic, no hard dependency)
//   - Three mute durations: permanent, until date, games remaining
//   - Survives map changes and server restarts via PersistentMute.ini
//   - Silent mute: blocked messages produce a private notice to sender only
//   - Admin commands via: mutate PM <command>
//
// Admin commands — type in chat (requires bAdmin=true):
//   !pm mute <name> forever
//   !pm mute <name> until YYYY-MM-DD
//   !pm mute <name> games N
//   !pm mute-hwid <HWID> forever|until YYYY-MM-DD|games N
//   !pm unmute <name>
//   !pm unmute-hwid <HWID>
//   !pm list
//   !pm debug-ace
// Note: Nexgen intercepts the Mutate chain so mutate PM commands are unreliable.
// =============================================================================
class PersistentMuteMut extends Mutator;

var PersistentMuteStore Store;

// Per-session player tracking (cleared on map change, rebuilt as players join)
struct PlayerEntry
{
    var PlayerPawn  Pawn;
    var string      HWID;
    var bool        bConfirmed;   // True once ACE has returned a HWID
    var bool        bMuted;
};
var array<PlayerEntry> Tracked;

// Seconds between HWID poll attempts (ACE validates async after player joins)
const POLL_INTERVAL = 2.0;

// Guards against processing the same game-end event more than once
var bool bGameEndProcessed;

// =============================================================================
//  Initialisation
// =============================================================================

function PostBeginPlay()
{
    log("PM_DEBUG PostBeginPlay fired");
    Store = Spawn(class'PersistentMute.PersistentMuteStore');
    if (Store == None)
        log("PM_DEBUG ERROR: PersistentMuteStore failed to spawn");
    else
        log("PM_DEBUG Store spawned OK");
    SetTimer(POLL_INTERVAL, true);
    Super.PostBeginPlay();

    // Self-register in the mutator chain when loaded as a ServerActor.
    // Must be listed before Nexgen in ServerActors so we become BaseMutator.
    if (Level.Game != None)
    {
        Level.Game.AddMutator(self);
        log("PM_DEBUG AddMutator called - PersistentMute should now be BaseMutator");
    }
    else
        log("PM_DEBUG ERROR: Level.Game is None at PostBeginPlay");
}

// =============================================================================
//  Player tracking
// =============================================================================

// ModifyPlayer fires each time a human pawn spawns/respawns.
// Human network players have a non-None Player reference; bots do not.
function ModifyPlayer(Pawn Other)
{
    local PlayerPawn PP;
    local string HasPlayer;

    PP = PlayerPawn(Other);
    if (PP != None && PP.Player != None)
        HasPlayer = "true";
    else
        HasPlayer = "false";
    log("PM_DEBUG ModifyPlayer: "$Other.Class.Name$" HasPlayer="$HasPlayer);

    if (PP != None && PP.Player != None)
        TrackPlayer(PP);

    if (NextMutator != None)
        NextMutator.ModifyPlayer(Other);
}

function TrackPlayer(PlayerPawn PP)
{
    local int i;
    local PlayerEntry E;

    // Deduplicate — ModifyPlayer fires on every respawn
    for (i = 0; i < Tracked.Length; i++)
        if (Tracked[i].Pawn == PP) return;

    E.Pawn       = PP;
    E.HWID       = "";
    E.bConfirmed = false;
    E.bMuted     = false;
    Tracked[Tracked.Length] = E;
}

// =============================================================================
//  Timer — HWID polling + stale entry cleanup
// =============================================================================

function Timer()
{
    local int i;
    local string H;

    // Detect game end — NotifyEndGame does not exist on Mutator in UT99
    if (Level.Game != None && Level.Game.bGameEnded && !bGameEndProcessed)
    {
        bGameEndProcessed = true;
        ProcessGameEnd();
    }

    for (i = Tracked.Length - 1; i >= 0; i--)
    {
        // Remove entries for players who have disconnected
        if (Tracked[i].Pawn == None || Tracked[i].Pawn.bDeleteMe)
        {
            Tracked.Remove(i, 1);
            continue;
        }

        if (!Tracked[i].bConfirmed)
        {
            H = QueryACEHWID(Tracked[i].Pawn);
            if (H != "")
            {
                Tracked[i].HWID       = H;
                Tracked[i].bConfirmed = true;
                ApplyMuteCheck(i);
            }
        }
    }
}

function ApplyMuteCheck(int Idx)
{
    local int Status;
    Status = Store.GetMuteStatus(Tracked[Idx].HWID, TodayStr());
    Tracked[Idx].bMuted = (Status > 0);

    if (Tracked[Idx].bMuted)
        Tracked[Idx].Pawn.ClientMessage(
            "[PersistentMute] You are muted on this server. Your chat is suppressed.");
}

// =============================================================================
//  Chat interception
// =============================================================================

function bool MutatorBroadcastMessage(Actor Sender, Pawn Receiver,
    out coerce string Msg, bool bTeamMessage, out name Type)
{
    local int i;
    local PlayerPawn PP;

    log("PM_DEBUG MutatorBroadcastMessage: Sender="$Sender.Class.Name$" Msg="$Msg);

    PP = PlayerPawn(Sender);
    if (PP != None)
    {
        // Admin commands via chat prefix !pm — never broadcast, always silent to others
        if (Caps(Left(Msg, 4)) == "!PM ")
        {
            if (PP.bAdmin)
                ProcessCommand(Mid(Msg, 4), PP);
            else
                PP.ClientMessage("[PM] Admin access required.");
            return false;
        }

        // Mute check — block chat from muted players
        for (i = 0; i < Tracked.Length; i++)
        {
            if (Tracked[i].Pawn == PP && Tracked[i].bMuted)
            {
                PP.ClientMessage("[PersistentMute] Your message was not sent. You are muted on this server.");
                return false;
            }
        }
    }

    if (NextMutator != None)
        return NextMutator.MutatorBroadcastMessage(Sender, Receiver, Msg, bTeamMessage, Type);
    return true;
}

// =============================================================================
//  Game-count tick on round end
//  Called from Timer() when Level.Game.bGameEnded transitions to true.
// =============================================================================

function ProcessGameEnd()
{
    local int i;

    for (i = 0; i < Tracked.Length; i++)
    {
        if (Tracked[i].bConfirmed && Tracked[i].bMuted)
        {
            if (Store.TickGames(Tracked[i].HWID))
            {
                Tracked[i].bMuted = false;
                Tracked[i].Pawn.ClientMessage("[PersistentMute] Your mute has expired. Chat restored.");
            }
        }
    }
}

// =============================================================================
//  Admin commands
// =============================================================================

function Mutate(string Str, PlayerPawn Sender)
{
    // Nexgen intercepts the Mutate chain so this may never fire.
    // Admin commands are handled via chat prefix !pm in MutatorBroadcastMessage.
    if (Caps(Left(Str, 3)) == "PM ")
    {
        if (!Sender.bAdmin)
            Sender.ClientMessage("[PM] Admin access required.");
        else
            ProcessCommand(Mid(Str, 3), Sender);
    }

    if (NextMutator != None)
        NextMutator.Mutate(Str, Sender);
}

function ProcessCommand(string Sub, PlayerPawn Admin)
{
    local string Cmd, A1, A2, A3;

    Cmd = Caps(GetWord(Sub, 0));
    A1  = GetWord(Sub, 1);
    A2  = Caps(GetWord(Sub, 2));
    A3  = GetWord(Sub, 3);

    switch (Cmd)
    {
        case "MUTE":        CmdMuteByName(Admin, A1, A2, A3);  break;
        case "MUTE-HWID":   CmdMuteByHWID(Admin, A1, A2, A3);  break;
        case "UNMUTE":      CmdUnmuteByName(Admin, A1);         break;
        case "UNMUTE-HWID": CmdUnmuteByHWID(Admin, A1);         break;
        case "LIST":        CmdList(Admin);                      break;
        case "DEBUG-ACE":   CmdDebugACE(Admin);                  break;
        default:
            Admin.ClientMessage("[PM] Commands (type in chat):");
            Admin.ClientMessage("  !pm mute <name> forever | until YYYY-MM-DD | games N");
            Admin.ClientMessage("  !pm mute-hwid <HWID> forever | until YYYY-MM-DD | games N");
            Admin.ClientMessage("  !pm unmute <name>  |  !pm unmute-hwid <HWID>  |  !pm list");
            Admin.ClientMessage("  !pm debug-ace  (dumps ACE actor info to server log)");
    }
}

function CmdMuteByName(PlayerPawn Admin, string Name, string DurType, string DurVal)
{
    local PlayerPawn Target;
    local string HWID;

    Target = FindByName(Name);
    if (Target == None)
    {
        Admin.ClientMessage("[PM] Player not found: "$Name);
        return;
    }

    HWID = HWIDFor(Target);
    if (HWID == "")
    {
        Admin.ClientMessage("[PM] HWID not yet available for "$Name$". Retry in a few seconds.");
        return;
    }

    DoMute(Admin, HWID, Target.PlayerReplicationInfo.PlayerName, DurType, DurVal, Target);
}

function CmdMuteByHWID(PlayerPawn Admin, string HWID, string DurType, string DurVal)
{
    local PlayerPawn Online;
    Online = FindByHWID(HWID);
    DoMute(Admin, HWID, "Unknown", DurType, DurVal, Online);
}

function DoMute(PlayerPawn Admin, string HWID, string PlayerName,
                string DurType, string DurVal, PlayerPawn Target)
{
    local int MType;
    local string ExpVal;

    switch (DurType)
    {
        case "FOREVER":
            MType  = 0;
            ExpVal = "0";
            break;

        case "UNTIL":
            MType  = 1;
            ExpVal = DurVal;
            if (ExpVal == "")
            {
                Admin.ClientMessage("[PM] Usage: PM mute <name> until YYYY-MM-DD");
                return;
            }
            break;

        case "GAMES":
            MType  = 2;
            ExpVal = DurVal;
            if (int(ExpVal) <= 0)
            {
                Admin.ClientMessage("[PM] Usage: PM mute <name> games N");
                return;
            }
            break;

        default:
            Admin.ClientMessage("[PM] Specify duration: forever | until YYYY-MM-DD | games N");
            return;
    }

    Store.SetMute(HWID, PlayerName, MType, ExpVal,
                  Admin.PlayerReplicationInfo.PlayerName, TodayStr());

    if (Target != None)
    {
        SetMuteState(Target, true);
        Target.ClientMessage("[PersistentMute] You have been muted by an admin.");
    }

    Admin.ClientMessage("[PM] Muted: "$PlayerName$" | HWID: "$HWID$" | "$DurType$" "$DurVal);
}

function CmdUnmuteByName(PlayerPawn Admin, string Name)
{
    local PlayerPawn Target;
    local string HWID;

    Target = FindByName(Name);
    if (Target == None) { Admin.ClientMessage("[PM] Player not found: "$Name); return; }

    HWID = HWIDFor(Target);
    if (HWID == "") { Admin.ClientMessage("[PM] HWID not available for "$Name); return; }

    if (Store.Unmute(HWID))
    {
        SetMuteState(Target, false);
        Target.ClientMessage("[PersistentMute] Your mute has been lifted.");
        Admin.ClientMessage("[PM] Unmuted: "$Target.PlayerReplicationInfo.PlayerName);
    }
    else
        Admin.ClientMessage("[PM] "$Name$" is not in the mute list.");
}

function CmdUnmuteByHWID(PlayerPawn Admin, string HWID)
{
    local PlayerPawn Online;
    Online = FindByHWID(HWID);

    if (Store.Unmute(HWID))
    {
        if (Online != None)
        {
            SetMuteState(Online, false);
            Online.ClientMessage("[PersistentMute] Your mute has been lifted.");
        }
        Admin.ClientMessage("[PM] Unmuted HWID: "$HWID);
    }
    else
        Admin.ClientMessage("[PM] HWID not found in mute list: "$HWID);
}

function CmdList(PlayerPawn Admin)
{
    local int i;
    local string Rec, TypeStr;

    if (Store.Records.Length == 0)
    {
        Admin.ClientMessage("[PM] No active mutes.");
        return;
    }

    Admin.ClientMessage("[PM] Active mutes ("$Store.Records.Length$"):");
    for (i = 0; i < Store.Records.Length; i++)
    {
        Rec = Store.Records[i];
        switch (int(Store.GetField(Rec, 2)))
        {
            case 0: TypeStr = "PERMANENT";                               break;
            case 1: TypeStr = "UNTIL "$Store.GetField(Rec, 3);          break;
            case 2: TypeStr = Store.GetField(Rec, 3)$" GAMES LEFT";     break;
            default: TypeStr = "UNKNOWN";
        }
        Admin.ClientMessage(
            "  ["$Store.GetField(Rec, 1)$"]"$
            " HWID:"$Store.GetField(Rec, 0)$
            " | "$TypeStr$
            " | By:"$Store.GetField(Rec, 4)$
            " | Added:"$Store.GetField(Rec, 5));
    }
}

// =============================================================================
//  ACE debug probe — run once after players have joined, then check server log
// =============================================================================

function CmdDebugACE(PlayerPawn Admin)
{
    local Actor A;
    local PlayerPawn PP;
    local int Count;

    Admin.ClientMessage("[PM] Scanning all actors for ACE - check server log for PM_DEBUG lines.");
    Count = 0;

    foreach AllActors(class'Actor', A)
    {
        if (InStr(Caps(string(A.Class.Name)), "ACE") >= 0)
        {
            log("PM_DEBUG actor class="$A.Class.Name
                $" Owner="$A.Owner
                $" HWID="$A.GetPropertyText("HWID")
                $" HardwareID="$A.GetPropertyText("HardwareID")
                $" PlayerID="$A.GetPropertyText("PlayerID")
                $" ClientID="$A.GetPropertyText("ClientID")
                $" PlayerName="$A.GetPropertyText("PlayerName"));
            Count++;
        }
    }

    foreach AllActors(class'PlayerPawn', PP)
    {
        if (PP.Player == None) continue;
        log("PM_DEBUG pawn="$PP.PlayerReplicationInfo.PlayerName
            $" pawn.HWID="$PP.GetPropertyText("HWID")
            $" pawn.HardwareID="$PP.GetPropertyText("HardwareID")
            $" pri.HWID="$PP.PlayerReplicationInfo.GetPropertyText("HWID")
            $" pri.HardwareID="$PP.PlayerReplicationInfo.GetPropertyText("HardwareID"));
    }

    Admin.ClientMessage("[PM] Found "$Count$" ACE-named actors. Results in server log.");
    if (Count == 0)
        Admin.ClientMessage("[PM] Zero ACE actors found - ACE may not be running or uses a different naming convention.");
}

// =============================================================================
//  ACE HWID query — dynamic property access, no hard dependency on ACE package
//  Update class name checks below once CmdDebugACE confirms actual names.
// =============================================================================

function string QueryACEHWID(PlayerPawn PP)
{
    local Actor A;
    local string H, PID;

    PID = string(PP.PlayerReplicationInfo.PlayerID);

    foreach AllActors(class'Actor', A)
    {
        if (A.Class.Name != 'ACEPlayerInfo' &&
            A.Class.Name != 'ACESvPlayer'   &&
            A.Class.Name != 'ACEInfo'        &&
            A.Class.Name != 'ACEClient')
            continue;

        // ---- Use !pm debug-ace to probe ACE class/property names ----

        if (A.Owner == PP ||
            A.GetPropertyText("PlayerID") == PID ||
            A.GetPropertyText("Player")   == PP.GetPropertyText("Name"))
        {
            H = A.GetPropertyText("HWID");
            if (H == "") H = A.GetPropertyText("HardwareID");
            if (H == "") H = A.GetPropertyText("ClientHWID");
            if (H != "") return H;
        }
    }
    return "";
}

// =============================================================================
//  Utility helpers
// =============================================================================

function PlayerPawn FindByName(string Name)
{
    local PlayerPawn P;
    foreach AllActors(class'PlayerPawn', P)
        if (InStr(Caps(P.PlayerReplicationInfo.PlayerName), Caps(Name)) >= 0)
            return P;
    return None;
}

function PlayerPawn FindByHWID(string HWID)
{
    local int i;
    for (i = 0; i < Tracked.Length; i++)
        if (Tracked[i].bConfirmed && Caps(Tracked[i].HWID) == Caps(HWID))
            return Tracked[i].Pawn;
    return None;
}

function string HWIDFor(PlayerPawn PP)
{
    local int i;
    for (i = 0; i < Tracked.Length; i++)
        if (Tracked[i].Pawn == PP && Tracked[i].bConfirmed)
            return Tracked[i].HWID;
    return "";
}

function SetMuteState(PlayerPawn PP, bool bMuted)
{
    local int i;
    for (i = 0; i < Tracked.Length; i++)
        if (Tracked[i].Pawn == PP)
            Tracked[i].bMuted = bMuted;
}

function string TodayStr()
{
    local string M, D;

    if (Level.Month < 10) M = "0"$Level.Month;
    else                  M = string(Level.Month);

    if (Level.Day < 10) D = "0"$Level.Day;
    else                D = string(Level.Day);

    return Level.Year$"-"$M$"-"$D;
}

function string GetWord(string S, int N)
{
    local int i;
    local string W, R;

    R = S;
    for (i = 0; i <= N; i++)
    {
        while (Left(R, 1) == " ") R = Mid(R, 1);
        if (InStr(R, " ") >= 0)
        {
            W = Left(R, InStr(R, " "));
            R = Mid(R, InStr(R, " ") + 1);
        }
        else
        {
            W = R;
            R = "";
        }
        if (i == N) return W;
    }
    return "";
}

defaultproperties
{
    bAlwaysTick=True
}
```
