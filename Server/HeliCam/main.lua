
package.loaded["libs/TriggerClientEvent"] = nil
local TriggerClientEvent = require("libs/TriggerClientEvent")


function heliCamUpdate(player_id, data)
	local data = Util.JsonDecode(data)
	if type(data) ~= "table" then return end
	
	data.player_id = player_id
	TriggerClientEvent:broadcastExcept(player_id, 'heliCamUpdate', data)
end

function onPlayerJoin(player_id)
	TriggerClientEvent:set_synced(player_id)
end

function onPlayerDisconnect(player_id)
	TriggerClientEvent:remove(player_id)
end

function onInit()
	MP.RegisterEvent("onPlayerJoin", "onPlayerJoin")
	MP.RegisterEvent("onPlayerDisconnect", "onPlayerDisconnect")
	MP.RegisterEvent("heliCamUpdate", "heliCamUpdate")
	
	for player_id, _ in pairs(MP.GetPlayers() or {}) do
		onPlayerJoin(player_id)
	end
end
