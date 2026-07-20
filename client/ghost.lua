-- client/ghost.lua
-- Time-trial ghost car: replays the player's stored best-lap line as a local,
-- translucent, non-collidable vehicle. Starts in sync with each lap (CP1
-- crossing) and fades out when its lap is done; you race your own best.
--
-- Timing: v2/v3 lines carry per-point ms-since-lap-start, so the ghost brakes and
-- accelerates exactly where you did. v1 lines (recorded before timing existed)
-- get distance-proportional timing over the stored lap time — constant pace,
-- still a usable reference.
--
-- The line also carries CP split times (v3) for pace comparison at each
-- checkpoint, but the ghost itself runs a clean full-lap replay driven
-- entirely by per-point timing — no clock corrections mid-lap.
--
-- Reads the line cache from client/main.lua via the RL_GetEntry global (both
-- files share this resource's Lua environment).

local GC = Config.Ghost or { enabled = false }

local GhostOn    = GC.enabled ~= false   -- user toggle (/raceline ghost)
local TTTrack    = nil
local GhostVeh   = 0
local Route      = nil    -- { pts, times (cumulative ms), model }
local Running    = false
local RunStart   = 0      -- GetGameTimer() at lap start
local Cursor     = 1      -- current segment index (monotonic per run)
local CurHeading = 0.0

-- ── Route preparation ─────────────────────────────────────────────────────────

local function BuildRoute(entry)
    local pts = entry.points
    if not pts or #pts < 3 then return nil end

    local times = {}
    if pts[1].t ~= nil and pts[#pts].t ~= nil and pts[#pts].t > 0 then
        -- v2/v3: true captured timing
        for i = 1, #pts do times[i] = pts[i].t or 0 end
    else
        -- v1 fallback: distribute the stored lap time over cumulative distance
        local total, cum = 0.0, { 0.0 }
        for i = 2, #pts do
            local dx, dy = pts[i].x - pts[i-1].x, pts[i].y - pts[i-1].y
            total = total + math.sqrt(dx * dx + dy * dy)
            cum[i] = total
        end
        local lapMs = entry.best or 60000
        for i = 1, #pts do
            times[i] = total > 0 and math.floor(cum[i] / total * lapMs) or 0
        end
    end

    return {
        pts   = pts,
        times = times,
        model = (entry.model and entry.model ~= 0) and entry.model or GC.fallbackModel,
    }
end

-- ── Ghost entity ──────────────────────────────────────────────────────────────

local function DeleteGhost()
    Running = false
    if GhostVeh ~= 0 and DoesEntityExist(GhostVeh) then
        DeleteEntity(GhostVeh)
    end
    GhostVeh = 0
end

local function SpawnGhost(model, at, heading)
    if not IsModelInCdimage(model) then model = GC.fallbackModel end
    RequestModel(model)
    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(model) and GetGameTimer() < deadline do Wait(25) end
    if not HasModelLoaded(model) then return false end

    -- Local-only (not networked): nobody else sees another player's ghost
    GhostVeh = CreateVehicle(model, at.x, at.y, at.z + (GC.zLift or 0.45), heading, false, false)
    SetModelAsNoLongerNeeded(model)
    if GhostVeh == 0 then return false end

    SetEntityAlpha(GhostVeh, GC.alpha or 150, false)
    SetEntityCollision(GhostVeh, false, false)
    SetEntityInvincible(GhostVeh, true)
    FreezeEntityPosition(GhostVeh, true)   -- we drive it by hand every frame
    SetVehicleEngineOn(GhostVeh, true, true, false)
    SetVehicleLights(GhostVeh, 2)
    return true
end

-- ── Replay ────────────────────────────────────────────────────────────────────

local function StartRun()
    if not GhostOn or not TTTrack then return end
    local entry = RL_GetEntry and RL_GetEntry(TTTrack)
    if not entry then return end

    Route = BuildRoute(entry)
    if not Route then return end

    local p1, p2 = Route.pts[1], Route.pts[2]
    local heading = math.deg(math.atan(-(p2.x - p1.x), p2.y - p1.y)) % 360

    if GhostVeh == 0 or not DoesEntityExist(GhostVeh) then
        if not SpawnGhost(Route.model, p1, heading) then return end
    else
        SetEntityCoordsNoOffset(GhostVeh, p1.x, p1.y, p1.z + (GC.zLift or 0.45), false, false, false)
        SetEntityHeading(GhostVeh, heading)
    end

    SetEntityVisible(GhostVeh, true, false)
    CurHeading = heading
    Cursor     = 1
    RunStart   = GetGameTimer()
    Running    = true
end

local function LerpAngle(a, b, f)
    local diff = (b - a + 180.0) % 360.0 - 180.0
    return (a + diff * math.min(f, 1.0)) % 360.0
end

CreateThread(function()
    while true do
        if Running and GhostVeh ~= 0 and DoesEntityExist(GhostVeh) then
            local elapsed = GetGameTimer() - RunStart
            local pts, times = Route.pts, Route.times
            local n = #pts

            -- advance the cursor (monotonic; never scans the whole array)
            while Cursor < n - 1 and times[Cursor + 1] <= elapsed do
                Cursor = Cursor + 1
            end

            if elapsed >= times[n] then
                -- Ghost lap done: hide and wait for the player's next lap
                SetEntityVisible(GhostVeh, false, false)
                Running = false
            else
                local a, b   = pts[Cursor], pts[Cursor + 1]
                local ta, tb = times[Cursor], times[Cursor + 1]
                local span   = tb - ta
                local f      = span > 0 and (elapsed - ta) / span or 0.0

                local x = a.x + (b.x - a.x) * f
                local y = a.y + (b.y - a.y) * f
                local z = a.z + (b.z - a.z) * f + (GC.zLift or 0.45)

                local target = math.deg(math.atan(-(b.x - a.x), b.y - a.y)) % 360
                CurHeading = LerpAngle(CurHeading, target, (GC.headingLerp or 10.0) * GetFrameTime())

                SetEntityCoordsNoOffset(GhostVeh, x, y, z, false, false, false)
                SetEntityHeading(GhostVeh, CurHeading)

                -- Camera must ignore the ghost too. Entity collision is off,
                -- but the gameplay cam still sweeps against it and gets shoved
                -- when you drive through the ghost — same bug as player cars.
                DisableCamCollisionForObject(GhostVeh)

                -- brake lights where you braked
                SetVehicleBrakeLights(GhostVeh, b.s == 2)
            end
            Wait(0)
        else
            Wait(250)
        end
    end
end)

-- ── Lifecycle (same TT events main.lua uses) ──────────────────────────────────

RegisterNetEvent("SPZ:tt:Begin", function(data)
    TTTrack = data and data.track and data.track.name or nil
    DeleteGhost()
end)

RegisterNetEvent("SPZ:tt:LapStarted", function()
    if not TTTrack then return end
    -- Restart the ghost in sync with the player's lap. RL_GetEntry is read
    -- fresh each lap, so a newly saved best becomes the ghost immediately.
    StartRun()
end)

RegisterNetEvent("SPZ:tt:Restarted", function()
    if GhostVeh ~= 0 then SetEntityVisible(GhostVeh, false, false) end
    Running = false
end)

RegisterNetEvent("SPZ:tt:End", function()
    TTTrack = nil
    DeleteGhost()
end)

AddEventHandler("onResourceStop", function(res)
    if res == GetCurrentResourceName() then DeleteGhost() end
end)

-- ── Toggle (called from the /raceline command in main.lua) ───────────────────

function RL_GhostToggle()
    GhostOn = not GhostOn
    if not GhostOn then DeleteGhost() end
    return GhostOn
end
