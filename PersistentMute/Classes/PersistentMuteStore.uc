// =============================================================================
// PersistentMuteStore.uc
// Config persistence layer for PersistentMute.
// Writes to System\PersistentMute.ini — survives map changes and restarts.
//
// Record format (pipe-delimited string):
//   [0] HWID         — ACE hardware ID (hex string)
//   [1] PlayerName   — display name at time of mute; grows "(aka ...)" aliases
//   [2] MuteType     — 0=Permanent, 1=Until date, 2=Games remaining
//   [3] ExpiryValue  — "0" | "YYYY-MM-DD" | integer string
//   [4] AdminName    — who issued the mute
//   [5] DateAdded    — YYYY-MM-DD when mute was created
//   [6] Reason       — optional free text (may be absent in old records)
//
// Seen format (last-seen cache, one record per HWID, newest last):
//   [0] HWID  [1] PlayerName  [2] LastSeenDate (YYYY-MM-DD)
// =============================================================================
class PersistentMuteStore extends Info config(PersistentMute);

var config array<string> Records;
var config array<string> Seen;

// Last-seen cache cap — oldest entry is evicted once exceeded
const SEEN_MAX = 200;

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
                 string ExpiryVal, string AdminName, string DateStr, string Reason)
{
    local int Idx;
    local string Rec;

    Rec = HWID$"|"$PlayerName$"|"$MuteType$"|"$ExpiryVal$"|"$AdminName$"|"$DateStr$"|"$Reason;
    Idx = FindIndex(HWID);
    if (Idx >= 0)
        Records[Idx] = Rec;
    else
    {
        // UT99 dynamic arrays do NOT auto-grow on Records[Records.Length]=Rec
        // (that is UT2004+ behaviour). Must Insert first, then assign.
        Records.Insert(Records.Length, 1);
        Records[Records.Length - 1] = Rec;
    }
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
              GetField(Records[Idx], 5) $"|"$
              GetField(Records[Idx], 6);
    Records[Idx] = Rebuilt;
    SaveConfig();
    return false;
}

// -----------------------------------------------------------------------------
//  Last-seen cache — enables offline mutes/unmutes by player name.
//  One record per HWID, most recently seen last (eviction removes index 0).
// -----------------------------------------------------------------------------

function TouchSeen(string HWID, string PlayerName, string DateStr)
{
    local int i;

    for (i = 0; i < Seen.Length; i++)
    {
        if (Caps(GetField(Seen[i], 0)) == Caps(HWID))
        {
            Seen.Remove(i, 1);
            break;
        }
    }
    Seen.Insert(Seen.Length, 1);
    Seen[Seen.Length - 1] = HWID$"|"$PlayerName$"|"$DateStr;
    if (Seen.Length > SEEN_MAX)
        Seen.Remove(0, 1);
    SaveConfig();
}

// Most recent cache entry matching the name — exact (case-insensitive) first,
// then substring. Returns the full record string, or "" if no match.
function string SeenLookup(string PlayerName)
{
    local int i;

    for (i = Seen.Length - 1; i >= 0; i--)
        if (Caps(GetField(Seen[i], 1)) == Caps(PlayerName))
            return Seen[i];
    for (i = Seen.Length - 1; i >= 0; i--)
        if (InStr(Caps(GetField(Seen[i], 1)), Caps(PlayerName)) >= 0)
            return Seen[i];
    return "";
}

// -----------------------------------------------------------------------------
//  Alias tracking — when a muted HWID reconnects under a new name, append it
//  to the record's name field: "Bob (aka Bob2, xX_Bob_Xx)".
// -----------------------------------------------------------------------------

function AddAlias(string HWID, string NewName)
{
    local int Idx;
    local string N;

    Idx = FindIndex(HWID);
    if (Idx < 0) return;

    N = GetField(Records[Idx], 1);
    if (InStr(Caps(N), Caps(NewName)) >= 0) return;   // name already listed

    if (InStr(N, " (aka ") >= 0)
        N = Left(N, Len(N) - 1)$", "$NewName$")";
    else
        N = N$" (aka "$NewName$")";

    Records[Idx] = GetField(Records[Idx], 0)$"|"$N
        $"|"$GetField(Records[Idx], 2)$"|"$GetField(Records[Idx], 3)
        $"|"$GetField(Records[Idx], 4)$"|"$GetField(Records[Idx], 5)
        $"|"$GetField(Records[Idx], 6);
    SaveConfig();
}

defaultproperties
{
    bHidden=True
}
