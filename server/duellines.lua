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
