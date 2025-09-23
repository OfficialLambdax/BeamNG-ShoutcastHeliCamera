--[[
	License: MIT
	Author: Neverless (discord: neverless.)
]]
--[[
	Todo
		- Spotlight rotation sync improvements
		- Consider to only eval heli t_pos in fixed rates to relieve the cpu enough that we can implement heavier t_pos eval algorhytms.
		- Adjustable heli loudness (as global, so to also influence to us remote heli sounds)
		- Rotation Bug: Directly flying up/down while not moving in any other direction aligns the heli front nose up/down
]]

package.loaded["HeliCam/libs/PhysicsActor"] = nil
package.loaded["HeliCam/defs/HonorableMentions"] = nil
package.loaded["HeliCam/defs/SpotlightTypes"] = nil
local PhysicsActor = require("HeliCam/libs/PhysicsActor")
local HonorableMentions = require("HeliCam/defs/HonorableMentions")
local SpotlightTypes = require("HeliCam/defs/SpotlightTypes")

local DRAW_TEXTADVANCED = ffi.C.BNG_DBG_DRAW_TextAdvanced

local M = {}

local VERSION = '0.52' -- 23.09.2025 (DD.MM.YYYY)

local CAM_NAME = 'helicam'
local SPECTATE_SOUND

local IS_SPAWNED = false
local IS_CAM = false
local UI_RENDER = true
local DEBUG_RENDER = false

local HELI
local HELI_MASS = 100
local HELI_MAX_THRUST = 1500
local HELI_BRAKE_DIST = 400 -- m
local HELI_MAX_SPEED = 100 -- ms
local HELI_MAX_THROTTLE_RANGE = 5 -- ms
local HELI_TARGET_ALT = 150
local HELI_CIRCLE_RADIUS = 200
local HELI_SPOTLIGHT = false
local HELI_AUTO_DESPAWN = true

local HELI_SPOTLIGHT_DRAW_SHADOWS = true
local HELI_SPOTLIGHT_TYPE = 1
local HELI_SPOTLIGHT_TYPE_DEF = SpotlightTypes
--[[
	1 = on vehicle
	2 = move with camera
]]
local HELI_SPOTLIGHT_MODE = 1

local HELI_CONTROL = false
local HELI_CONTROL_INPUTS = {
	radius = 0,
	radius_up = 0,
	radius_down = 0,
	altitude = 0,
	altitude_up = 0,
	altitude_down = 0
}

local HELI_MODE = 2
local MODE_CLEAR_NAME = {
	[1] = 'Hover above Vehicle',
	[2] = 'Circle around Vehicle',
	[3] = 'Close to vehicle',
	[4] = 'Front',
	[5] = 'Right',
	[6] = 'Behind',
	[7] = 'Left',
	[8] = 'Still',
	--[9] = 'Trajectory',
}

local MODE_AUTO_TP = true
local MODE_TP_DIST = 1500
local MODE_AUTO_ROT = true
local MODE_AUTO_FOV = true
local MODE_ROT_SMOOTHER = 5

-- Custom player tags
local function rgbToColorF(r, g, b, a) return ColorF(r / 255, g / 255, b / 255, (a or 127) / 127) end
local PLAYER_TAG_DEFAULT_POSTFIX = ' [Heli]'
local PLAYER_TAG_TEST = nil
local PLAYER_TAGS = HonorableMentions

--[[
	Format
	["player_id"] = table
		[heli] = heli
		[remote_data] = remote_data
]]
local REMOTE_HELIS = {}
local REMOTE_SEND_TIMER = hptimer()

local IS_BEAMMP_SESSION = false
local MP_UPDATE_RATE = 250

local INPUT_LOCK_PAYLOAD = [[
	local function setInputLock(state)
		for name, _ in pairs(input.state) do
			input.setAllowedInputSource(name, "local", state)
		end
	end;
]]

local SPECTATOR_WHITELIST_VEHICLES = {}
local SPECTATOR_WHITELIST_PLAYERS = {}


-- ------------------------------------------------------------------
-- Common
local function boolOr(bool, var)
	if type(bool) == "boolean" then return bool end
	return var
end

local function vec2Array(vec)
	return {vec.x, vec.y, vec.z}
end

local function array2Vec(array)
	if #array < 3 then return end
	if type(array[1]) ~= "number" then return end
	if type(array[2]) ~= "number" then return end
	if type(array[3]) ~= "number" then return end
	return vec3(array)
end

local function adaptColor(from, into)
	into.r = from.r
	into.g = from.g
	into.b = from.b
	into.a = from.a
end

-- drop in replacement for debugDrawer:drawTextAdvanced()
local function drawTextAdvanced(pos, text, txt_color, bg_color)
	DRAW_TEXTADVANCED(
		pos.x, pos.y, pos.z,
		text,
		color(txt_color.r * 255, txt_color.g * 255, txt_color.b * 255, txt_color.a * 254),
		true, -- use advanced text
		false, -- twod
		color(bg_color.r, bg_color.g, bg_color.b, bg_color.a),
		false, -- shadow
		false -- use z
	)
end

local function inRange(x, t, y)
	return t > x and t < y
end

local function dist2d(p1, p2)
	return math.sqrt((p2.x - p1.x)^2 + (p2.y - p1.y)^2)
end

local function dist3d(p1, p2)
	return math.sqrt((p2.x - p1.x)^2 + (p2.y - p1.y)^2 + (p2.z - p1.z)^2)
end

local function isBeamMPSession()
	if MPCoreNetwork then return MPCoreNetwork.isMPSession() end
	return false
end

local function surfaceHeight(pos_vec)
	local pos_z = be:getSurfaceHeightBelow(vec3(pos_vec.x, pos_vec.y, pos_vec.z + 2))
	if pos_z < -1e10 then return end -- "the function returns -1e20 when the raycast fails"
	return pos_z
end

local function hasLineOfSight(from_vec, to_vec)
	local dir_vec = (to_vec - from_vec):normalized()
	local dist = dist3d(from_vec, to_vec)
	
	local hit_dist = castRayStatic(from_vec, dir_vec, dist)
	if hit_dist < dist then
		return false, dist
	end
	return true, dist
end

local function rotateVectorByDegrees(for_vec, up_vec, degrees)
	local a = for_vec
	local b = up_vec
	local q = degrees
	local c = a:cross(b)
	
	local term1 = a * math.cos(q)
	return vec3(
		term1.x + (c.x * math.sin(q)),
		term1.y + (c.y * math.sin(q)),
		term1.z + (c.z * math.sin(q))
	)
end

local function createCircle(pos_vec, radius, points, f_dir, u_dir)
	local c_pos = pos_vec
	local radius = radius or 5
	local points = points or 8
	local f_dir = f_dir or vec3(1, 0, 0)
	local u_dir = u_dir or vec3(0, 0, 1)
	local step = 6.28 / points
	
	local circle = {
		c_pos = c_pos,
		c_up = u_dir
	}
	
	for rot = 1, points, 1 do
		local r_pos = c_pos + (rotateVectorByDegrees(f_dir, u_dir, step * rot) * radius)
		table.insert(
			circle,
			r_pos
		)
	end
	
	return circle
end

local function filterCircleByLOS(circle, pos_vec)
	local new_circle = {}
	for _, pos in ipairs(circle) do
		if hasLineOfSight(pos, pos_vec) then
			table.insert(new_circle, pos)
		end
	end
	return new_circle
end

local function boolToOnOff(bool)
	if bool then return 'On' end
	return 'Off'
end

-- This isnt fully functional
-- https://gamedev.stackexchange.com/questions/69649/using-atan2-to-calculate-angle-between-two-vectors
local function dirAngle(dir_vec1, dir_vec2)
    return math.acos(dir_vec1:dot(dir_vec2))
    --return math.abs(math.atan2(dir_vec1.y, dir_vec1.x) - math.atan2(dir_vec2.y, dir_vec2.x))
    --return math.acos(dir_vec1:dot(dir_vec2) / (dir_vec1:length() * dir_vec2:length()))
end

local function tableVToK(table)
	local new_table = {}
	for _, v in pairs(table) do
		new_table[v] = true
	end
	return new_table
end

local function tableHasContent(table)
	return #({next(table)}) > 0
end

-- ------------------------------------------------------------------
-- MP Stuff
local function isBeamMPSession()
	if MPCoreNetwork then return MPCoreNetwork.isMPSession() end
	return false
end

local function getPlayerNameFromVehicle(veh_id)
	if not IS_BEAMMP_SESSION then return nil end
	return (MPVehicleGE.getVehicleByGameID(veh_id) or{}).ownerName
end

local function getMyId()
	if not IS_BEAMMP_SESSION then return nil end
	local player_id = MPConfig.getPlayerServerID()
	if player_id == -1 then return end
	return player_id
end

local function getPlayerNameFromId(player_id)
	if not IS_BEAMMP_SESSION then return nil end
	return (MPVehicleGE.getPlayers()[player_id] or {}).name
end

local function isOwn(game_vehicle_id)
	if not IS_BEAMMP_SESSION then return true end
	return MPVehicleGE.isOwn(game_vehicle_id)
end

-- ------------------------------------------------------------------
-- Spectator whitelist stuff
local function evalValidSpectatedVehicles() -- produces duplicates
	local vehicles = {}
	for veh_id, _ in pairs(SPECTATOR_WHITELIST_VEHICLES) do
		local vehicle = getObjectByID(veh_id)
		if not vehicle then
			SPECTATOR_WHITELIST_VEHICLES[veh_id] = nil
		else
			table.insert(vehicles, vehicle)
		end
	end
	
	if IS_BEAMMP_SESSION then
		for player_name, _ in pairs(SPECTATOR_WHITELIST_PLAYERS) do
			for _, veh_data in pairs(MPVehicleGE.getPlayerByName(player_name).vehicles) do
				local vehicle = getObjectByID(veh_data.gameVehicleID)
				if vehicle then
					table.insert(vehicles, vehicle)
				end
			end
		end
	end
	
	return vehicles
end

local function evalSpectatorShip()
	local change = false
	local vehicle = getPlayerVehicle(0)
	if not vehicle then
		change = true
		
	else
		if tableHasContent(SPECTATOR_WHITELIST_VEHICLES) then
			change = SPECTATOR_WHITELIST_VEHICLES[vehicle:getId()] == nil
		end
		if not change and IS_BEAMMP_SESSION and tableHasContent(SPECTATOR_WHITELIST_PLAYERS) then
			change = SPECTATOR_WHITELIST_PLAYERS[getPlayerNameFromVehicle(vehicle:getId())] == nil
		end
	end
	
	if change then
		local valid_vehicles = evalValidSpectatedVehicles()
		if tableHasContent(valid_vehicles) then
			local random = valid_vehicles[math.random(1, #valid_vehicles)]
			be:enterVehicle(0, random)
		end
	end
end

-- ------------------------------------------------------------------
-- Cam update
local function updateCam(vehicle, dt)
	local cam_name = core_camera.getActiveCamName()
	if cam_name ~= CAM_NAME then
		if cam_name ~= "free" then
			core_camera.setByName(CAM_NAME)
		else
			return nil
		end
	end
	
	local tar_pos = vehicle:getPosition()
	local cam_pos = HELI:getPosition()
	cam_pos.z = cam_pos.z - 1
	local dist = dist3d(tar_pos, cam_pos)
	local pre_pos
	if simTimeAuthority.getPause() then
		pre_pos = tar_pos
	else
		--[[
		local tar_vel = vehicle:getVelocity()
		local speed_factor = math.min(1, tar_vel:length() / 5)
		local dist_factor = 0.5 - clamp((dist / 20) * 0.035, 0, 0.35)
		pre_pos = tar_pos + (speed_factor * (tar_vel * dist_factor))
		]]
		
		-- Essentially: Aim at a pos in front of the vehicle. The closer we are to the vehicle the further but only if the angle between vel dir and cam dir to veh dir is small. or in other words: aim ahead if we are behind vehicle, aim only half as much ahead if we are at the side, dont aim ahead at all if we are ahead of vehicle)
		local tar_vel = vehicle:getVelocity()
		local vel_dir = tar_vel:normalized()
		local speed = tar_vel:length()
		--local speed_factor = math.min(1, speed / 5)
		local speed_factor = clamp(speed / 5, 0, 1)
		local dist_factor = 0
		if dist < 60 and speed > 2 then
			local dir_dif = 2 - clamp(dirAngle(vel_dir, (tar_pos - cam_pos):normalized()), 0, 2)
			dist_factor = (3 - clamp((dist / 60) * 3, 0, 3)) * dir_dif
		end
		pre_pos = tar_pos + (vel_dir * 5 * (speed_factor + dist_factor))
	end
	
	core_camera:setPosition(cam_pos)
	if MODE_AUTO_ROT then
		-- smooth rotate
		local tar_dir = (pre_pos - cam_pos):normalized() -- what we want to point to
		local c_dir = core_camera:getForward() -- where we are currently pointing to
		
		local s_dir = (tar_dir - c_dir) * MODE_ROT_SMOOTHER * dt -- step rotate by this amount
		local t_dir = c_dir + s_dir -- apply to current rot
		
		core_camera:setRotation(quatFromDir(
			t_dir,
			vec3(0, 0, 1)
		))
		
		if DEBUG_RENDER then
			debugDrawer:drawSphere(pre_pos, 1, ColorF(0, 0, 1, 1))
			debugDrawer:drawText(pre_pos + vec3(0, 0, 2), 'Cam target', ColorF(0, 0, 1, 1))
		end
	end
	if MODE_AUTO_FOV then
		local fov = math.max(0, 40 - ((dist / 200) * 40))
		core_camera:setFOV(fov)
	end
end

-- ------------------------------------------------------------------
-- Target select
local function evalTargetHeightPos(pos_vec) -- for where pos_vec ~= heli pos
	local tar_z = (surfaceHeight(pos_vec) or pos_vec.z) + HELI_TARGET_ALT
	if pos_vec.z > tar_z then tar_z = pos_vec.z + HELI_TARGET_ALT end
	return vec3(
		pos_vec.x,
		pos_vec.y,
		tar_z
	)
end

local function evalTargetHeightPosHeli(pos_vec) -- for where pos_vec == heli pos
	local tar_z = (surfaceHeight(pos_vec) or pos_vec.z) + HELI_TARGET_ALT
	if pos_vec.z > tar_z then tar_z = pos_vec.z end
	return vec3(
		pos_vec.x,
		pos_vec.y,
		tar_z
	)
end

local function sortPointsFromCircleByDist(circle, pos_vec)
	local dists = {}
	for _, pos in ipairs(circle) do
		table.insert(dists, {dist = dist2d(pos, pos_vec), pos = pos})
	end
	table.sort(dists, function(x, y) return x.dist < y.dist end)
	return dists
end

local function evalClosestFromCircle2D(circle, h_pos)
	local closest_dist = 99999
	local closest_pos = h_pos
	for _, pos in ipairs(circle) do
		local dist = dist2d(pos, h_pos)
		if dist < closest_dist then
			closest_dist = dist
			closest_pos = pos
		end
	end
	return closest_pos
end

local function evalPosWithLOSToTarget(c_pos, t_pos, veh_pos)
	if hasLineOfSight(t_pos, veh_pos) then return t_pos end
	local dist = dist2d(t_pos, c_pos)
	local dir = (c_pos - t_pos):normalized()
	for index = 0, dist, 10 do
		local pos = t_pos + (dir * index)
		if hasLineOfSight(pos, veh_pos) then
			return pos + (dir * 20) -- landing on the edge of LOS usually leads to well being on the edge
		--else
		--	debugDrawer:drawSphere(pos, 1, ColorF(1, 0, 0, 1))
		end
		--debugDrawer:drawText(pos + vec3(0, 0, 5), index, ColorF(0, 0, 1, 1))
	end
	return t_pos -- no point with LOS
end

-- reduced precision because this is cpu heavy
-- c_pos = center of circle, h_pos = current heli pos, veh_pos, actual target veh pos
local function findClosestFromCircleWithLOS2D(circle, c_pos, h_pos, veh_pos)
	local dists = sortPointsFromCircleByDist(circle, h_pos)
	local dist_to_c = dist2d(c_pos, dists[1].pos) -- dist from all circle posses to center is the same
	for _, pos in ipairs(dists) do
		pos = pos.pos
		if hasLineOfSight(pos, veh_pos) then return pos end -- if pos has direct line of sight then easy
		
		-- otherwise step from pos towards center
		local c_dir = (c_pos - pos):normalized()
		for index = 0, dist_to_c, 40 do
			local t_pos = pos + (c_dir * index)
			if hasLineOfSight(t_pos, veh_pos) then
				--debugDrawer:drawSphere(t_pos + (c_dir * 20), 1, ColorF(0, 1, 0, 1))
				return t_pos + (c_dir * 20)
			--else
				--debugDrawer:drawSphere(t_pos, 1, ColorF(1, 0, 0, 1))
			end
			--debugDrawer:drawText(t_pos + vec3(0, 0, 5), index, ColorF(0, 0, 1, 1))
		end
	end
	return c_pos -- if none
end

-- ------------------------------------------------------------------
-- Player own Heli AI setters
local function increaseAlt(amount)
	HELI_TARGET_ALT = math.max(10, HELI_TARGET_ALT + amount)
	--log('I', 'Set altitude to ' .. math.floor(HELI_TARGET_ALT) .. ' meters')
end

local function increaseRadius(amount)
	HELI_CIRCLE_RADIUS = math.max(20, HELI_CIRCLE_RADIUS + amount)
	--log('I', 'Set radius to ' .. math.floor(HELI_CIRCLE_RADIUS) .. ' meters')
end

local function increaseThrust(amount)
	HELI_MAX_THRUST = math.max(0, HELI_MAX_THRUST + amount)
	--log('I', 'Set max thrust to ' .. math.floor(HELI_MAX_THRUST))
end

local function increaseRotSmoother(amount)
	MODE_ROT_SMOOTHER = math.max(0, MODE_ROT_SMOOTHER + amount)
	---log('I', 'Set rotation smoother to ' .. MODE_ROT_SMOOTHER)
end

-- ------------------------------------------------------------------
-- Player own Heli AI and Physics Controller
local function spawnHeli()
	if not HELI or IS_SPAWNED then return end
	local tar_veh = getPlayerVehicle(0)
	if not tar_veh then return end
	
	HELI:setPosition(tar_veh:getPosition() + vec3(0, 0, 20))
	HELI:setVelocity(vec3(0, 0, 0))
	IS_SPAWNED = true
end

local function modeDirect(self, dt, tar_veh)
	-- heli
	local c_pos = self:getPosition()
	local c_vel = self:getVelocity()
	
	-- target
	local v_pos = tar_veh:getSpawnWorldOOBB():getCenter()
	local t_pos = evalTargetHeightPos(v_pos)
	local t_vel = tar_veh:getVelocity()
	
	return v_pos, c_pos, c_vel, t_pos, t_vel
end

local function modeCircle(self, dt, tar_veh)
	-- heli
	local c_pos = self:getPosition()
	local c_vel = self:getVelocity()
	
	-- target
	local v_pos = tar_veh:getSpawnWorldOOBB():getCenter()
	local t_pos = evalTargetHeightPos(v_pos)
	local t_vel = tar_veh:getVelocity()
	
	-- circle flight when close to vehicle
	if dist2d(t_pos, c_pos) < HELI_CIRCLE_RADIUS * 1.3 then
		local circle = createCircle(t_pos, HELI_CIRCLE_RADIUS, 30)
		local data = self:getData()
		local switch = dist2d(circle[data.index], c_pos) < 60
		if hasLineOfSight(circle[data.index], v_pos) then
			data.los_timer:stopAndReset()
		elseif not switch and data.los_timer:stop() > 1000 then
			data.los_timer:stopAndReset()
			switch = true
		end
		if switch then
			data.index = data.index + 1
			if data.index > #circle then data.index = 1 end
		end
		
		--t_pos = circle[data.index]
		t_pos = evalPosWithLOSToTarget(t_pos, circle[data.index], v_pos)
		
		if DEBUG_RENDER then
			local circle_pos = evalTargetHeightPos(v_pos)
			for _, pos in ipairs(circle) do
				pos = evalPosWithLOSToTarget(circle_pos, pos, v_pos)
				if hasLineOfSight(pos, v_pos) then
					debugDrawer:drawSphere(pos, 1, ColorF(0, 1, 0, 1))
				else
					debugDrawer:drawSphere(pos, 1, ColorF(1, 0, 0, 1))
					debugDrawer:drawText(pos + vec3(0, 0, 5), 'No LOS', ColorF(1, 0, 0, 1))
				end
			end
			debugDrawer:drawCircle(v_pos + vec3(0, 0, HELI_TARGET_ALT), HELI_CIRCLE_RADIUS, 30, Point4F(1, 1, 1, 1))
			debugDrawer:drawSphere(t_pos, 2, ColorF(0, 0, 1, 1))
			debugDrawer:drawText(t_pos + vec3(0, 0, 5), 'Target', ColorF(0, 0, 1, 1))
		end
	end
	
	return v_pos, c_pos, c_vel, t_pos, t_vel
end

local function modeClosest(self, dt, tar_veh)
	-- heli
	local c_pos = self:getPosition()
	local c_vel = self:getVelocity()
	
	-- target
	local v_pos = tar_veh:getSpawnWorldOOBB():getCenter()
	local t_pos = evalTargetHeightPos(v_pos)
	local t_vel = tar_veh:getVelocity()
	
	if dist2d(t_pos, c_pos) < HELI_CIRCLE_RADIUS * 1.3 then
		local circle = createCircle(t_pos, HELI_CIRCLE_RADIUS, 30)
		t_pos = findClosestFromCircleWithLOS2D(
			circle,
			t_pos,
			c_pos,
			v_pos
		)
		
		if DEBUG_RENDER then
			debugDrawer:drawCircle(v_pos + vec3(0, 0, HELI_TARGET_ALT), HELI_CIRCLE_RADIUS, 30, Point4F(1, 1, 1, 1))
			debugDrawer:drawSphere(t_pos, 2, ColorF(0, 0, 1, 1))
			debugDrawer:drawText(t_pos + vec3(0, 0, 5), 'Target', ColorF(0, 0, 1, 1))
		end
	end
	
	return v_pos, c_pos, c_vel, t_pos, t_vel
end

local function modeInFront(self, dt, tar_veh)
	-- heli
	local c_pos = self:getPosition()
	local c_vel = self:getVelocity()
	
	-- target
	local v_pos = tar_veh:getSpawnWorldOOBB():getCenter()
	local t_pos = evalTargetHeightPos(v_pos) -- center
	local t_vel = tar_veh:getVelocity()
	
	local t_dir = t_vel:normalized()
	if t_vel:length() < 5 then
		t_dir = tar_veh:getDirectionVector()
	end
	t_dir.z = 0
	
	t_pos = evalPosWithLOSToTarget(
		t_pos,
		evalTargetHeightPos(v_pos + (t_dir * HELI_CIRCLE_RADIUS)),
		v_pos
	)
	
	if DEBUG_RENDER then
		debugDrawer:drawSphere(t_pos, 2, ColorF(0, 0, 1, 1))
		debugDrawer:drawText(t_pos + vec3(0, 0, 5), 'Target', ColorF(0, 0, 1, 1))
	end
	
	return v_pos, c_pos, c_vel, t_pos, t_vel
end

local function modeRight(self, dt, tar_veh)
	-- heli
	local c_pos = self:getPosition()
	local c_vel = self:getVelocity()
	
	-- target
	local v_pos = tar_veh:getSpawnWorldOOBB():getCenter()
	local t_pos = evalTargetHeightPos(v_pos) -- center
	local t_vel = tar_veh:getVelocity()
	
	local t_dir = t_vel:normalized()
	if t_vel:length() < 5 then
		t_dir = tar_veh:getDirectionVector()
	end
	t_dir = vec3(t_dir.y, -t_dir.x, 0)
	
	t_pos = evalPosWithLOSToTarget(
		t_pos,
		evalTargetHeightPos(v_pos + (t_dir * HELI_CIRCLE_RADIUS)),
		v_pos
	)
	
	if DEBUG_RENDER then
		debugDrawer:drawSphere(t_pos, 2, ColorF(0, 0, 1, 1))
		debugDrawer:drawText(t_pos + vec3(0, 0, 5), 'Target', ColorF(0, 0, 1, 1))
	end
	
	return v_pos, c_pos, c_vel, t_pos, t_vel
end

local function modeLeft(self, dt, tar_veh)
	-- heli
	local c_pos = self:getPosition()
	local c_vel = self:getVelocity()
	
	-- target
	local v_pos = tar_veh:getSpawnWorldOOBB():getCenter()
	local t_pos = evalTargetHeightPos(v_pos) -- center
	local t_vel = tar_veh:getVelocity()
	
	local t_dir = t_vel:normalized()
	if t_vel:length() < 5 then
		t_dir = tar_veh:getDirectionVector()
	end
	t_dir = -vec3(t_dir.y, -t_dir.x, 0)
	
	t_pos = evalPosWithLOSToTarget(
		t_pos,
		evalTargetHeightPos(v_pos + (t_dir * HELI_CIRCLE_RADIUS)),
		v_pos
	)
	
	if DEBUG_RENDER then
		debugDrawer:drawSphere(t_pos, 2, ColorF(0, 0, 1, 1))
		debugDrawer:drawText(t_pos + vec3(0, 0, 5), 'Target', ColorF(0, 0, 1, 1))
	end
	
	return v_pos, c_pos, c_vel, t_pos, t_vel
end

local function modeBehind(self, dt, tar_veh)
	-- heli
	local c_pos = self:getPosition()
	local c_vel = self:getVelocity()
	
	-- target
	local v_pos = tar_veh:getSpawnWorldOOBB():getCenter()
	local t_pos = evalTargetHeightPos(v_pos) -- center
	local t_vel = tar_veh:getVelocity()
	
	local t_dir = t_vel:normalized()
	if t_vel:length() < 5 then
		t_dir = tar_veh:getDirectionVector()
	end
	t_dir.z = 0
	t_dir = -t_dir
	
	t_pos = evalPosWithLOSToTarget(
		t_pos,
		evalTargetHeightPos(v_pos + (t_dir * HELI_CIRCLE_RADIUS)),
		v_pos
	)
	
	if DEBUG_RENDER then
		debugDrawer:drawSphere(t_pos, 2, ColorF(0, 0, 1, 1))
		debugDrawer:drawText(t_pos + vec3(0, 0, 5), 'Target', ColorF(0, 0, 1, 1))
	end
	
	return v_pos, c_pos, c_vel, t_pos, t_vel
end

local function modeStill(self, dt, tar_veh)
	-- heli
	local c_pos = self:getPosition()
	local c_vel = self:getVelocity()
	
	-- target
	local v_pos = tar_veh:getSpawnWorldOOBB():getCenter()
	local t_pos = evalTargetHeightPosHeli(c_pos)
	local t_vel = tar_veh:getVelocity()
	
	return v_pos, c_pos, c_vel, t_pos, t_vel
end

-- bollocks
--[[
local function modeTrajectory(self, dt, tar_veh)
	-- heli
	local c_pos = self:getPosition()
	local c_vel = self:getVelocity()
	
	-- target
	local v_pos = tar_veh:getSpawnWorldOOBB():getCenter()
	
	local data = self:getData()
	local trajectory = data.trajectory
	if data.trajectory_timer:stop() > 150 or #trajectory == 0 then
		data.trajectory_timer:stopAndReset()
		for index = #trajectory, 1, -1 do
			trajectory[index + 1] = trajectory[index]
		end
		if #trajectory == 6 then trajectory[6] = nil end
		trajectory[1] = {
			pos = evalTargetHeightPos(tar_veh:getSpawnWorldOOBB():getCenter()),
			vel = tar_veh:getVelocity()
		}
	end
	
	local t_pos = trajectory[#trajectory].pos
	local t_vel = (trajectory[#trajectory - 1] or {}).vel or tar_veh:getVelocity()
	
	if DEBUG_RENDER then
		for _, pos in ipairs(trajectory) do
			debugDrawer:drawSphere(pos.pos, 1, ColorF(0, 1, 0, 1))
		end
		debugDrawer:drawSphere(t_pos, 2, ColorF(0, 0, 1, 1))
	end
	
	return v_pos, c_pos, c_vel, t_pos, t_vel
end
]]

local AI_MODE_HANDLER = {
	[1] = modeDirect,
	[2] = modeCircle,
	[3] = modeClosest,
	[4] = modeInFront,
	[5] = modeRight,
	[6] = modeBehind,
	[7] = modeLeft,
	[8] = modeStill,
	--[9] = modeTrajectory,
}
local function switchToMode(mode)
	HELI_MODE = mode
	if HELI_MODE > #AI_MODE_HANDLER then
		HELI_MODE = 1
	end
	log('I', 'Switched to ' .. MODE_CLEAR_NAME[HELI_MODE])
end

local function aiController(self, dt, tar_veh)
	local v_pos, c_pos, c_vel, t_pos, t_vel = AI_MODE_HANDLER[HELI_MODE](self, dt, tar_veh)

	local dist = dist3d(t_pos, c_pos)
	local dir_to_t = (t_pos - c_pos):normalized()
	
	-- predict position of target
	local r_vel = c_vel:length() - dir_to_t:dot(t_vel)
	local p_pos = t_pos + (t_vel * dist / math.abs(r_vel))
	if p_pos.x ~= p_pos.x then return end -- if nan
	
	-- create dir to intercept predicted position
	local dir_to_p_pos = (p_pos - c_pos):normalized()
	
	-- dist to predicted pos
	dist = dist3d(p_pos, c_pos)
	
	-- perform flight
	
	-- target velocity towards target
	local t_vel = dir_to_p_pos * math.min(HELI_MAX_SPEED, ((dist / HELI_BRAKE_DIST) * HELI_MAX_SPEED))
	
	-- difference to current velocity
	local d_vel = t_vel - c_vel
	
	-- thrust
	local thrust = math.min(HELI_MAX_THRUST, (d_vel:length() / HELI_MAX_THROTTLE_RANGE) * HELI_MAX_THRUST)
	
	-- set dir to thrust towards and thrust value
	self:setDirectionVector(d_vel:normalized()):setThrust(thrust)
	
	local data = self:getData()
	data.spotlight = HELI_SPOTLIGHT
	if HELI_SPOTLIGHT_MODE == 1 or core_camera.getActiveCamName() ~= CAM_NAME then
		local p_pos = v_pos + (tar_veh:getVelocity() * 0.05)
		data.spotlight_dir = (p_pos - c_pos):normalized()
		
	elseif HELI_SPOTLIGHT_MODE == 2 then
		data.spotlight_dir = core_camera:getForward()
	end
	
	if DEBUG_RENDER then
		local vel_dir_pos = c_pos + (c_vel:normalized() * ((c_vel:length() / HELI_MAX_SPEED) * 10))
		local thrust_dir_pos = c_pos + (d_vel:normalized() * ((thrust / HELI_MAX_THRUST) * 10))
		local pre_dir_pos = c_pos + (dir_to_p_pos * ((thrust / HELI_MAX_THRUST) * 10))
		
		debugDrawer:drawText(v_pos + vec3(0, 0, 1), 'x Target', ColorF(0, 0, 0, 1))
		
		debugDrawer:drawCircle(c_pos, 5, 30, Point4F(1, 1, 1, 1)) -- heli
		debugDrawer:drawText(c_pos, math.floor(c_vel:length() * 3.6) .. ' kph', ColorF(1, 1, 1, 1)) -- speed
		
		--debugDrawer:drawSphere(p_pos, 1, ColorF(0, 0, 1, 1)) -- tar pos
		
		debugDrawer:drawLine(c_pos, pre_dir_pos, ColorF(0, 0, 1, 1)) -- intercept dir
		debugDrawer:drawText(pre_dir_pos, 'Intercept dir', ColorF(0, 0, 1, 1))
		
		debugDrawer:drawLine(c_pos, vel_dir_pos, ColorF(0, 1, 0, 1)) -- actual vel dir
		debugDrawer:drawText(vel_dir_pos, 'Vel dir', ColorF(0, 1, 0, 1))
		
		debugDrawer:drawLine(c_pos, thrust_dir_pos, ColorF(1, 0, 0, 1)) -- thrust dir
		debugDrawer:drawText(thrust_dir_pos, 'Thrust dir', ColorF(1, 0, 0, 1))
	end
end

local function physicsController(self, dt, tar_veh)
	if simTimeAuthority.getPause() then return end
	
	local int = self:getInternal()
	local accel = int.thrust / int.mass
	int.vel = int.vel + (int.f_dir * accel * dt)
	int.pos = int.pos + (int.vel * dt)
end
-- ------------------------------------------------------------------
-- Remote Player Heli AI and Physics Controller
--[[
	Format
	[player_id] = int
	[state] = bool -- if false none of the below data is considered
	[spotlight] = bool
	[spotlight_type] = int -- todo
	[spotlight_dir] = {x, y, z}
	[pos] = {x, y, z}
	[f_dir] = {x, y, z}
	[vel] = {x, y, z}
	[thrust] = float
]]
local function decodeAndVerifyRemoteData(remote_data)
	if remote_data:len() > 500 then
		log('E', 'Received remote data has a odd size. Rejecting')
		return
	end
	
	local ok, remote_data = pcall(jsonDecode, remote_data)
	if not ok then
		log('E', 'Cannot decode remote data. Rejecting')
		return
	end
	
	if type(remote_data) ~= 'table' then log('E', 'remote_data is not of type table') return end
	if type(remote_data.player_id) ~= 'number' then log('E', 'remote_data.player_id is not of type number') return end
	if type(remote_data.state) ~= 'boolean' then log('E', 'remote_data.state is not of type bool') return end
	
	if remote_data.state == false then return remote_data end
	
	if type(remote_data.spotlight) ~= 'boolean' then log('E', 'remote_data.spotlight is not of type bool') return end
	if type(remote_data.spotlight_type) ~= 'number' then log('E', 'remote_data.spotlight_type is not of type number') return end
	if type(remote_data.spotlight_dir) ~= 'table' then log('E', 'remote_data.spotlight_dir is not of type table') return end
	if type(remote_data.pos) ~= 'table' then log('E', 'remote_data.pos is not of type table') return end
	if type(remote_data.f_dir) ~= 'table' then log('E', 'remote_data.f_dir is not of type table') return end
	if type(remote_data.vel) ~= 'table' then log('E', 'remote_data.vel is not of type table') return end
	if type(remote_data.thrust) ~= 'number' then log('E', 'remote_data.thrust is not of type number') return end
	
	remote_data.spotlight_dir = array2Vec(remote_data.spotlight_dir)
	if not remote_data.spotlight_dir then log('E', 'remote_data.spotlight_dir is of a invalid format') return end
	remote_data.pos = array2Vec(remote_data.pos)
	if not remote_data.pos then log('E', 'remote_data.pos is of a invalid format') return end
	remote_data.f_dir = array2Vec(remote_data.f_dir)
	if not remote_data.f_dir then log('E', 'remote_data.f_dir is of a invalid format') return end
	remote_data.vel = array2Vec(remote_data.vel)
	if not remote_data.vel then log('E', 'remote_data.vel is of a invalid format') return end
	
	return remote_data
end

-- for local to remote send
local function buildRemoteDataFromHeli(heli)
	if not heli:isEnabled() then
		return '{"state":false,"player_id":1}'
	end
	
	local data = heli:getData()
	return jsonEncode({
		player_id = 1, -- set by server, but required for sp dev
		state = true,
		spotlight = HELI_SPOTLIGHT,
		spotlight_type = HELI_SPOTLIGHT_TYPE,
		spotlight_dir = vec2Array(data.spotlight_dir),
		pos = vec2Array(heli:getPositionAsRef()),
		f_dir = vec2Array(heli:getDirectionVectorAsRef()),
		vel = vec2Array(heli:getVelocityAsRef()),
		thrust = heli:getThrust(),
	})
end

local function remoteAiController(self, dt, remote_data)
	local data = self:getData()
	if data.spotlight_type ~= remote_data.spotlight_type then
		data.spotlight_type = remote_data.spotlight_type
		data.spotlight_change = true
	end
	data.spotlight_type = remote_data.spotlight_type
	data.spotlight = remote_data.spotlight
	data.spotlight_dir = remote_data.spotlight_dir
end

local function remotePhysicsController(self, dt, remote_data)
	if simTimeAuthority.getPause() then return end
	
	local data_time = remote_data.timer:stop()
	if data_time > 1000 then
		local c_pos = self:getPositionAsRef()
		if dist3d(c_pos, core_camera:getPosition()) < 400 then
			debugDrawer:drawText(c_pos + vec3(0, 0, 12), 'LOST CONNECTION', ColorF(1, 0, 0, 1))
		end
		return
	end
	
	local c_pos = self:getPositionAsRef()
	local t_vel = remote_data.vel
	
	local o_pos = remote_data.pos -- actual last known pos
	local a_pos = o_pos + (t_vel * (data_time / 1000)) -- prediced actual position based on receive time
	local p_pos = c_pos + (t_vel * dt) -- predicted pos by remote velocity
	
	-- if to far then just tp and call it a day
	local dist = dist3d(o_pos, p_pos)
	if dist > 1000 then
		self:setPosition(o_pos)
		return
	end
	
	-- make pos adjustments based on the distance of our predicted and the known last pos
	local step_by = math.min(150, (dist / 100) * 150) * dt
	
	local t_dir = (a_pos - p_pos):normalized()
	self:setPosition(p_pos + (t_dir * step_by))
	
	--[[
		We could additionally factor the remote f_dir and thrust into p_pos since we know both but the extra cpu time for just that little extra precision is not worth it.
	]]
	
	-- required for the model rotation sync, ignored by the physics controller
	self:setVelocity(remote_data.vel)
	self:setDirectionVector(remote_data.f_dir)
	self:setThrust(remote_data.thrust)
	
	if DEBUG_RENDER then
		debugDrawer:drawSphere(a_pos, 1, ColorF(1, 0, 0, 0.5))
		debugDrawer:drawText(a_pos + vec3(0, 0, 2), 'x Predicted remote pos', ColorF(1, 0, 0, 1))
	end
end

-- ------------------------------------------------------------------
-- Base Heli Routines
local function switchSpotLightMode()
	HELI_SPOTLIGHT_MODE = HELI_SPOTLIGHT_MODE + 1
	if HELI_SPOTLIGHT_MODE > 2 then HELI_SPOTLIGHT_MODE = 1 end
end

local function switchSpotLightType()
	HELI_SPOTLIGHT_TYPE = HELI_SPOTLIGHT_TYPE + 1
	if HELI_SPOTLIGHT_TYPE > #HELI_SPOTLIGHT_TYPE_DEF then
		HELI_SPOTLIGHT_TYPE = 1
	end
	
	if HELI then
		local data = HELI:getData()
		data.spotlight_type = HELI_SPOTLIGHT_TYPE
		data.spotlight_change = true
	end
end

local function spotLightRoutine(self, is_enabled, dt)
	local data = self:getData()
	local obj = self:getObjByName('spotlight')
	obj.isEnabled = is_enabled and data.spotlight
	if not is_enabled then return end
	
	if data.spotlight_change then
		data.spotlight_change = false
		local s_def = HELI_SPOTLIGHT_TYPE_DEF[data.spotlight_type]
		if s_def then
			local shadows = HELI_SPOTLIGHT_DRAW_SHADOWS
			if s_def.shadows ~= nil then shadows = s_def.shadows end
			obj.innerAngle = s_def.inner
			obj.outerAngle = s_def.outer
			obj.brightness = s_def.brightness
			obj.range = s_def.range
			obj.color = s_def.color
			obj.castShadows = shadows
		end
	end
	
	-- smooth transition to target
	local t_dir = data.spotlight_dir -- what we want to point to
	local c_dir = data.spotlight_dir_last -- where we are currently pointing to
	
	local s_dir = (t_dir - c_dir) * 7 * dt -- step rotate by this amount
	t_dir = c_dir + s_dir -- apply to current rot
	data.spotlight_dir_last = t_dir
	
	local c_pos = self:getPositionAsRef()
	local rot = quatFromDir(t_dir, vec3(0, 0, 1))
	obj:setPosRot(c_pos.x, c_pos.y, c_pos.z, rot.x, rot.y, rot.z, rot.w)
end

local function soundRoutine(self, is_enabled, dt)
	local data = self:getData()
	local obj = self:getObjByName('sound')
	
	if not is_enabled then
		if obj.volume > 0 then
			obj.volume = 0
			obj:postApply()
		end
		if data.is_player and SPECTATE_SOUND.volume > 0 then
			SPECTATE_SOUND.volume = 0
			SPECTATE_SOUND:postApply()
		end
		return
	end
	
	obj:setPosition(self:getPositionAsRef())
	if data.is_player then
		if IS_CAM then
			if SPECTATE_SOUND.volume == 0 then
				SPECTATE_SOUND.volume = 1
				SPECTATE_SOUND:postApply()
			end
			if obj.volume > 0 then
				obj.volume = 0
				obj:postApply()
			end
		else
			if obj.volume == 0 then
				obj.volume = 1
				obj:postApply()
			end
			if SPECTATE_SOUND.volume > 0 then
				SPECTATE_SOUND.volume = 0
				SPECTATE_SOUND:postApply()
			end
		end
	else
		if obj.volume == 0 then
			obj.volume = 1
			obj:postApply()
		end
	end
end

local function nameTagRenderRoutine(self, is_enabled, dt)
	if not is_enabled then return end
	--[[
	local data = self:getData()
	local cam_pos = core_camera:getPosition()
	local pos = self:getPosition()
	pos.z = pos.z + 10
	
	local player_name = PLAYER_TAG_TEST or getPlayerNameFromId(data.player_id or getMyId()) or 'MH-6'
	local nametag = PLAYER_TAGS[player_name] or PLAYER_TAGS._default
	local has_los = hasLineOfSight(pos, cam_pos) -- some debug drawers draw through other objects
	debugDrawer:drawSphere(pos, 1, nametag.orb)
	if has_los then debugDrawer:drawCircle(pos, 2, 8, Point4F(0, 0, 0, 0.5)) end
	]]
	
	-- dont draw if player or if the mp setting hide nametags is on
	--if data.is_player or settings.getValue("hideNameTags") then return end
	if settings.getValue("hideNameTags") then return end

	local cam_pos = core_camera:getPosition()
	local pos = self:getPosition()
	local full_until = 150
	local fade_until = 300
	local dist = dist3d(pos, cam_pos)
	if dist > fade_until then return end

	local fade = 1
	if dist > full_until then
		fade = 1 - math.min(1, ((dist - full_until) / (fade_until / 2)) * 1)
	end
	
	local data = self:getData()
	local player_name = PLAYER_TAG_TEST or getPlayerNameFromId(data.player_id or getMyId()) or 'MH-6'
	local nametag = PLAYER_TAGS[player_name] or PLAYER_TAGS._default
	adaptColor(nametag.textcolor, data.textcolor)
	adaptColor(nametag.background, data.background)
	data.textcolor.a = data.textcolor.a * fade
	data.background.a = data.background.a * fade
	
	pos.z = pos.z + 5
	--[[
	debugDrawer:drawTextAdvanced(
		pos,
		' ' .. player_name .. (nametag.postfix or PLAYER_TAG_DEFAULT_POSTFIX),
		data.textcolor, -- text color
		true, -- draw background
		false, -- unknown
		data.background
	)
	]]
	
	drawTextAdvanced(
		pos,
		' ' .. player_name .. (nametag.postfix or PLAYER_TAG_DEFAULT_POSTFIX),
		data.textcolor,
		data.background
	)
end

local function heliModelRenderRoutine(self, is_enabled, dt)
	local obj = self:getObjByName('model')
	obj:setHidden(not is_enabled)
	if not is_enabled then return end
	
	local data = self:getData()
	local c_pos = self:getPositionAsRef()
	local c_vel = self:getVelocityAsRef()
	local a_dir = self:getDirectionVector()
	local thrust = self:getThrust()
	
	-- forward dir ---------------------------------------------
	local t_dir = -c_vel:normalized()
	local dir = 1 - (c_vel:normalized() - a_dir):length() -- tilt direction
	t_dir.z = math.min(0.6, (thrust / HELI_MAX_THRUST) * 0.6) * dir -- tilt by thrust. 60% weight
	t_dir.z = t_dir.z + math.min(0.4, (c_vel:length() / HELI_MAX_SPEED) * 0.4) -- tilt by speed. 40% weight
	
	local c_dir = data.model_dir_last -- where we are currently pointing to
	local s_dir = (t_dir - c_dir) * 1 * dt -- step rotate by this amount
	
	t_dir = c_dir + s_dir -- apply to current dir
	data.model_dir_last = t_dir
	
	-- up dir --------------------------------------------------
	a_dir.z = 1
	local c_dir = data.model_udir_last
	local s_dir = (a_dir - c_dir) * 1 * dt
	
	local u_dir = c_dir + s_dir
	data.model_udir_last = u_dir
	
	local rot = quatFromDir(t_dir, u_dir)
	local pos = c_pos + (t_dir * 2.5) -- moving the pos a little back so that spotlight and cam are closer to the front of the heli instead of on its belly
	obj:setPosRot(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
end

-- ------------------------------------------------------------------
-- Heli constructor
local function addDefaultObjects(heli, postfix)
	local obj = createObject("SpotLight")
	obj.useInstanceRenderData = 1
	obj.color = Point4F(1, 0.95, 0.5, 1)
	obj.isEnabled = false
	obj:setField("flareType", 0, "vehicleHeadLightFlare") -- doesnt work quite as well
	obj.range = 500
	obj.innerAngle = 4
	obj.outerAngle = 7
	obj.brightness = 1.5
	obj.castShadows = false
	obj:registerObject('helicam_spotlight_' .. postfix)
	heli:addObj('spotlight', obj)
	
	local obj = createObject("SFXEmitter")
	obj.fileName = 'art/sounds/HeliCam/heli_constant.ogg'
	obj.isLooping = true
	obj.playOnAdd = true
	obj.isStreaming = false
	obj.volume = 0
	obj.is3D = true
	obj:setField("sourceGroup", 0, "AudioChannelMaster")
	obj.referenceDistance = 50
	obj.maxDistance = 500
	obj:registerObject('helicam_sound_' .. postfix)
	heli:addObj('sound', obj)
	
	local obj = createObject("TSStatic")
	obj.shapeName = '/art/shapes/HeliCam/helicopter_cam.dae'
	obj.dynamic = true
	--obj.useInstanceRenderData = 1
	--obj.instanceColor = color_point
	obj:setPosRot(0, 0, 0, 0, 0, 0, 0)
	obj.scale = vec3(1, 1, 1)
	obj:registerObject('helicam_model_' .. postfix)
	obj:setHidden(true)
	heli:addObj('model', obj)
end

local function createPlayerHeli()
	local heli = PhysicsActor()
		:setMass(HELI_MASS)
		:setAiController(aiController)
		:setPhysicsController(physicsController)
		:addRoutine(spotLightRoutine)
		:addRoutine(soundRoutine)
		:addRoutine(nameTagRenderRoutine)
		:addRoutine(heliModelRenderRoutine)
		:setState(IS_SPAWNED)
	
	local data = heli:getData()
	data.index = 1
	data.is_player = true
	data.textcolor = ColorF(0, 0, 0, 0)
	data.background = ColorI(0, 0, 0, 0)
	data.los_timer = hptimer()
	--data.trajectory = {}
	--data.trajectory_timer = hptimer()
	data.spotlight_type = 1
	data.spotlight_change = true
	data.spotlight_dir = vec3(0, 0, 0)
	data.spotlight_dir_last = vec3(0, 0, 0)
	data.model_dir_last = vec3(-1, 0, 0)
	data.model_udir_last = vec3(0, 0, 1)
	
	addDefaultObjects(heli, 'player')
	return heli
end

local function createRemotePlayerHeli(player_id)
	local heli = PhysicsActor()
		:setAiController(remoteAiController)
		:setPhysicsController(remotePhysicsController)
		:addRoutine(spotLightRoutine)
		:addRoutine(soundRoutine)
		:addRoutine(nameTagRenderRoutine)
		:addRoutine(heliModelRenderRoutine)
		:setState(true)
	
	local data = heli:getData()
	data.is_player = false
	data.player_id = player_id
	data.textcolor = ColorF(0, 0, 0, 0)
	data.background = ColorI(0, 0, 0, 0)
	data.spotlight_type = 1
	data.spotlight_change = true
	data.spotlight_dir = vec3(0, 0, 0)
	data.spotlight_dir_last = vec3(0, 0, 0)
	data.model_dir_last = vec3(-1, 0, 0)
	data.model_udir_last = vec3(0, 0, 1)
	
	addDefaultObjects(heli, player_id)
	return heli
end

-- ------------------------------------------------------------------
-- Load / unload
local function init()
	if HELI then return end
	if core_levels.getLevelName(getMissionFilename()) == nil then return end -- not inside a level
	IS_BEAMMP_SESSION = isBeamMPSession()
	loadJsonMaterialsFile('/art/shapes/HeliCam/main.materials.json')
	HELI = createPlayerHeli()
	
	local obj = createObject("SFXEmitter")
	obj.fileName = 'art/sounds/HeliCam/heli_constant.ogg'
	obj.isLooping = true
	obj.playOnAdd = true -- todo
	obj.isStreaming = false
	obj.volume = 0
	obj.is3D = false
	obj:setField("sourceGroup", 0, "AudioChannelMaster")
	obj.referenceDistance = 50
	obj.maxDistance = 500
	obj:registerObject('helicam_player_view_sound')
	SPECTATE_SOUND = obj
	
	if IS_BEAMMP_SESSION then
		AddEventHandler('heliCamUpdate', M.receiveRemoteHeliData)
	end
end

local function unload()
	if HELI then
		HELI:delete()
		HELI = nil
		
		SPECTATE_SOUND:delete()
		SPECTATE_SOUND = nil
	end
	
	for _, data in pairs(REMOTE_HELIS) do
		data.heli:delete()
	end
	REMOTE_HELIS = {}
	
	SPECTATOR_WHITELIST_VEHICLES = {}
	SPECTATOR_WHITELIST_PLAYERS = {}
	
	IS_SPAWNED = false
	IS_CAM = false
	HELI_CONTROL = false
	UI_RENDER = true
	HELI_SPOTLIGHT = false
end

-- ------------------------------------------------------------------
-- Heli control
local function switchHeliControl(state)
	for _, vehicle in ipairs(getAllVehicles()) do
		if isOwn(vehicle:getId()) then
			vehicle:queueLuaCommand(INPUT_LOCK_PAYLOAD .. 'setInputLock(' .. tostring(not state) .. ')')
		end
	end
end

local function heliControl(dt)
	if not HELI_CONTROL then return end
	
	local radius = (HELI_CONTROL_INPUTS.radius_up - HELI_CONTROL_INPUTS.radius_down) + HELI_CONTROL_INPUTS.radius
	local altitude = (HELI_CONTROL_INPUTS.altitude_up - HELI_CONTROL_INPUTS.altitude_down) + HELI_CONTROL_INPUTS.altitude
	
	if not inRange(-0.2, radius, 0.2) then
		local factor = -radius * 30 * dt
		increaseRadius(factor)
	end
	
	if not inRange(-0.2, altitude, 0.2) then
		local factor = altitude * 30 * dt
		increaseAlt(factor)
	end
end

-- ------------------------------------------------------------------
-- Game events
M.onVehicleSwitched = function(prev_vehicle, vehicle)
	if not IS_CAM then return end
	evalSpectatorShip()
end

M.onUpdate = function(dt_real, dt_sim, dt_real)
	if not HELI then return end
	HELI:setState(IS_SPAWNED)

	local tar_veh = getPlayerVehicle(0)
	if tar_veh then
		HELI:tick(dt_sim, tar_veh)
		if IS_SPAWNED then
			local t_pos = tar_veh:getPosition()
			if MODE_AUTO_TP and HELI_MODE ~= 8 and dist2d(tar_veh:getPosition(), HELI:getPosition()) > MODE_TP_DIST then
				HELI:setPosition(evalTargetHeightPos(t_pos))
				HELI:setVelocity(vec3(0, 0, 0))
			end
			if IS_CAM then
				updateCam(tar_veh, dt_sim)
				heliControl(dt_sim)
			end
		end
		
		if IS_BEAMMP_SESSION and REMOTE_SEND_TIMER:stop() > MP_UPDATE_RATE then
		--if REMOTE_SEND_TIMER:stop() > MP_UPDATE_RATE then
			REMOTE_SEND_TIMER:stopAndReset()
			TriggerServerEvent('heliCamUpdate', buildRemoteDataFromHeli(HELI))
			--M.receiveRemoteHeliData(buildRemoteDataFromHeli(HELI))
		end
	end
	
	-- update helis from other players
	for player_id, data in pairs(REMOTE_HELIS) do
		if data.remote_data then
			if data.remote_data.timer:stop() < 5000 then
				data.heli:setState(data.remote_data.state)
				data.heli:tick(dt_sim, data.remote_data)
				
			else -- lost signal
				data.heli:setState(false)
				data.heli:tick(dt_sim, data.remote_data)
				data.heli:delete()
				REMOTE_HELIS[player_id] = nil
			end
		end
	end
end

M.onGuiUpdate = function(dt)
	local tar_veh = getPlayerVehicle(0)
	if not tar_veh or not HELI or not IS_SPAWNED or not IS_CAM or not UI_RENDER then return end
	
	local t_pos = tar_veh:getPosition()
	local h_pos = HELI:getPosition()
	local h_vel = math.floor(HELI:getVelocity():length() * 3.6)
	local altitude_from_target = math.floor(h_pos.z - t_pos.z)
	local dist = math.floor(dist2d(t_pos, h_pos))
	local has_los = hasLineOfSight(t_pos, h_pos)
	local spectating = getPlayerNameFromVehicle(tar_veh:getId()) or 'YOU'
	local spotlight = boolToOnOff(HELI_SPOTLIGHT)
	local spotlight_mode = 'Locked'
	if HELI_SPOTLIGHT_MODE == 2 then spotlight_mode = 'Free' end
	local spotlight_def = HELI_SPOTLIGHT_TYPE_DEF[HELI_SPOTLIGHT_TYPE]
	local spotlight_type = string.format(
		'%s° %sm %s',
		spotlight_def.outer, spotlight_def.range, spotlight_def.name
	)
	
	if HELI_CONTROL then
		guihooks.message({txt = string.format(
			[[
				HELI CAM V%s - %s
				HELI CONTROL MODE! VEHICLE CONTROLS LOCKED
				---------------------._ Settings _.----------------------
				Altitude........: %sm (Target: %sm)
				Speed...........: %skph (Max: %skph)
				2D Distance.: %sm (Target: %sm)
				Thrust...........: %s (Max: %s)
				------------------------._ State _.------------------------
				Mode............: %s (LOS: %s)
				Auto TP.........: %s (Dist > %sm)
				Auto Rotate.: %s (Smoother: %s)
				Auto Fov.......: %s (FOV: %s)
				Spotlight......: %s (Mode: %s)
				Spot. Type....: %s
			]],
				VERSION, spectating,
				altitude_from_target, math.floor(HELI_TARGET_ALT),
				h_vel, math.floor(HELI_MAX_SPEED * 3.6),
				dist, math.floor(HELI_CIRCLE_RADIUS),
				math.floor(HELI:getThrust()), math.floor(HELI_MAX_THRUST),
				MODE_CLEAR_NAME[HELI_MODE], has_los,
				boolToOnOff(MODE_AUTO_TP), MODE_TP_DIST,
				boolToOnOff(MODE_AUTO_ROT), math.floor(MODE_ROT_SMOOTHER),
				boolToOnOff(MODE_AUTO_FOV), math.floor(core_camera:getFovDeg()),
				spotlight, spotlight_mode,
				spotlight_type
			)},
			1,
			"helicam"
		)
	else
		guihooks.message({txt = string.format(
			[[
				HELI CAM V%s - %s
				VEHICLE CONTROL MODE! Limited heli control
				------------------------._ State _.------------------------
				Mode............: %s
				Altitude........: %sm
				Speed...........: %skph
				Distance.......: %sm
			]],
				VERSION, spectating,
				MODE_CLEAR_NAME[HELI_MODE],
				altitude_from_target,
				h_vel,
				dist
			)},
			1,
			"helicam"
		)
	end
end

M.onExtensionLoaded = init
M.onWorldReadyState = function(state) if state == 2 then init() end end

M.onExtensionUnloaded = unload
M.onClientEndMission = unload

-- ------------------------------------------------------------------
-- Custom MP events
M.receiveRemoteHeliData = function(remote_data)
	local remote_data = decodeAndVerifyRemoteData(remote_data)
	if not remote_data then return end
	
	remote_data.timer = hptimer()
	local data = REMOTE_HELIS[remote_data.player_id] or {heli = createRemotePlayerHeli(remote_data.player_id)}
	data.remote_data = remote_data
	
	REMOTE_HELIS[remote_data.player_id] = data
end

-- ------------------------------------------------------------------
-- Custom events / Hotkeys
M.toggleAnim = function() -- testing
	local obj = HELI:getObjByName('model')
	obj.playAmbient = not obj.playAmbient
	obj:postApply()
end

M.heliControlInput = function(type, value)
	HELI_CONTROL_INPUTS[type] = value
end

M.toggleHeliControl = function(state)
	if not HELI_CONTROL and not IS_CAM then return end
	HELI_CONTROL = boolOr(state, not HELI_CONTROL)
	switchHeliControl(HELI_CONTROL)
end

M.toggleCam = function(state)
	IS_CAM = boolOr(state, not IS_CAM)
	M.toggleHeliControl(IS_CAM)
	spawnHeli()
	
	if not IS_CAM then
		core_camera.setVehicleCameraByIndexOffset(1) -- it be better if we switched to the last camera
		if HELI_AUTO_DESPAWN then
			M.despawnHeli()
		end
	end
end

M.spawnHeli = function()
	spawnHeli()
end

M.despawnHeli = function()
	IS_CAM = false
	IS_SPAWNED = false
	switchHeliControl(false)
end

M.nextMode = function()
	if not IS_CAM then return end
	switchToMode(HELI_MODE + 1)
end

M.setMode = function(mode)
	if not IS_CAM then return end
	switchToMode(math.max(1, tonumber(mode) or 1))
end

M.toggleAutoRot = function(state)
	if not IS_CAM or not HELI_CONTROL then return end
	MODE_AUTO_ROT = boolOr(state, not MODE_AUTO_ROT)
end

M.toggleAutoFov = function(state)
	if not IS_CAM or not HELI_CONTROL then return end
	MODE_AUTO_FOV = boolOr(state, not MODE_AUTO_FOV)
end

M.toggleAutoTp = function(state)
	MODE_AUTO_TP = boolOr(state, not MODE_AUTO_TP)
end

M.toggleDebugDraw = function(state)
	if not IS_CAM or not HELI_CONTROL then return end
	DEBUG_RENDER = boolOr(state, not DEBUG_RENDER)
end

M.toggleUiRender = function(state)
	if not IS_CAM then return end
	UI_RENDER = boolOr(state, not UI_RENDER)
end

M.toggleSpotLight = function(state)
	if not IS_CAM or not HELI_CONTROL then return end
	HELI_SPOTLIGHT = boolOr(state, not HELI_SPOTLIGHT)
end

M.switchSpotLightMode = function()
	if not IS_CAM or not HELI_CONTROL then return end
	switchSpotLightMode()
end

M.switchSpotLightType = function()
	if not IS_CAM or not HELI_CONTROL then return end
	switchSpotLightType()
end

M.increaseAlt = function(amount)
	if not IS_CAM or not HELI_CONTROL then return end
	increaseAlt(tonumber(amount) or 0)
end

M.increaseRadius = function(amount)
	if not IS_CAM or not HELI_CONTROL then return end
	increaseRadius(tonumber(amount) or 0)
end

M.increaseThrust = function(amount)
	if not IS_CAM or not HELI_CONTROL then return end
	increaseThrust(tonumber(amount) or 0)
end

M.increaseRotSmoother = function(amount)
	if not IS_CAM or not HELI_CONTROL then return end
	increaseRotSmoother(tonumber(amount) or 0)
end

-- ------------------------------------------------------------------
-- API
M.setPlayertag = function(player_name, textcolor, background, postfix, orb)
	PLAYER_TAGS[player_name] = {
		textcolor = textcolor or rgbToColorF(255, 255, 255), -- must be ColorF where rgba go from 0 to 1
		background = background or ColorI(255, 255, 255, 127), -- must be ColorI
		postfix = postfix or ' [Heli]',
		orb = orb or rgbToColorF(122, 122, 122, 64) -- must be ColorF
	}
end

M.removePlayertag = function(player_name)
	PLAYER_TAGS[player_name] = nil
end

M.setAllInOne = function(veh_id, mode, height, radius, teleport)
	local vehicle = getObjectByID(veh_id)
	if not vehicle then return end
	
	be:enterVehicle(0, vehicle)
	spawnHeli()
	M.toggleCam(true)
	
	if mode then M.setMode(mode) end
	if height then M.setAltitude(height) end
	if radius then M.setRadius(radius) end
	if teleport then M.teleport() end
end

M.setMode = function(mode) -- int. See MODE_CLEAR_NAME table
	switchToMode(mode or 1)
end

M.setTarget = function(veh_id)
	local vehicle = getObjectByID(veh_id)
	if not vehicle then return end
	be:enterVehicle(0, vehicle)
end

M.teleport = function(pos)
	HELI:setPosition(
		evalTargetHeightPos(
			pos or getPlayerVehicle(0):getPosition()
		)
	)
	M.setVelocity()
end

M.setVelocity = function(vel)
	HELI:setVelocity(vel or vec3(0, 0, 0))
end

M.setAltitude = function(height)
	HELI_TARGET_ALT = height
end

M.setRadius = function(radius)
	HELI_CIRCLE_RADIUS = radius
end

M.setThrust = function(thrust)
	HELI_MAX_THRUST = thrust
end

M.setRotSmoother = function(smoother)
	MODE_ROT_SMOOTHER = smoother
end

-- whitelist
M.setAllowedVehicles = function(table) -- [1..n] = vehicle_id (give empty table to disable)
	SPECTATOR_WHITELIST_VEHICLES = tableVToK(table)
	evalSpectatorShip()
end

M.setAllowedPlayers = function(table) -- [1..n] = player_name (give empty table to disable)
	SPECTATOR_WHITELIST_PLAYERS = tableVToK(table)
	evalSpectatorShip()
end

-- raw access to the Heli physics obj.
-- Please see HeliCam/libs/PhysicsActor.lua for the interface
M.HELI = HELI

return M
