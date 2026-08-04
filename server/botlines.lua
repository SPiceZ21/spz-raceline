-- server/botlines.lua
-- Bot line supplier. Hands spz-races a spread of real, stored human lines for a
-- track so it can fill a thin race with replayed "ghost-bots". Returns a MIXED
-- pace field (fastest through slower PBs), not a wall of record laps, so the
-- bots are beatable.

-- A specific player's stored line for a track (for ghost duels). Same decode as
-- GetBotLines but keyed to one player_id.
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

exports("GetBotLines", function(track, count)
    if type(track) ~= "string" or type(count) ~= "number" or count <= 0 then
        return {}
    end

    -- Pool the fastest lines for this track (one per player already, since the
    -- racelines table stores a single best line per player/track).
    local pool = MySQL.query.await([[
        SELECT r.points, r.best_ms, pl.username, r.player_id
        FROM racelines r JOIN players pl ON pl.id = r.player_id
        WHERE r.track = ?
        ORDER BY r.best_ms ASC
        LIMIT 20
    ]], { track })

    if not pool or #pool == 0 then return {} end

    -- Even spread across the pool for varied pace. With count == 1 just take the
    -- fastest; otherwise sample indices from fastest (i=1) to slowest (i=count).
    local picks = {}
    local N = #pool
    if N <= count then
        for i = 1, N do picks[i] = pool[i] end
    elseif count == 1 then
        picks[1] = pool[1]
    else
        for i = 1, count do
            local idx = math.floor((i - 1) * (N - 1) / (count - 1)) + 1
            picks[i] = pool[idx]
        end
    end

    local out = {}
    for _, row in ipairs(picks) do
        local ok, stored = pcall(json.decode, row.points)
        if ok and type(stored) == "table" and type(stored.p) == "table" and #stored.p >= 10 then
            out[#out + 1] = {
                name   = row.username or "Ghost",
                ms     = row.best_ms,
                model  = stored.m,        -- vehicle model hash
                points = stored.p,        -- flat { x, y, z, state, t, ... }
                splits = stored.c or {},  -- per-CP cumulative ms into the lap (v3)
            }
        end
    end
    return out
end)
