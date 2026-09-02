# UT99 PersistentMute — Project Memory

Persistent notes for this project. Read at the start of every session.
See `CLAUDE.md` for project-specific details.

## CONFIRMED ROOT CAUSES

- **Server-wide `!pm` silent failure (Aug 2026)**: server was upgraded to ACE v14e
  and `IACEv13.u` was removed from `System`. `PersistentMute.u` had `IACEv13` baked
  into its name table via the untyped `class'IACECheck'` literal, so the package
  failed to resolve its dependency and never loaded — ServerActor never spawned,
  Nexgen plugin never registered, every `!pm` command silently did nothing.
  Fixed by qualifying the literal as `class'IACEv14.IACECheck'` (commit `69b8212`).
  Confirmed working live 2026-09-01: package loads, `!pm` responds in chat, HWID
  capture works under ACE v14e.

## RULED-OUT THEORIES

- (none recorded yet)

## PROJECT CONVENTIONS

- **`!pm` is a chat command, never a console command.** Send it by pressing **T** and
  typing `!pm list`, or from the console as `say !pm list`. Typing `!pm ...` straight
  into the console returns *"unrecognized command"* from UT's own console parser — the
  mod never sees it. Confirmed 2026-08-10: `!pm list` in chat returned the mute list
  correctly on the live server. Do not treat that console message as a mod failure.
- Chat is only visible to `PersistentMutePlugin` (the Nexgen plugin). `Mutate()` exists
  in `PersistentMuteMut.uc` but Nexgen intercepts the Mutate chain, so `mutate pm ...`
  from the console is unreliable by design.

## CHANGE LOG

Newest first. Format: `- YYYY-MM-DD — what changed`.

- 2026-09-01 — Confirmed IACEv14 retarget live: package loads, !pm responds, HWID captured under ACE v14e. Updated README/CLAUDE.md refs from IACEv13 to IACEv14.
- 2026-08-10 — Documented that `!pm` is chat-only (Readme + MEMORY); console "unrecognized command" is not a mod fault.
- 2026-08-02 — Created MEMORY.md skeleton (UT99 convention).
