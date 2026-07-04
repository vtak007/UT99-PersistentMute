// =============================================================================
// PersistentMutePlugin.uc
// Nexgen plugin half of PersistentMute.
//
// WHY THIS EXISTS:
//   On a Nexgen server the standard mutator broadcast hooks never fire —
//   NexgenController runs its OWN private message-mutator chain and only calls
//   REGISTERED Nexgen plugins (verified live: MutatorBroadcastMessage never
//   fired even as head BaseMutator). So chat interception must be a Nexgen
//   plugin. Nexgen calls plugins[i].mutatorTeamMessage(...) for Say/TeamSay and
//   mutatorBroadcastMessage(...) for other broadcasts; returning false blocks.
//
//   This plugin is spawned lazily by PersistentMuteMut once NexgenController
//   exists; NexgenPlugin.preBeginPlay() then self-registers it with the
//   controller. The back-reference Mut is set by PersistentMuteMut after spawn.
//   All persistence / HWID / tracking logic stays in PersistentMuteMut; this
//   class only decides whether a given chat line is blocked.
// =============================================================================
class PersistentMutePlugin extends NexgenPlugin;

var PersistentMuteMut Mut;   // back-reference set by the mutator after spawn

// Nexgen calls the message hooks once PER RECEIVER, so a single chat line fires
// them N times. Dedupe side effects (command execution, private notice) on
// sender+text within a short window; the block decision is returned every call.
var Actor  lastSender;
var string lastMsg;
var float  lastTime;

// Nexgen right "G" = R_Moderate (may moderate the game) — required for !pm.
const R_MODERATE = "G";

// Shared filter. Returns true if the message must be BLOCKED (swallowed).
function bool filterChat(Actor sender, string msg)
{
    local PlayerPawn PP;
    local NexgenClient c;
    local bool bNewEvent;

    PP = PlayerPawn(sender);
    if (PP == None || Mut == None)
        return false;   // not a player line, or not wired up yet — allow

    bNewEvent = !(sender == lastSender && msg == lastMsg
                  && (Level.TimeSeconds - lastTime) < 0.5);

    // Admin commands via chat prefix !pm — never broadcast to others.
    if (Caps(Left(msg, 4)) == "!PM ")
    {
        if (bNewEvent)
        {
            lastSender = sender;  lastMsg = msg;  lastTime = Level.TimeSeconds;
            c = control.getClient(PP);
            if (c != None && c.hasRight(R_MODERATE))
                Mut.ProcessCommand(Mid(msg, 4), PP);
            else
                PP.ClientMessage("[PM] Moderator access required.");
        }
        return true;
    }

    // Muted sender — block silently with a private duration-specific notice.
    if (Mut.IsMuted(PP))
    {
        if (bNewEvent)
        {
            lastSender = sender;  lastMsg = msg;  lastTime = Level.TimeSeconds;
            PP.ClientMessage(Mut.MuteNotice(Mut.HWIDFor(PP)));
        }
        return true;
    }

    return false;   // allow
}

// Normal player chat (Say / TeamSay).
function bool mutatorTeamMessage(Actor sender, Pawn receiver,
    PlayerReplicationInfo pri, coerce string s, name type, optional bool bBeep)
{
    if (type != 'Say' && type != 'TeamSay')
        return true;

    if (filterChat(sender, s))
        return false;
    return true;
}

// Other broadcasts (e.g. spectator chat) — block muted senders here too.
function bool mutatorBroadcastMessage(Actor sender, Pawn receiver,
    out coerce string msg, optional bool bBeep, out optional name type)
{
    if (filterChat(sender, msg))
        return false;
    return true;
}

defaultproperties
{
    pluginName="PersistentMute"
    pluginAuthor="perdition007"
    pluginVersion="1.0"
}
