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

-- Every rejection below used to be a bare `return`, which made a line that
-- never got stored indistinguishable from one the system never heard about —
-- the whole chain failed in silence. Each exit now says why.
AddEventHandler("spz-raceline:lapCompleted", function(src, trackName, lapTimeMs)
    if type(trackName) ~= "string" or type(lapTimeMs) ~= "number" or lapTimeMs <= 0 then
        print(("^3[raceline] Ignoring lap from %s: bad payload (track=%s time=%s).^7")
            :format(tostring(src), tostring(trackName), tostring(lapTimeMs)))
        TriggerClientEvent("spz-raceline:lapVerdict", src, tostring(trackName),
            "bad payload — spz-races sent a lap this resource cannot read")
        return
    end

    local pid = PlayerDbId(src)
    if not pid then
        print(("^3[raceline] No spz-identity profile for source %s — lap on %s not stored.^7")
            :format(tostring(src), trackName))
        TriggerClientEvent("spz-raceline:lapVerdict", src, trackName, "no identity profile — line not stored")
        return
    end

    local best = MySQL.scalar.await(
        "SELECT best_ms FROM racelines WHERE player_id = ? AND track = ? LIMIT 1",
        { pid, trackName }
    )
    if best and lapTimeMs >= best then
        print(("^3[raceline] %s: %d ms does not beat stored %d ms — keeping the old line.^7")
            :format(trackName, lapTimeMs, best))
        TriggerClientEvent("spz-raceline:lapVerdict", src, trackName,
            ("%d ms did not beat your stored %d ms"):format(lapTimeMs, best))
        return
    end

    print(("^2[raceline] %s: %d ms beats %s — asking client %s for its line.^7")
        :format(trackName, lapTimeMs, best and (best .. " ms") or "no stored line", tostring(src)))
    -- The accepted path is reported too. Only ever announcing rejections means
    -- silence is ambiguous: it could be "nothing was wrong" or "nothing ran".
    TriggerClientEvent("spz-raceline:lapVerdict", src, trackName,
        ("%d ms beats %s — requesting your line")
            :format(lapTimeMs, best and (best .. " ms") or "no stored line"))

    Pending[src] = { track = trackName, ms = lapTimeMs, pid = pid, expires = GetGameTimer() + 30000 }
    TriggerClientEvent("spz-raceline:requestCapture", src, trackName)
end)

-- ── Line submission (client → server, only valid against a pending token) ────

RegisterNetEvent("spz-raceline:submitCapture", function(track, payload)
    local src = source

    -- This handler is the last stretch before the INSERT and it used to reject
    -- in total silence: a line could be captured, requested, sent, and dropped
    -- here with nothing written and nothing said. Every gate now reports, to
    -- the server log and to the submitting client.
    local function reject(why)
        print(("^1[raceline] Rejected %s's line for %s: %s.^7")
            :format(tostring(src), tostring(track), why))
        TriggerClientEvent("spz-raceline:lapVerdict", src, track, "line rejected — " .. why)
    end

    local p = Pending[src]
    if not p or p.track ~= track or GetGameTimer() > p.expires then
        reject(not p and "no pending request (expired or never asked)"
               or p.track ~= track and ("pending track is " .. tostring(p.track))
               or "the 30s submission window closed")
        return
    end
    Pending[src] = nil

    -- v2/v3 payload: { v = 2|3, m = modelHash, p = { x, y, z, state, t, ... }, c = splits? }
    -- v4 adds `r`: the fixed-rate motion stream the ghost replays.
    -- v5 adds `rf` (motion stride) and `s`: the vehicle spec header.
    if type(payload) ~= "table" or type(payload.v) ~= "number"
       or payload.v < 2 or payload.v > 5 then
        reject("unsupported payload version " .. tostring(type(payload) == "table" and payload.v or "?"))
        return
    end
    if type(payload.m) ~= "number" then reject("no vehicle model in payload") return end
    local flat = payload.p
    if type(flat) ~= "table" then reject("no points array in payload") return end

    local n = #flat
    if n < 10 or n % 5 ~= 0 or n > Config.MaxPoints * 5 then
        reject(("bad points array: %d values (need a multiple of 5, 10..%d)")
            :format(n, Config.MaxPoints * 5))
        return
    end
    for i = 1, n do
        if type(flat[i]) ~= "number" then reject("non-numeric value at point index " .. i) return end
    end
    -- Per-point times must be sane: within the lap, non-negative
    local lastT = flat[n]
    if lastT < 0 or lastT > p.ms + 60000 then
        reject(("last point stamped %d ms against a %d ms lap"):format(lastT, p.ms))
        return
    end

    -- v3+ carries CP split times; validate them minimally
    local splits = nil
    if payload.v >= 3 and type(payload.c) == "table" then
        local clean = true
        for _, v in pairs(payload.c) do
            if type(v) ~= "number" or v < 0 then clean = false; break end
        end
        if clean then splits = payload.c end
    end

    -- Motion stream: flat tuples of `stride` numbers
    -- (t,x,y,z,qx,qy,qz,qw,steer,rpm,flags[,w1..w4]).
    -- Rejected wholesale if malformed — the line still stores fine without it.
    local motion, stride = nil, nil
    if payload.v >= 4 then
        local rf = (payload.v >= 5) and tonumber(payload.rf) or 11

        if type(payload.r) == "string" and rf and rf >= 11 and rf <= 32 then
            -- Packed (base64). Opaque to the server, so validate shape only:
            -- charset and a size ceiling derived from the worst-case sample
            -- width. It is replayed client-side as the submitter's own ghost,
            -- so garbage can only ever spoil their own replay.
            local maxBytes = math.ceil(((Config.MaxMotionSamples or 7500) * 32 + 64) * 4 / 3) + 8
            if #payload.r >= 16 and #payload.r <= maxBytes
               and payload.r:match("^[A-Za-z0-9+/=]+$") then
                motion, stride = payload.r, rf
            end

        elseif type(payload.r) == "table" and rf and rf >= 11 and rf <= 32 then
            local rn   = #payload.r
            local maxN = (Config.MaxMotionSamples or 7500) * rf
            if rn >= rf * 4 and rn % rf == 0 and rn <= maxN then
                local clean = true
                for i = 1, rn do
                    if type(payload.r[i]) ~= "number" then clean = false; break end
                end
                if clean then motion, stride = payload.r, rf end
            end
        end
    end

    -- Vehicle spec header — stored verbatim but only as a plain table, and only
    -- alongside a valid motion stream.
    local spec = (motion and payload.v >= 5 and type(payload.s) == "table") and payload.s or nil

    -- Normalise for storage (splits may be empty table for v2 upgrades)
    local stored = { v = motion and 5 or 3, m = payload.m, p = flat, c = splits or {} }
    if motion then
        stored.r  = motion
        stored.rf = stride
        stored.s  = spec
    end

    -- Who holds this track's record BEFORE the write — to detect a steal.
    local prevRows = MySQL.query.await([[
        SELECT r.player_id, r.best_ms, pl.username
        FROM racelines r JOIN players pl ON pl.id = r.player_id
        WHERE r.track = ? ORDER BY r.best_ms ASC LIMIT 1
    ]], { track })
    local prev = prevRows and prevRows[1]

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

    print(("^2[raceline] Stored %s for player %d: %d ms, %d points%s.^7")
        :format(track, p.pid, p.ms, n / 5, motion and " (+ motion)" or ""))

    TriggerClientEvent("spz-raceline:saved", src, track, p.ms, { x = flat[1], y = flat[2], z = flat[3] })

    -- New TRACK record (fastest line for this track, any player)? crown.lua
    -- broadcasts the steal and refreshes crown statebags; this file clears its
    -- ghost-record cache (handler near RecordCache below).
    if not prev or p.ms < prev.best_ms then
        local newName = MySQL.scalar.await(
            "SELECT username FROM players WHERE id = ? LIMIT 1", { p.pid }) or "Driver"
        TriggerEvent("spz-raceline:recordTaken", {
            track   = track,
            newPid  = p.pid, newName = newName, newMs = p.ms, newSrc = src,
            oldPid  = prev and prev.player_id or nil,
            oldName = prev and prev.username or nil,
            oldMs   = prev and prev.best_ms or nil,
        })
    end
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

    -- Every failure below answers the client instead of going quiet. A request
    -- that is never answered leaves PendingLoad set for the rest of the
    -- session, so the display sits at track=nil and the next attempt to load
    -- the same track is indistinguishable from a lost packet.
    local pid = PlayerDbId(src)
    if not pid then
        TriggerClientEvent("spz-raceline:line", src, track, nil, nil, "no profile")
        return
    end

    local rows = MySQL.query.await(
        "SELECT points, best_ms FROM racelines WHERE player_id = ? AND track = ? LIMIT 1",
        { pid, track }
    )
    local row = rows and rows[1]
    if not row then
        TriggerClientEvent("spz-raceline:line", src, track, nil, nil, "no stored line")
        return
    end

    local ok, flat = pcall(json.decode, row.points)
    if not ok or type(flat) ~= "table" then
        print(("^1[raceline] Stored line for %s (player %d) is not decodable JSON.^7"):format(track, pid))
        TriggerClientEvent("spz-raceline:line", src, track, nil, nil, "stored line corrupt")
        return
    end

    -- LATENT: a v5 line carries the packed motion stream (~100 KB), which a
    -- plain reliable event can silently drop — the ghost would then never load.
    TriggerLatentClientEvent("spz-raceline:line", src, 200000, track, flat, row.best_ms)
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

    TriggerLatentClientEvent("spz-raceline:recordLine", src, 200000,
        track, rec.points, rec.best, rec.holder)
end)

-- Summary only (no line payload) — for menus/leaderboards
exports("GetRecordSummary", function(track)
    local rec = GetRecordRow(track)
    if not rec.best then return nil end
    return { best = rec.best, holder = rec.holder }
end)

-- A new track record just landed: drop the cached ghost-record row so the next
-- fetch reflects the new holder immediately.
AddEventHandler("spz-raceline:recordTaken", function(info)
    if info and info.track then RecordCache[info.track] = nil end
end)

AddEventHandler("playerDropped", function()
    Pending[source] = nil
end)
