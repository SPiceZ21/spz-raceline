# spz-raceline

Racing-line trainer. Automatically records your driving line in **races and
time trials** and paints your best one on the road as a flat ribbon: **green**
where you were on throttle, **red** where you were braking, faint white where
you coasted.

## How it behaves

- **Fully automatic capture.** Every race lap and time-trial lap is silently
  recorded. When a lap **beats your stored best for that track**, the driven
  line is saved (per player, per track) — slower laps never overwrite it.
  Times are server-measured (from `spz-races`); the client only supplies
  points, never times.
- **Closed loops.** Circuit captures run through the final-checkpoint → start-line
  stretch, and any residual seam is bridged with interpolated points at
  display time (`Config.LoopCloseRange`), so the ribbon reads as one
  continuous lap.
- **Ghost while practising.** Entering a time trial shows your stored best
  line; beating it swaps the ghost immediately.
- **Auto-detect.** Drive near any track where you have a stored line
  (`Config.AutoLoadRange`, default 150 m from the line's start) and it loads
  and displays automatically; it hides again when you leave.

## Ghost car

In time trials your stored best lap replays as a **translucent ghost car** —
your own vehicle model, brake lights lighting up where you braked. It launches
in sync with each lap start (CP1 crossing), fades out when its lap is done,
and swaps to the new line the moment you set a faster one. Lines recorded from
v0.4 onward carry per-point timing so the ghost accelerates and brakes exactly
where you did; older lines replay at distance-proportional pace.

## Commands

| Command | Effect |
|---|---|
| `/raceline show` | Show the line |
| `/raceline hide` | Hide the line |
| `/raceline ghost` | Toggle the time-trial ghost car |

`Raceline: Toggle Display` is also bindable in Settings → Key Bindings.

## How it works

- Samples position + pedal state every `Config.SampleDistance` metres driven.
  Brake input wins over throttle, so trail-braking reads as braking.
- Two buffers: the display ring buffer (drawn), and a per-lap capture that is
  frozen at the lap boundary and submitted only when the server confirms the
  lap improved.
- Rendering is two-stage: a slow thread rebuilds the set of nearby segments
  every `Config.RebuildMs`, the per-frame thread only paints that set
  (`Config.MaxDrawSegments` cap).
- Storage: `racelines` table, owned by `spz-core/migrations/006_racelines.sql`.
  Lines are stored as a flat JSON array of `x, y, z, state` quadruples; the
  first point doubles as the proximity anchor.

## Exports (client)

`SetLineVisible(bool)`, `IsLineVisible()`, `ClearLine()`,
`GetLine()` → ordered point array, `LoadLine(points)` → replace the display.

Point format: `{ x, y, z, s, brk }` where `s` = 0 coast / 1 throttle / 2 brake.

## Dependencies

- `oxmysql` (persistence)
- Soft: `spz-identity` (player id), `spz-races` (lap events)
