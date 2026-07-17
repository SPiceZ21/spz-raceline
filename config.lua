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
