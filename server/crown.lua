-- server/crown.lua
-- Track-record CROWNS. A player who currently holds the fastest stored line for
-- at least one track "wears a crown" — published as the statebag spz:records
-- (how many tracks they hold). Losing a record to someone else is a real,
-- broadcast event, not a silent DB update.

local function fmt(ms)
    if not ms or ms <= 0 then return "--:--.---" end
    local m = math.floor(ms / 60000)
    local s = math.floor((ms % 60000) / 1000)
    local t = ms % 1000
    return string.format("%d:%02d.%03d", m, s, t)
end

-- Map a stored player_id back to an online server source (nil if offline).
local function SrcFromPid(pid)
    for _, s in ipairs(GetPlayers()) do
        local src = tonumber(s)
        local ok, prof = pcall(function() return exports["spz-identity"]:GetProfile(src) end)
        if ok and prof and prof.id == pid then return src end
    end
    return nil
end

-- How many tracks this player currently holds the record on.
local function CountRecords(pid)
    local n = MySQL.scalar.await([[
        SELECT COUNT(*) FROM racelines r1
        WHERE r1.player_id = ?
          AND r1.best_ms = (
              SELECT MIN(r2.best_ms) FROM racelines r2 WHERE r2.track = r1.track
          )
    ]], { pid })
    return n or 0
end

-- Recompute and publish a player's crown count. Async: the COUNT hits the DB.
local function PublishCrown(src, pid)
    src = tonumber(src)
    if not src then return end
    CreateThread(function()
        if not pid then
            local ok, prof = pcall(function() return exports["spz-identity"]:GetProfile(src) end)
            pid = ok and prof and prof.id or nil
        end
        if not pid then return end
        local state = Player(src).state
        if not state then return end
        state:set('spz:records', CountRecords(pid), true)
    end)
end
exports("PublishCrown", PublishCrown)

-- ── Record changed hands ─────────────────────────────────────────────────────
AddEventHandler("spz-raceline:recordTaken", function(info)
    if not info or not info.track then return end

    -- Refresh crown counts for the new holder and (if online) the dethroned one.
    PublishCrown(info.newSrc, info.newPid)
    if info.oldPid and info.oldPid ~= info.newPid then
        local oldSrc = SrcFromPid(info.oldPid)
        if oldSrc then PublishCrown(oldSrc, info.oldPid) end
    end

    -- Announce only a genuine change of hands or a brand-new record. A holder
    -- improving their own time is not news.
    local text
    if info.oldPid and info.oldPid ~= info.newPid then
        text = ("%s snatched the %s record from %s  (%s -> %s)"):format(
            info.newName or "Driver", info.track, info.oldName or "?",
            fmt(info.oldMs), fmt(info.newMs))
    elseif not info.oldPid then
        text = ("%s set the first %s record  (%s)"):format(
            info.newName or "Driver", info.track, fmt(info.newMs))
    else
        return   -- same holder, just faster
    end

    TriggerClientEvent("SPZ:recordStolen", -1, {
        text  = text,
        track = info.track,
        thief = info.newName,
        victim = info.oldName,
    })

    pcall(function()
        exports["spz-log"]:Log("race", "Track Record", text, "warning")
    end)
end)

-- ── Initial publish ──────────────────────────────────────────────────────────
AddEventHandler("SPZ:playerReady", function(source)
    PublishCrown(source)
end)

-- Resource restart: republish for everyone already online.
CreateThread(function()
    Wait(3000)
    for _, s in ipairs(GetPlayers()) do
        PublishCrown(tonumber(s))
    end
end)
