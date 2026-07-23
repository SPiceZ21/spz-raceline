-- server/main.lua
-- Persistence + the only authority on "did the time improve".
--
-- Flow: spz-races finishes a race/TT lap → fires spz-raceline:lapCompleted here
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

-- ── Lap completed (server-local event, fired by spz-races for both races and
--    time trials — timetrail.lua and checkpoints.lua)

AddEventHandler("spz-raceline:lapCompleted", function(src, trackName, lapTimeMs)
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

RegisterNetEvent("spz-raceline:submitCapture", function(track, payload)
    local src = source
    local p = Pending[src]
    if not p or p.track ~= track or GetGameTimer() > p.expires then return end
    Pending[src] = nil

    -- v2/v3 payload: { v = 2|3, m = modelHash, p = { x, y, z, state, t, ... }, c = splits? }
    if type(payload) ~= "table" or (payload.v ~= 2 and payload.v ~= 3) then return end
    if type(payload.m) ~= "number" then return end
    local flat = payload.p
    if type(flat) ~= "table" then return end

    local n = #flat
    if n < 10 or n % 5 ~= 0 or n > Config.MaxPoints * 5 then return end
    for i = 1, n do
        if type(flat[i]) ~= "number" then return end
    end
    -- Per-point times must be sane: within the lap, non-negative
    local lastT = flat[n]
    if lastT < 0 or lastT > p.ms + 60000 then return end

    -- v3 carries CP split times; validate them minimally
    local splits = nil
    if payload.v == 3 and type(payload.c) == "table" then
        local clean = true
        for _, v in pairs(payload.c) do
            if type(v) ~= "number" or v < 0 then clean = false; break end
        end
        if clean then splits = payload.c end
    end

    -- Normalise to v3 for storage (splits may be empty table for v2 upgrades)
    local stored = { v = 3, m = payload.m, p = flat, c = splits or {} }

    MySQL.query.await([[
        INSERT INTO racelines (player_id, track, best_ms, anchor_x, anchor_y, anchor_z, points)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            best_ms  = VALUES(best_ms),
            anchor_x = VALUES(anchor_x),
            anchor_y = VALUES(anchor_y),
            anchor_z = VALUES(anchor_z),
            points   = VALUES(points)
    ]], { p.pid, track, p.ms, flat[1], flat[2], flat[3],
          json.encode(stored) })

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

-- ── Track record lines (async ghost racing) ──────────────────────────────────
-- The fastest stored line for a track, ANY player — the server ghost everyone
-- races against. Cached briefly: leaderboards and TT menus hammer this.

local RecordCache = {}   -- track -> { at = ms, best, holder, points }
local RECORD_TTL  = 60000

local function GetRecordRow(track)
    local hit = RecordCache[track]
    if hit and (GetGameTimer() - hit.at) < RECORD_TTL then return hit end

    local rows = MySQL.query.await([[
        SELECT r.points, r.best_ms, p.username
        FROM racelines r
        JOIN players p ON p.id = r.player_id
        WHERE r.track = ?
        ORDER BY r.best_ms ASC
        LIMIT 1
    ]], { track })

    local row = rows and rows[1]
    local entry
    if row then
        local ok, decoded = pcall(json.decode, row.points)
        entry = {
            at     = GetGameTimer(),
            best   = row.best_ms,
            holder = row.username or "Unknown",
            points = ok and decoded or nil,
        }
    else
        entry = { at = GetGameTimer() }   -- negative-cache empty tracks too
    end
    RecordCache[track] = entry
    return entry
end

RegisterNetEvent("spz-raceline:getRecordLine", function(track)
    local src = source
    if type(track) ~= "string" then return end

    local rec = GetRecordRow(track)
    if not rec.points then return end

    TriggerClientEvent("spz-raceline:recordLine", src, track, rec.points, rec.best, rec.holder)
end)

-- Summary only (no line payload) — for menus/leaderboards
exports("GetRecordSummary", function(track)
    local rec = GetRecordRow(track)
    if not rec.best then return nil end
    return { best = rec.best, holder = rec.holder }
end)

AddEventHandler("playerDropped", function()
    Pending[source] = nil
end)
