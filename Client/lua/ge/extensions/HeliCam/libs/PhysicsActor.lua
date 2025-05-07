
return function()
	local actor = {int = {
		pos = vec3(0, 0, 0),
		f_dir = vec3(0, 0, 0),
		u_dir = vec3(0, 0, 1),
		vel = vec3(0, 0, 0),
		mass = 0,
		thrust = 0,
		is_enabled = false,
		ai_controller = nop,
		physics_controller = nop,
		routines = {},
		objs = {},
		data = {},
	}}
	
	function actor:getPosition() return vec3(self.int.pos) end
	function actor:getDirectionVector() return vec3(self.int.f_dir) end
	function actor:getDirectionVectorUp() return vec3(self.int.u_dir) end
	function actor:getVelocity() return vec3(self.int.vel) end
	
	function actor:getPositionAsRef() return self.int.pos end
	function actor:getDirectionVectorAsRef() return self.int.f_dir end
	function actor:getDirectionVectorUpAsRef() return self.int.u_dir end
	function actor:getVelocityAsRef() return self.int.vel end
	
	function actor:getMass() return self.int.mass end
	function actor:getThrust() return self.int.thrust end
	function actor:getData() return self.int.data end
	function actor:getInternal() return self.int end
	function actor:getObjs() return self.int.objs end
	function actor:getObjByName(name) return self.int.objs[name] end
	function actor:isEnabled() return self.int.is_enabled end
	
	function actor:setVelocity(vel) self.int.vel:set(vel) return self end
	function actor:setPosition(pos) self.int.pos:set(pos) return self end
	function actor:setDirectionVector(dir) self.int.f_dir:set(dir) return self end
	function actor:setDirectionVectorUp(dir) self.int.u_dir:set(dir) return self end
	function actor:setMass(mass) self.int.mass = mass return self end
	function actor:setThrust(thrust) self.int.thrust = thrust return self end
	function actor:setState(state) self.int.is_enabled = state return self end
	
	function actor:setAiController(func) self.int.ai_controller = func return self end
	function actor:setPhysicsController(func) self.int.physics_controller = func return self end
	
	function actor:addRoutine(func) table.insert(self.int.routines, func) return self end
	function actor:addObj(name, obj) self.int.objs[name] = obj return self end
	
	function actor:delete()
		for name, obj in pairs(self.int.objs) do
			if obj.delete then obj:delete() end
			self.int.objs[name] = nil
		end
	end
	
	function actor:tick(dt, ...)
		local int = self.int
		if int.is_enabled then
			int.ai_controller(self, dt, ...)
			int.physics_controller(self, dt, ...)
		end
		
		for _, routine in ipairs(int.routines) do
			routine(self, int.is_enabled, dt)
		end
		
		return self
	end
	
	return actor
end
