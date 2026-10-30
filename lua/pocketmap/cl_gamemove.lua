-- Dispatch the active gamemode and addon movement callbacks, using the actual
-- player and command with virtual movement data. No gamemode formulas are copied.
PocketMap.GamemodeMovement = {}
local Bridge = PocketMap.GamemodeMovement

function Bridge.Step(ply, mv, cmd, session)
	local playerMeta, entityMeta = FindMetaTable("Player"), FindMetaTable("Entity")
	local saved = {}
	local realFlags = ply:GetFlags()
	local flagsMask = bit.bor(FL_ONGROUND, FL_DUCKING)
	local viewAngles = cmd:GetViewAngles()
	local function flags()
		local value = bit.band(realFlags, bit.bnot(flagsMask))
		if session.onground then value = bit.bor(value, FL_ONGROUND) end
		if session.ducking then value = bit.bor(value, FL_DUCKING) end
		return value
	end
	local virtual = {
		OnGround = function() return session.onground == true end,
		IsOnGround = function() return session.onground == true end,
		Crouching = function() return session.ducking == true end,
		GetFlags = flags,
		IsFlagSet = function(_, flag) return bit.band(flags(), flag) ~= 0 end,
		GetPos = function() return mv:GetOrigin() end,
		GetNetworkOrigin = function() return mv:GetOrigin() end,
		GetVelocity = function() return mv:GetVelocity() end,
		GetMoveType = function() return session.noclip and MOVETYPE_NOCLIP or MOVETYPE_WALK end,
		GetGroundEntity = function() return session.onground and (session.groundEnt or game.GetWorld()) or NULL end,
		WaterLevel = function() return session.waterLevel or 0 end,
		WaterType = function() return session.waterType or 0 end,
		EyeAngles = function() return mv:GetAngles() end,
		GetAimVector = function() return mv:GetAngles():Forward() end,
		EyePos = function() return mv:GetOrigin() + Vector(0, 0, session.ducking and 28 or 64) end,
		KeyDown = function(_, key) return mv:KeyDown(key) end,
		KeyPressed = function(_, key) return mv:KeyPressed(key) end,
		KeyReleased = function(_, key) return mv:KeyReleased(key) end,
	}
	local ok, err = xpcall(function()
		-- Auto-refresh can load this bridge while the old movement module is
		-- still resident. Refresh the dependency before using the new API.
		if not PocketMap.Movement or type(PocketMap.Movement.Prepare) ~= "function" then
			include("pocketmap/movement.lua")
		end
		assert(PocketMap.Movement and type(PocketMap.Movement.Prepare) == "function", "PocketMap movement module is out of date; restart the game/server to load matching Lua files")
		PocketMap.Movement.Prepare(ply, mv, session)
		-- Scope player reads to the synchronous callback chain. Other players
		-- keep their normal methods; every override is restored even on errors.
		for name, callback in pairs(virtual) do
			local original = playerMeta[name] or entityMeta[name]
			if original then
				saved[#saved + 1] = { name = name, value = rawget(playerMeta, name) }
				local method = callback
				playerMeta[name] = function(target, ...)
					if target == ply then return method(target, ...) end
					return original(target, ...)
				end
			end
		end
		cmd:SetViewAngles(mv:GetAngles())
		hook.Run("SetupMove", ply, mv, cmd)
		if not hook.Run("Move", ply, mv) then
			session.moveSpeed = mv.speedModified and mv:GetMaxSpeed() or nil
			PocketMap.Movement.Step(ply, mv, session)
		end
		hook.Run("FinishMove", ply, mv)
	end, debug.traceback)
	for i = #saved, 1, -1 do
		local entry = saved[i]
		playerMeta[entry.name] = entry.value
	end
	cmd:SetViewAngles(viewAngles)
	return ok, err
end
