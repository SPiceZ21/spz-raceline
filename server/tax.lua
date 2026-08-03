-- server/tax.lua
-- Track ownership tax. A passive credit trickle to every player who currently
-- holds at least one track record, scaled by how many they hold. The crown
-- pays rent, so records are worth defending, not just setting.
--
-- Reads the spz:records crown count published by crown.lua — no extra DB work.

local T = Config.Tax or {}
if T.enabled == false then return end

local INTERVAL  = T.intervalMs or 600000
local PER_TRACK = T.perTrack or 25

CreateThread(function()
    while true do
        Wait(INTERVAL)

        for _, s in ipairs(GetPlayers()) do
            local src   = tonumber(s)
            local state = src and Player(src).state
            local held  = state and state['spz:records'] or 0

            if held > 0 then
                local pay = held * PER_TRACK
                local profile = exports["spz-identity"]:GetProfile(src)
                if profile then
                    exports["spz-identity"]:UpdateProfile(src, {
                        credits = (profile.credits or 0) + pay,
                    })
                    TriggerClientEvent("SPZ:trackTax", src, { credits = pay, tracks = held })
                end
            end
        end
    end
end)
