-- server/main.lua
-- Persistence + the only authority on "did the time improve".
--
-- Flow: spz-races finishes a TT lap → fires spz-raceline:tt:lapCompleted here
-- with the SERVER-measured lap time → we compare against the stored best and,
-- only if faster, ask that client for its captured line. The client never
-- supplies a time — the pending token pins the time we were told by spz-races,
-- so a client can submit junk points at worst, never a fake record.

local Pending = {}   -- src -> { track, ms, pid, expires }

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function PlayerDbId(src)
    local ok, profile = pcall(function() return exports["spz-identity"]:GetProfile(src) end)
    return ok and profile and profile.id or nil
end

-- Identity loads the profile asynchronously after join; wait a little.
local function AwaitPlayerDbId(src, timeoutMs)
    local deadline = GetGameTimer() + (timeoutMs or 15000)
    while GetGameTimer() < deadline do
        local pid = PlayerDbId(src)
        if pid then return pid end
        Wait(500)
    end
    return nil
end

-- ── Lap completed (server-local event, fired by spz-races/server/timetrail.lua)

AddEventHandler("spz-raceline:tt:lapCompleted", function(src, trackName, lapTimeMs)
    if type(trackName) ~= "string" or type(lapTimeMs) ~= "number" or lapTimeMs <= 0 then return end

    local pid = PlayerDbId(src)
    if not pid then return end

    local best = MySQL.scalar.await(
        "SELECT best_ms FROM racelines WHERE player_id = ? AND track = ? LIMIT 1",
        { pid, trackName }
    )
    if best and lapTimeMs >= best then return end   -- no improvement: keep the old line

    Pending[src] = { track = trackName, ms = lapTimeMs, pid = pid, expires = GetGameTimer() + 30000 }
    TriggerClientEvent("spz-raceline:requestCapture", src, trackName)
end)

-- ── Line submission (client → server, only valid against a pending token) ────

RegisterNetEvent("spz-raceline:submitCapture", function(track, flat)
    local src = source
    local p = Pending[src]
    if not p or p.track ~= track or GetGameTimer() > p.expires then return end
    Pending[src] = nil

    -- flat = { x, y, z, state, x, y, z, state, ... }
    if type(flat) ~= "table" then return end
    local n = #flat
    if n < 8 or n % 4 ~= 0 or n > Config.MaxPoints * 4 then return end
    for i = 1, n do
        if type(flat[i]) ~= "number" then return end
    end

    MySQL.query.await([[
        INSERT INTO racelines (player_id, track, best_ms, anchor_x, anchor_y, anchor_z, points)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            best_ms  = VALUES(best_ms),
            anchor_x = VALUES(anchor_x),
            anchor_y = VALUES(anchor_y),
            anchor_z = VALUES(anchor_z),
            points   = VALUES(points)
    ]], { p.pid, track, p.ms, flat[1], flat[2], flat[3], json.encode(flat) })

    TriggerClientEvent("spz-raceline:saved", src, track, p.ms, { x = flat[1], y = flat[2], z = flat[3] })
end)

-- ── Anchor list (for client proximity auto-loading) ──────────────────────────

RegisterNetEvent("spz-raceline:getAnchors", function()
    local src = source
    local pid = AwaitPlayerDbId(src, 15000)
    if not pid then return end

    local rows = MySQL.query.await(
        "SELECT track, best_ms, anchor_x, anchor_y, anchor_z FROM racelines WHERE player_id = ?",
        { pid }
    )

    local out = {}
    for _, r in ipairs(rows or {}) do
        out[#out + 1] = { track = r.track, best = r.best_ms, x = r.anchor_x, y = r.anchor_y, z = r.anchor_z }
    end
    TriggerClientEvent("spz-raceline:anchors", src, out)
end)

-- ── Full line fetch ───────────────────────────────────────────────────────────

RegisterNetEvent("spz-raceline:getLine", function(track)
    local src = source
    if type(track) ~= "string" then return end

    local pid = PlayerDbId(src)
    if not pid then return end

    local rows = MySQL.query.await(
        "SELECT points, best_ms FROM racelines WHERE player_id = ? AND track = ? LIMIT 1",
        { pid, track }
    )
    local row = rows and rows[1]
    if not row then return end

    local ok, flat = pcall(json.decode, row.points)
    if not ok or type(flat) ~= "table" then return end

    TriggerClientEvent("spz-raceline:line", src, track, flat, row.best_ms)
end)

-- ── Cleanup ───────────────────────────────────────────────────────────────────

AddEventHandler("playerDropped", function()
    Pending[source] = nil
end)
