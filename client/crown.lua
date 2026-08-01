-- client/crown.lua
-- Renders a gold crown marker above any player who holds a track record
-- (statebag spz:records > 0), and toasts when a record changes hands.

local RANGE = 60.0

CreateThread(function()
    while true do
        local sleep = 500
        local myPed = PlayerPedId()
        local myPos = GetEntityCoords(myPed)

        for _, plr in ipairs(GetActivePlayers()) do
            local sid  = GetPlayerServerId(plr)
            local recs = Player(sid).state['spz:records']

            if recs and recs > 0 then
                local ped = GetPlayerPed(plr)
                if ped ~= 0 and DoesEntityExist(ped) then
                    local pos = GetEntityCoords(ped)
                    if #(myPos - pos) < RANGE then
                        sleep = 0
                        local off = IsPedInAnyVehicle(ped, false) and 1.65 or 1.2
                        -- Type 0 = downward chevron; hovers, bobs, faces camera.
                        DrawMarker(0, pos.x, pos.y, pos.z + off,
                            0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                            0.35, 0.35, 0.35,
                            255, 190, 40, 200,
                            true, true, 2, false, nil, nil, false)
                    end
                end
            end
        end

        Wait(sleep)
    end
end)

RegisterNetEvent("SPZ:recordStolen", function(d)
    if not d or not d.text then return end
    lib.notify({
        title       = "TRACK RECORD",
        description  = d.text,
        type        = "warning",
        duration    = 7000,
        position    = "top",
        icon        = "crown",
    })
end)
