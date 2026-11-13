-- Dispatch the active gamemode and addon movement callbacks, using the actual
-- player and command with virtual movement data. No gamemode formulas are copied.
PocketMap.GamemodeMovement = PocketMap.GamemodeMovement or {}
local Bridge = PocketMap.GamemodeMovement

-- Player method wrappers are installed once and stay installed. They only
-- divert calls for the walking player while Bridge.active is set, so no
-- protected call is needed to restore them after an error.
Bridge.originals = Bridge.originals or {}

local function installWrapper(playerMeta, entityMeta, name)
	if Bridge.originals[name] then return end
	local original = playerMeta[name] or entityMeta[name]
	if not original then return end
	Bridge.originals[name] = { value = rawget(playerMeta, name) }
	playerMeta[name] = function(target, ...)
		local active = PocketMap.GamemodeMovement.active
		local method = active and target == active.ply and active.virtual[name]
		if method then return method(target, ...) end
		return original(target, ...)
	end
end

local VIRTUAL_NAMES = {
	"OnGround", "IsOnGround", "Crouching", "GetFlags", "IsFlagSet", "GetPos",
	"GetNetworkOrigin", "GetVelocity", "GetMoveType", "GetGroundEntity",
	"WaterLevel", "WaterType", "EyeAngles", "GetAimVector", "EyePos", "GetCurrentViewOffset",
	"KeyDown", "KeyPressed", "KeyReleased",
}

function Bridge.Reset()
	Bridge.active = nil
end

function Bridge.Step(ply, mv, cmd, session)
	local playerMeta, entityMeta = FindMetaTable("Player"), FindMetaTable("Entity")
	for _, name in ipairs(VIRTUAL_NAMES) do installWrapper(playerMeta, entityMeta, name) end

	local realFlags = ply:GetFlags()
	local flagsMask = bit.bor(FL_ONGROUND, FL_DUCKING)
	local viewAngles = cmd:GetViewAngles()
	local function flags()
		local value = bit.band(realFlags, bit.bnot(flagsMask))
		if session.onground then value = bit.bor(value, FL_ONGROUND) end
		if session.crouchFlag then value = bit.bor( value, FL_DUCKING ) end
		return value
	end
	local virtual = {
		OnGround = function() return session.onground == true end,
		IsOnGround = function() return session.onground == true end,
		Crouching = function() return session.crouchFlag == true end,
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
		EyePos = function() return mv:GetOrigin() + PocketMap.Walk.EyeOffset( session ) end,
		GetCurrentViewOffset = function() return PocketMap.Walk.EyeOffset( session ) end,
		KeyDown = function(_, key) return mv:KeyDown(key) end,
		KeyPressed = function(_, key) return mv:KeyPressed(key) end,
		KeyReleased = function(_, key) return mv:KeyReleased(key) end,
	}

	-- Auto-refresh can load this bridge while the old movement module is
	-- still resident. Refresh the dependency before using the new API.
	if not PocketMap.Movement or type(PocketMap.Movement.Prepare) ~= "function" then
		include("pocketmap/movement.lua")
	end
	PocketMap.Movement.Prepare(ply, mv, session)

	Bridge.active = { ply = ply, virtual = virtual }
	cmd:SetViewAngles(mv:GetAngles())

	local predicted = not game.SinglePlayer()
	if predicted then hook.Run("SetupMove", ply, mv, cmd) end
	if not hook.Run("Move", ply, mv) then
		session.moveSpeed = mv.speedModified and mv:GetMaxSpeed() or nil
		PocketMap.Movement.Step(ply, mv, session)
	end
	if predicted then hook.Run("FinishMove", ply, mv) end
	Bridge.active = nil
	cmd:SetViewAngles(viewAngles)
end
