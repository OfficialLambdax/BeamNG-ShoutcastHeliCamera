local C = {}
C.__index = C

local function inRange(x, t, y)
	return t > x and t < y
end

function C:init(fov_default, fov_min, fov_max)
	self.isFilter = true
	self.hidden = true
	self.fov_default = fov_default or 80
	self.fov_min = fov_min or 10
	self.fov_max = fov_max or 120
	self.accel = 0
	self:reset()
end

function C:reset()
	self.fov = self.fov_default
	self.accel = 0
end

function C:setFOV(fov)
	self.fov = fov
	self.accel = 0
end

function C:update(data)
	if data.openxrSessionRunning then return false end
	local input = MoveManager.zoomIn - MoveManager.zoomOut -- -0.1 to 0.1. unsure if this is true with all input controllers, but it is for keyboard
	local accel = self.accel
	
	-- if input matches accel dir then accel, otherwise brake
	if (input > 0 and accel >= 0) or (input < 0 and accel <= 0) then
		accel = accel + (input * 1 * data.dt)
		
	elseif accel < 0 or accel > 0 then
		local dir = -1
		if accel < 0 then dir = 1 end
		
		local step = 0.3 * data.dt * dir
		accel = accel + step
		if inRange(-step, accel, step) then accel = 0 end
	end
	
	self.accel = clamp(accel, -1, 1)
	self.fov = clamp(self.fov + self.accel, self.fov_min, self.fov_max)
	data.res.fov = self.fov
end


-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW
return function(...)
	local o = ... or {}
	setmetatable(o, C)
	o:init()
	return o
end
