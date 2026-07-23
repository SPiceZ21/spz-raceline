Config = {}

-- ── Capture ───────────────────────────────────────────────────────────────────

Config.SampleDistance   = 2.0    -- metres driven between samples
Config.MaxPoints        = 4000   -- ring buffer cap (~8 km of line at 2 m spacing)
Config.BreakDistance    = 20.0   -- a jump bigger than this (teleport/respawn) splits the line
Config.ThrottleDeadzone = 0.15   -- pedal input below this counts as coasting
Config.BrakeDeadzone    = 0.15

-- ── Display ───────────────────────────────────────────────────────────────────

Config.DrawDistance    = 140.0   -- only segments this close to the player render
Config.LineWidth       = 0.35    -- ribbon width in metres
Config.HeightOffset    = 0.08    -- lift above the road to avoid z-fighting
Config.RebuildMs       = 400     -- how often the visible segment set refreshes
Config.MaxDrawSegments = 300     -- hard cap on quads per frame

Config.Colours = {
    accel = { r = 40,  g = 220, b = 90,  a = 150 },  -- green: on throttle
    brake = { r = 235, g = 45,  b = 45,  a = 150 },  -- red: on brakes
    coast = { r = 235, g = 235, b = 235, a = 100 },  -- faint white: neither
}

-- ── Time-trial persistence ────────────────────────────────────────────────────
-- Best-lap lines are stored per player per track (only when the lap time
-- improves) and auto-load when the player comes near where the line starts.

Config.AutoLoadRange   = 150.0   -- metres from a stored line's start to auto-show it
Config.AutoUnloadRange = 220.0   -- hysteresis: hide again beyond this
Config.AutoScanMs      = 3000    -- proximity check interval
Config.LoopCloseRange  = 60.0    -- if a line ends within this of its start, close the loop

-- ── Ghost car (time trials) ───────────────────────────────────────────────────
-- Replays your stored best lap as a translucent car to race against. Uses the
-- per-point timing captured with the line (v2 lines); older v1 lines replay at
-- distance-proportional pace.
Config.Ghost = {
    enabled       = true,
    alpha         = 150,       -- 0-255 ghost transparency
    zLift         = 0.45,      -- points are at road height; lift to axle height
    fallbackModel = `sultan`,  -- used when the line predates model capture (v1)
    headingLerp   = 10.0,      -- yaw smoothing factor (higher = snappier)
}

-- Telemetry coaching overlay (/raceline coach). Paints the road red where you
-- lost time vs your reference lap, with "-Xs" markers at the worst spots.
Config.Coach = {
    enabled     = true,
    minLossMs   = 40,          -- ignore losses smaller than this (noise floor)
    markerCount = 4,           -- how many "hot" loss markers to flag
    drawRange   = 220.0,       -- metres
    width       = 0.5,         -- ribbon width
    zLift       = 0.06,        -- lift above road to avoid z-fighting
}
