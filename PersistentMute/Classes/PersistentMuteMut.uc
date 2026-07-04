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
// Note: Nexgen intercepts the Mutate chain so mutate PM commands are unreliable.
// =============================================================================
class PersistentMuteMut extends Mutator;

var PersistentMuteStore Store;

// Nexgen plugin half — handles chat interception (Nexgen owns the chat path,
// so the standard mutator broadcast hooks never fire). Spawned lazily from
// Timer() once NexgenController exists; it self-registers with Nexgen.
var PersistentMutePlugin PMPlugin;
var bool bPluginDone;   // true once we've had our one shot at spawning it

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
    Store = Spawn(class'PersistentMute.PersistentMuteStore');
    if (Store == None)
        log("PersistentMute: ERROR - PersistentMuteStore failed to spawn");

    SetTimer(POLL_INTERVAL, true);
    Super.PostBeginPlay();

    // Self-register in the mutator chain when loaded as a ServerActor.
    // Must be listed before Nexgen in ServerActors so we become BaseMutator.
    // NOTE: AddMutator is a member of Mutator, NOT GameInfo. Splice in via
    // BaseMutator directly. Because we load before Nexgen, BaseMutator is None
    // when we run, so we become BaseMutator and Nexgen appends behind us.
    if (Level.Game != None)
    {
        if (Level.Game.BaseMutator == None)
            Level.Game.BaseMutator = self;
        else
        {
            // BaseMutator is already claimed by the command-line ?mutator= list
            // (added during GameInfo init, before ServerActors run). Prepend so
            // we become the new head and get first crack at every hook —
            // especially MutatorBroadcastMessage, which the tail never receives
            // when an upstream mutator (e.g. Nexgen) fails to forward it.
            self.NextMutator = Level.Game.BaseMutator;
            Level.Game.BaseMutator = self;
        }
    }
    else
        log("PersistentMute: ERROR - Level.Game is None at PostBeginPlay");
}

// True if the given pawn is currently tracked and muted this session.
function bool IsMuted(PlayerPawn PP)
{
    local int i;
    for (i = 0; i < Tracked.Length; i++)
        if (Tracked[i].Pawn == PP && Tracked[i].bMuted)
            return true;
    return false;
}

// Spawn the Nexgen plugin once NexgenController exists. NexgenPlugin.preBeginPlay
// self-registers with the controller, so we only Spawn after confirming it is up.
// We get exactly one shot (bPluginDone) — if the controller is present but
// registration fails, retrying will not help.
function TrySpawnPlugin()
{
    local NexgenController NC;

    foreach AllActors(class'Nexgen112N.NexgenController', NC)
        break;   // we only need to know one exists

    if (NC == None)
        return;   // Nexgen not initialised yet — try again next tick

    bPluginDone = true;
    PMPlugin = Spawn(class'PersistentMute.PersistentMutePlugin');
    if (PMPlugin != None)
        PMPlugin.Mut = self;
    else
        log("PersistentMute: ERROR - PersistentMutePlugin failed to spawn/register");
}

// =============================================================================
//  Player tracking
// =============================================================================

// ModifyPlayer fires each time a human pawn spawns/respawns.
// Human network players have a non-None Player reference; bots do not.
function ModifyPlayer(Pawn Other)
{
    local PlayerPawn PP;

    PP = PlayerPawn(Other);
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
    // UT99 dynamic arrays do NOT auto-grow on Tracked[Tracked.Length]=E
    // (that is UT2004+ behaviour). Must Insert first, then assign.
    Tracked.Insert(Tracked.Length, 1);
    Tracked[Tracked.Length - 1] = E;
}

// =============================================================================
//  Timer — HWID polling + stale entry cleanup
// =============================================================================

function Timer()
{
    local int i;
    local string H;

    // Spawn + register the Nexgen plugin once Nexgen is up (load-order safe).
    if (!bPluginDone)
        TrySpawnPlugin();

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
        Tracked[Idx].Pawn.ClientMessage(MuteNotice(Tracked[Idx].HWID));
}

// Duration-specific notice shown to a muted player — built from the stored
// record so the same wording appears on mute, on join, and on blocked chat.
function string MuteNotice(string HWID)
{
    local int i;
    local string Rec;

    for (i = 0; i < Store.Records.Length; i++)
    {
        Rec = Store.Records[i];
        if (Caps(Store.GetField(Rec, 0)) == Caps(HWID))
        {
            switch (int(Store.GetField(Rec, 2)))
            {
                case 1: return "You are muted on this server until "$Store.GetField(Rec, 3)$".";
                case 2: return "You are muted on this server for "$Store.GetField(Rec, 3)$" games";
            }
            return "You are muted on this server forever";
        }
    }
    return "You are muted on this server forever";
}

// =============================================================================
//  Chat interception
// =============================================================================

function bool MutatorBroadcastMessage(Actor Sender, Pawn Receiver,
    out coerce string Msg, bool bTeamMessage, out name Type)
{
    local int i;
    local PlayerPawn PP;

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
                PP.ClientMessage(MuteNotice(Tracked[i].HWID));
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
        default:
            Admin.ClientMessage("[PM] Commands (type in chat):");
            Admin.ClientMessage("  !pm mute <name> forever | until YYYY-MM-DD | games N");
            Admin.ClientMessage("  !pm mute-hwid <HWID> forever | until YYYY-MM-DD | games N");
            Admin.ClientMessage("  !pm unmute <name>  |  !pm unmute-hwid <HWID>  |  !pm list");
    }
}

// ---- mute by in-game name ----

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

// ---- mute by raw HWID (works for offline players) ----

function CmdMuteByHWID(PlayerPawn Admin, string HWID, string DurType, string DurVal)
{
    local PlayerPawn Online;
    Online = FindByHWID(HWID);
    DoMute(Admin, HWID, "Unknown", DurType, DurVal, Online);
}

// ---- shared mute execution ----

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

    // Update live session state if player is currently online
    if (Target != None)
    {
        SetMuteState(Target, true);
        Target.ClientMessage(MuteNotice(HWID));
    }

    Admin.ClientMessage("[PM] Muted: "$PlayerName$" | HWID: "$HWID$" | "$DurType$" "$DurVal);
}

// ---- unmute by name ----

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

// ---- unmute by raw HWID ----

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

// ---- list all active mutes ----

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
//  ACE HWID query
//  ACE (v13p) spawns one IACECheck actor per validated player. Find it by
//  PlayerID and read HWHash directly — the same approach NexgenACEExt uses.
//  Requires EditPackages=IACEv13 (typed class'IACECheck'). Returns "" until ACE
//  has finished validating the player (its IACECheck appears a few seconds after
//  connect); Timer() keeps polling until confirmed.
// =============================================================================

function string QueryACEHWID(PlayerPawn PP)
{
    local IACECheck A;
    local int PID;

    if (PP.PlayerReplicationInfo == None)
        return "";

    PID = PP.PlayerReplicationInfo.PlayerID;

    foreach AllActors(class'IACECheck', A)
    {
        if (A.PlayerID == PID)
        {
            if (A.bWine)   // HWID unavailable under Wine/Linux clients
                return "";
            return A.HWHash;
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

// ISO date string built from LevelInfo's native time fields (UT99 + 469)
function string TodayStr()
{
    local string M, D;

    if (Level.Month < 10) M = "0"$Level.Month;
    else                  M = string(Level.Month);

    if (Level.Day < 10) D = "0"$Level.Day;
    else                D = string(Level.Day);

    return Level.Year$"-"$M$"-"$D;
}

// Extract word N (0-indexed) from a space-delimited string
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
