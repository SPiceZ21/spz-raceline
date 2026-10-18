-- server/duellines.lua
-- Stored-line supplier for ghost duels: one named player's best line on one
-- track, decoded for spz-races/server/duel.lua to replay as their ghost.
--
-- This file used to also serve GetBotLines, which handed spz-races a spread of
-- lines to backfill thin races with replayed "ghost-bots". That feature is gone
-- and so is the query behind it.

exports("GetLineByPlayerId", function(pid, track)
    pid = tonumber(pid)
    if not pid or type(track) ~= "string" then return nil end

    local rows = MySQL.query.await([[
        SELECT r.points, r.best_ms, pl.username
        FROM racelines r JOIN players pl ON pl.id = r.player_id
        WHERE r.player_id = ? AND r.track = ? LIMIT 1
    ]], { pid, track })

    local row = rows and rows[1]
    if not row then return nil end

    local ok, stored = pcall(json.decode, row.points)
    if not ok or type(stored) ~= "table" or type(stored.p) ~= "table" or #stored.p < 10 then
        return nil
    end
    return {
        name   = row.username or "Ghost",
        ms     = row.best_ms,
        model  = stored.m,
        points = stored.p,
        splits = stored.c or {},
    }
end)

-- ── Track outline for the race poll ──────────────────────────────────────────
-- The fastest stored line for a track, ANY player, thinned to a 2-D outline.
-- Captured every 2 m along what was actually driven, so it follows the roads —
-- unlike the checkpoints, which can sit hundreds of metres apart and plot as
-- chords across the map. Cached: a poll asks for three tracks at once.
--
--   exports["spz-raceline"]:GetTrackOutline("10-80", 180, { x = .., y = .. })
--   → { {x=..,y=..}, ... } or nil
-- `near` (optional) is the track's first checkpoint: a line that does not start
-- near it was driven on some other layout and is ignored.
local OutlineCache, OUTLINE_TTL = {}, 600000

exports("GetTrackOutline", function(track, maxPoints, near)
    if type(track) ~= "string" then return nil end
    maxPoints = math.max(20, math.min(400, tonumber(maxPoints) or 180))

    local hit = OutlineCache[track]
    local flat
    if hit and (GetGameTimer() - hit.at) < OUTLINE_TTL then
        flat = hit.flat
    else
        local rows = MySQL.query.await(
            "SELECT points FROM racelines WHERE track = ? ORDER BY best_ms ASC LIMIT 1", { track })
        local row = rows and rows[1]
        local ok, data = false, nil
        if row and row.points then ok, data = pcall(json.decode, row.points) end
        flat = (ok and type(data) == "table" and type(data.p) == "table") and data.p or false
        OutlineCache[track] = { at = GetGameTimer(), flat = flat }
    end
    if not flat or #flat < 50 then return nil end

    -- points are x, y, z, state, t
    local n = math.floor(#flat / 5)
    if near and near.x and near.y then
        local dx, dy = flat[1] - near.x, flat[2] - near.y
        if dx * dx + dy * dy > 150 * 150 then return nil end
    end

    local total = 0
    for i = 2, n do
        local a, b = (i - 2) * 5, (i - 1) * 5
        total = total + math.sqrt((flat[b + 1] - flat[a + 1]) ^ 2 + (flat[b + 2] - flat[a + 2]) ^ 2)
    end
    local step = math.max(8.0, total / maxPoints)

    local out, acc = { { x = math.floor(flat[1] + 0.5), y = math.floor(flat[2] + 0.5) } }, 0
    for i = 2, n do
        local a, b = (i - 2) * 5, (i - 1) * 5
        acc = acc + math.sqrt((flat[b + 1] - flat[a + 1]) ^ 2 + (flat[b + 2] - flat[a + 2]) ^ 2)
        if acc >= step or i == n then
            out[#out + 1] = { x = math.floor(flat[b + 1] + 0.5), y = math.floor(flat[b + 2] + 0.5) }
            acc = 0
        end
    end
    return #out >= 10 and out or nil
end)

-- A new record replaces the line the outline came from.
AddEventHandler("spz-raceline:recordTaken", function(d)
    if d and d.track then OutlineCache[d.track] = nil end
end)
