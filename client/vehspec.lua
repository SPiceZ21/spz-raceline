-- client/vehspec.lua
-- Vehicle spec header for the ghost.
--
-- The line used to store only the model hash, so the ghost always appeared as a
-- bone-stock car — different paint, stock wheels, no livery. This snapshots the
-- car you actually drove (once per lap, not per sample) so the replay is your
-- car, not a lookalike.

-- Index mods: 0-16 are the visual/performance slots, 23/24 are wheels (front /
-- rear for bikes). 17-22 are on/off toggles and go through ToggleVehicleMod.
local INDEX_MODS  = { 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,23,24,48 }
local TOGGLE_MODS = { 17,18,19,20,21,22 }

--- Snapshot everything that makes this car look like itself.
function RL_SpecCapture(veh)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil end

    local pri, sec     = GetVehicleColours(veh)
    local pearl, wheel = GetVehicleExtraColours(veh)

    local spec = {
        model      = GetEntityModel(veh),
        col        = { pri, sec },
        extraCol   = { pearl, wheel },
        wheelType  = GetVehicleWheelType(veh),
        tint       = GetVehicleWindowTint(veh),
        plate      = GetVehicleNumberPlateText(veh),
        plateIdx   = GetVehicleNumberPlateTextIndex(veh),
        dirt       = GetVehicleDirtLevel(veh),
        mods       = {},
        toggles    = {},
        extras     = {},
    }

    -- Custom RGB paint overrides the palette index when set.
    if GetIsVehiclePrimaryColourCustom(veh) then
        spec.customPri = { GetVehicleCustomPrimaryColour(veh) }
    end
    if GetIsVehicleSecondaryColourCustom(veh) then
        spec.customSec = { GetVehicleCustomSecondaryColour(veh) }
    end

    for _, slot in ipairs(INDEX_MODS) do
        local m = GetVehicleMod(veh, slot)
        if m and m ~= -1 then
            spec.mods[tostring(slot)] = { m, GetVehicleModVariation(veh, slot) and 1 or 0 }
        end
    end

    for _, slot in ipairs(TOGGLE_MODS) do
        if IsToggleModOn(veh, slot) then spec.toggles[tostring(slot)] = 1 end
    end

    for i = 0, 14 do
        if DoesExtraExist(veh, i) then
            spec.extras[tostring(i)] = IsVehicleExtraTurnedOn(veh, i) and 1 or 0
        end
    end

    -- Lighting + tyres
    spec.xenon = GetVehicleXenonLightsColour and GetVehicleXenonLightsColour(veh) or nil
    local nr, ng, nb = GetVehicleNeonLightsColour(veh)
    spec.neonCol = { nr, ng, nb }
    spec.neon = {}
    for i = 0, 3 do
        spec.neon[i + 1] = IsVehicleNeonLightEnabled(veh, i) and 1 or 0
    end
    local sr, sg, sb = GetVehicleTyreSmokeColor(veh)
    spec.smoke = { sr, sg, sb }

    return spec
end

--- Rebuild the look on the ghost. Silently skips anything the model lacks.
function RL_SpecApply(veh, spec)
    if not spec or not veh or veh == 0 or not DoesEntityExist(veh) then return end

    SetVehicleModKit(veh, 0)   -- required before any SetVehicleMod call

    if spec.col then SetVehicleColours(veh, spec.col[1] or 0, spec.col[2] or 0) end
    if spec.extraCol then SetVehicleExtraColours(veh, spec.extraCol[1] or 0, spec.extraCol[2] or 0) end
    if spec.customPri then
        SetVehicleCustomPrimaryColour(veh, spec.customPri[1], spec.customPri[2], spec.customPri[3])
    end
    if spec.customSec then
        SetVehicleCustomSecondaryColour(veh, spec.customSec[1], spec.customSec[2], spec.customSec[3])
    end

    if spec.wheelType then SetVehicleWheelType(veh, spec.wheelType) end

    for slot, m in pairs(spec.mods or {}) do
        SetVehicleMod(veh, tonumber(slot), m[1], (m[2] == 1))
    end
    for slot in pairs(spec.toggles or {}) do
        ToggleVehicleMod(veh, tonumber(slot), true)
    end
    for i, on in pairs(spec.extras or {}) do
        SetVehicleExtra(veh, tonumber(i), on == 1 and 0 or 1)   -- 0 = enabled
    end

    if spec.tint then SetVehicleWindowTint(veh, spec.tint) end
    if spec.plate then SetVehicleNumberPlateText(veh, spec.plate) end
    if spec.plateIdx then SetVehicleNumberPlateTextIndex(veh, spec.plateIdx) end
    if spec.dirt then SetVehicleDirtLevel(veh, spec.dirt + 0.0) end

    if spec.xenon then SetVehicleXenonLightsColour(veh, spec.xenon) end
    if spec.neonCol then SetVehicleNeonLightsColour(veh, spec.neonCol[1], spec.neonCol[2], spec.neonCol[3]) end
    for i = 0, 3 do
        SetVehicleNeonLightEnabled(veh, i, (spec.neon and spec.neon[i + 1] == 1) or false)
    end
    if spec.smoke then SetVehicleTyreSmokeColor(veh, spec.smoke[1], spec.smoke[2], spec.smoke[3]) end
end
