# UT99 PersistentMute — Project Memory

Persistent notes for this project. Read at the start of every session.
See `CLAUDE.md` for project-specific details.

## CONFIRMED ROOT CAUSES

- (none recorded yet)

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

- 2026-08-10 — Documented that `!pm` is chat-only (Readme + MEMORY); console "unrecognized command" is not a mod fault.
- 2026-08-02 — Created MEMORY.md skeleton (UT99 convention).
