# spz-raceline

Racing-line trainer. Records your driving line and paints it on the road as a
flat ribbon: **green** where you were on throttle, **red** where you were
braking, faint white where you coasted.

## Time-trial integration

- Every time-trial lap is silently captured. When a lap **beats your stored
  best for that track**, the driven line is saved to the database
  (per player, per track) — slower laps never overwrite it.
- The lap time is server-measured (taken from `spz-races`); the client only
  supplies points, never times.
- Entering a time trial shows your stored best line as a ghost to drive
  against; beating it swaps the ghost for the new line immediately.
- **Auto-detect:** drive near any track where you have a stored line
  (`Config.AutoLoadRange`, default 150 m from the line's start) and it loads
  and displays automatically; it hides again when you leave.

## Manual usage

| Command | Effect |
|---|---|
| `/raceline rec` | Toggle free recording (auto-shows the line) |
| `/raceline show` / `hide` | Toggle display |
| `/raceline clear` | Wipe the displayed line |

`Raceline: Toggle Display` is also bindable in Settings → Key Bindings.

## How it works

- Samples position + pedal state every `Config.SampleDistance` metres driven.
  Brake input wins over throttle, so trail-braking reads as braking.
- Two buffers: the display ring buffer (drawn), and a per-lap capture that is
  frozen at the finish line and submitted only when the server confirms the
  lap improved.
- Rendering is two-stage: a slow thread rebuilds the set of nearby segments
  every `Config.RebuildMs`, the per-frame thread only paints that set
  (`Config.MaxDrawSegments` cap).
- Storage: `racelines` table, owned by `spz-core/migrations/006_racelines.sql`.
  Lines are stored as a flat JSON array of `x, y, z, state` quadruples; the
  first point doubles as the proximity anchor.

## Exports (client)

`StartRecording()`, `StopRecording()`, `IsRecording()`, `SetLineVisible(bool)`,
`IsLineVisible()`, `ClearLine()`, `GetLine()` → ordered point array,
`LoadLine(points)` → replace the display buffer.

Point format: `{ x, y, z, s, brk }` where `s` = 0 coast / 1 throttle / 2 brake.

## Dependencies

- `oxmysql` (persistence)
- Soft: `spz-identity` (player id), `spz-races` (time-trial lap events) —
  without them the manual record/display still works.
