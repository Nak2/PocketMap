-- A local camera and movement session, simulated in the original BSP coordinates.
-- Replace any always-installed hooks left by the previous walk implementation.
hook.Remove("CreateMove", "PocketMap_Walk")
hook.Remove("PlayerBindPress", "PocketMap_Noclip")
PocketMap.Walk = {}
local Walk = PocketMap.Walk
local Session = {}
Session.__index = Session

-- Query the BSP's spatial partition instead of scanning every leaf on every
-- ground, stair, ladder and slide probe. Child indices < 0 encode leaf indices.
function Session:QueryLeafs(lo, hi)
	local result, stack = {}, { 0 }
	while #stack > 0 do
		local index = stack[#stack]
		stack[#stack] = nil
		if index < 0 then
			local leaf = self.leafs[-1 - index]
			if leaf then result[#result + 1] = leaf end
		else
			local node = self.nodes[index]
			if node then
				local n, dist = node.plane.normal, node.plane.dist
				local low = n.x * (n.x < 0 and hi.x or lo.x) + n.y * (n.y < 0 and hi.y or lo.y) + n.z * (n.z < 0 and hi.z or lo.z) - dist
				local high = n.x * (n.x < 0 and lo.x or hi.x) + n.y * (n.y < 0 and lo.y or hi.y) + n.z * (n.z < 0 and lo.z or hi.z) - dist
				if high >= -0.03125 then stack[#stack + 1] = node.children[1] end
				if low <= 0.03125 then stack[#stack + 1] = node.children[2] end
			end
		end
	end
	return result
end

-- Expand each convex brush by the player hull, then clip the swept origin
-- against its planes. The BSP partitions select brushes; render-leaf bounds
-- must not reject player clips or brush sections extending beyond those bounds.
function Session:TraceHull(start, finish, mins, maxs, mask, out)
	out = out or {}
	out.Fraction, out.Hit, out.StartSolid, out.AllSolid = 1, false, false, false
	out.HitWorld, out.Entity = false, game.GetWorld()
	out.HitNormal = Vector(0, 0, 0)
	out.Contents, out.SurfaceProps = 0, 0
	out.Displacement = false
	out.Texinfo, out.SurfaceName = nil, nil -- the surface that was hit, for the sound of a step: a texinfo, or the name of a surface property
	local lo = {x = math.min(start.x, finish.x) + mins.x, y = math.min(start.y, finish.y) + mins.y, z = math.min(start.z, finish.z) + mins.z}
	local hi = {x = math.max(start.x, finish.x) + maxs.x, y = math.max(start.y, finish.y) + maxs.y, z = math.max(start.z, finish.z) + maxs.z}
	local seen = {}
	for _, leaf in ipairs(self:QueryLeafs(lo, hi)) do
		for _, brush in ipairs(leaf:GetBrushes()) do
			if not seen[brush] and bit.band(brush.contents, mask or MASK_PLAYERSOLID) ~= 0 then
				seen[brush] = true
				local enter, leave, normal, hitTexinfo = -1, 1, nil, nil
				local outside, endOutside, rejected = false, false, false
				for _, side in ipairs(brush.sides) do
					local n, dist = side.plane.normal, side.plane.dist
					local offset = n.x * (n.x < 0 and maxs.x or mins.x) + n.y * (n.y < 0 and maxs.y or mins.y) + n.z * (n.z < 0 and maxs.z or mins.z)
					local d1 = n.x * start.x + n.y * start.y + n.z * start.z + offset - dist
					local d2 = n.x * finish.x + n.y * finish.y + n.z * finish.z + offset - dist
					if d1 > 0 then outside = true end
					if d2 > 0 then endOutside = true end
					-- A clipped surf velocity is tangent to the plane. Double
					-- precision dot products can make that look infinitesimally
					-- inward, causing four zero-distance hits and a speed reset.
					if d1 > 0 and d2 >= d1 - 0.0000001 then rejected = true break end
					if d1 > 0 or d2 > 0 then
						if d1 > d2 then
							local f = (d1 - 0.03125) / (d1 - d2)
							if f > enter then enter, normal, hitTexinfo = f, n, side.texinfo end
						else
							leave = math.min(leave, (d1 + 0.03125) / (d1 - d2))
						end
					end
				end
				if not rejected then
					if not outside then
						out.StartSolid = true
						if not endOutside then out.AllSolid, out.Fraction = true, 0 end
					elseif enter < leave and enter > -1 and enter < out.Fraction then
						out.Fraction = math.max(0, enter)
						local length = math.sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z)
						out.HitNormal = {x = normal.x / length, y = normal.y / length, z = normal.z / length}
						out.Contents, out.Texinfo = brush.contents, hitTexinfo
					end
				end
			end
		end
	end
	-- The static props (and the terrain, if pocketmap_physics_terrain says so) from the collision the map was compiled with (cl_physics.lua).
	-- Unless that has the terrain, it is made of the triangles of the displacements (cl_displacements.lua).
	local physics = self.physics
	if physics then PocketMap.Physics.Trace(physics, start, finish, mins, maxs, mask, lo, hi, out) end
	if self.displacements and not (physics and physics.terrain > 0) then
		PocketMap.Displacements.Trace(self.displacements, start, finish, mins, maxs, mask, lo, hi, out)
	end
	out.Hit = out.Fraction < 1 or out.StartSolid
	out.HitWorld = out.Hit
	out.HitPos = {x = start.x + (finish.x - start.x) * out.Fraction, y = start.y + (finish.y - start.y) * out.Fraction, z = start.z + (finish.z - start.z) * out.Fraction}
	return out
end

local fields = { Origin = "origin", Velocity = "velocity", Angles = "angles", MoveAngles = "moveAngles", AbsMoveAngles = "moveAngles", Buttons = "buttons", OldButtons = "oldButtons", ForwardSpeed = "forward", SideSpeed = "side", UpSpeed = "up", MaxSpeed = "maxSpeed", MaxClientSpeed = "maxClientSpeed", ImpulseCommand = "impulse", ConstraintCenter = "constraintCenter", ConstraintRadius = "constraintRadius", ConstraintWidth = "constraintWidth", ConstraintSpeedFactor = "constraintSpeedFactor", FinalStepHeight = "finalStepHeight", FinalIdealVelocity = "finalIdealVelocity", FinalJumpVelocity = "finalJumpVelocity" }
local Move = {}
local function copyValue(value)
	if isvector(value) then return Vector(value.x, value.y, value.z) end
	if isangle(value) then return Angle(value.p, value.y, value.r) end
	return value
end
for name, field in pairs(fields) do
	local key = field
	Move["Get" .. name] = function(self) return copyValue(self[key]) end
	Move["Set" .. name] = function(self, value) self[key] = copyValue(value) end
end

function Move:KeyDown(key) return bit.band(self.buttons, key) ~= 0 end
function Move:KeyPressed(key) return self:KeyDown(key) and bit.band(self.oldButtons, key) == 0 end
function Move:KeyReleased(key) return not self:KeyDown(key) and bit.band(self.oldButtons, key) ~= 0 end
function Move:AddKey(key) self.buttons = bit.bor(self.buttons, key) end
function Move:RemoveKeys(key) self.buttons = bit.band(self.buttons, bit.bnot(key)) end
function Move:SetMaxSpeed(speed) self.maxSpeed, self.speedModified = speed, true end
function Move:SetMaxClientSpeed(speed) self.maxClientSpeed, self.maxSpeed, self.speedModified = speed, speed, true end
function Move:GetConstraintPastRadius() return self.origin:DistToSqr(self.constraintCenter) > self.constraintRadius * self.constraintRadius end

local REACH_SQR = 300 * 300
local MOVE_HOOK, HUD_HOOK = "PocketMap_Walk", "PocketMap_WalkHUD"

-- These two only exist while somebody walks in a map
function Walk.Leave()
	Walk.session = nil
	hook.Remove("CreateMove", MOVE_HOOK)
	hook.Remove("HUDPaint", HUD_HOOK)
end

local function leaveKeyName()
	return string.upper(input.LookupBinding("+reload") or "R")
end

local function drawLeaveHint()
	draw.SimpleTextOutlined("Press " .. leaveKeyName() .. " to leave", "DermaLarge", ScrW() / 2, ScrH() - 48, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM, 1, color_black)
end

function Walk.ToggleNoclip()
	local session = Walk.session
	if not session then return end
	local mv = session.move
	if session.noclip then
		local duck = bit.band(mv.buttons, IN_DUCK) ~= 0
		local trace = session:TraceHull(mv.origin, mv.origin, Vector(-16, -16, 0), Vector(16, 16, duck and 36 or 72))
		if trace.StartSolid then
			chat.AddText("[PocketMap] Move out of the solid geometry before turning noclip off.")
			return
		end
	end
	-- The velocity stays as it is, in both directions: noclip has its own friction, and walking on goes on from where the flight was
	session.noclip = not session.noclip
	chat.AddText("[PocketMap] Noclip " .. (session.noclip and "on" or "off") .. ".")
end

concommand.Add("pocketmap_noclip", Walk.ToggleNoclip)

local function spawnPoint(session)
	local candidates = {}
	for _, ent in pairs(session.bsp:GetEntities()) do
		if ent.origin and (ent.classname == "info_player_start" or string.StartWith(ent.classname or "", "info_player_")) then
			candidates[#candidates + 1] = ent
		end
	end
	for _, ent in ipairs(candidates) do
		local pos = isvector(ent.origin) and ent.origin or Vector(ent.origin)
		pos = pos + Vector(0, 0, 2)
		if not session:TraceHull(pos, pos, Vector(-16, -16, 0), Vector(16, 16, 72)).StartSolid then
			return pos, isangle(ent.angles) and ent.angles or Angle(0, 0, 0)
		end
	end
end

local createMove

---@param ent Entity # the block to walk in
function Walk.Enter(ent)
	local ply = LocalPlayer()
	if Walk.session or not IsValid(ply) or not ply:Alive() or ply:InVehicle() then return end
	local mini = IsValid(ent) and ent.Miniature
	if not mini or mini.state ~= "ready" then
		chat.AddText("[PocketMap] Aim at a loaded Pocket Map first.")
		return
	end

	-- The first time in a map: its collision is read in the background (cl_physics.lua), then this goes on
	if mini.physics == nil then
		if not mini.physicsPreparing then chat.AddText("[PocketMap] Preparing the collision of this map...") end
		PocketMap.Physics.Prepare(mini, function()
			if IsValid(ent) and not Walk.session then Walk.Enter(ent) end
		end)
		return
	end

	local session = setmetatable({ mini = mini, bsp = mini.bsp, nodes = mini.bsp:GetNodes(), leafs = mini.bsp:GetLeafs(), displacements = mini.displacementCollision, physics = mini.physics or nil }, Session)
	local pos, angles = spawnPoint(session)
	if not pos then chat.AddText("[PocketMap] No clear player spawn was found in this map.") return end
	session.move = setmetatable({ origin = pos, velocity = Vector(), angles = angles, moveAngles = angles, buttons = 0, oldButtons = 0, forward = 0, side = 0, up = 0, maxSpeed = 320, maxClientSpeed = 320, impulse = 0, constraintCenter = Vector(), constraintRadius = 0, constraintWidth = 0, constraintSpeedFactor = 1, finalStepHeight = 0, finalIdealVelocity = Vector(), finalJumpVelocity = Vector() }, { __index = Move })
	session.yawOffset = angles.y - ply:EyeAngles().y
	Walk.session = session
	hook.Add("CreateMove", MOVE_HOOK, createMove)
	hook.Add("HUDPaint", HUD_HOOK, drawLeaveHint)
	chat.AddText("[PocketMap] Walking: WASD, Space to jump, Ctrl to crouch. Your noclip key (default V) toggles flight. Press " .. leaveKeyName() .. " to leave.")
end

concommand.Add("pocketmap_walk", function()
	if Walk.session then Walk.Leave() return end
	local ply = LocalPlayer()
	if IsValid(ply) then Walk.Enter(ply:GetEyeTrace().Entity) end
end)

function createMove(cmd)
	local session = Walk.session
	if not session then return end
	local ply, mini = LocalPlayer(), session.mini
	if not IsValid(ply) or not ply:Alive() or ply:InVehicle() or not IsValid(mini.ent) or mini.state ~= "ready" then Walk.Leave() return end
	local mv = session.move
	local number = cmd:CommandNumber()
	if number > 0 and session.command ~= number then
		session.command = number
		mv.oldButtons = mv.buttons
		mv.buttons, mv.forward, mv.side, mv.up = cmd:GetButtons(), cmd:GetForwardMove(), cmd:GetSideMove(), cmd:GetUpMove()
		local angles = cmd:GetViewAngles()
		mv.angles = Angle(angles.p, angles.y + session.yawOffset, 0)
		mv.moveAngles = mv.angles
		mv.maxSpeed, mv.maxClientSpeed = ply:GetRunSpeed(), ply:GetRunSpeed()
		mv.speedModified = false
		mv.impulse = cmd:GetImpulse()
		local ok, err = PocketMap.GamemodeMovement.Step(ply, mv, cmd, session)
		if not ok then
			Walk.Leave()
			ErrorNoHalt("[PocketMap] Gamemode movement callback failed: " .. tostring(err) .. "\n")
			chat.AddText("[PocketMap] Walk mode ended because a gamemode movement callback failed; see the console.")
		elseif not session.stepsFailed then
			-- A problem with a sound must not stop the movement: it is reported once and the walk goes on without footsteps
			local stepped, stepError = pcall(function() PocketMap.Footsteps.Update(session, engine.TickInterval()) end)
			if not stepped then
				session.stepsFailed = true
				ErrorNoHalt("[PocketMap] Footsteps: " .. tostring(stepError) .. "\n")
			end
		end
	end
	cmd:ClearMovement()
	cmd:ClearButtons()
end

function Walk.View(fov, zfar)
	local session = Walk.session
	if not session or not IsValid(session.mini.ent) or session.mini.state ~= "ready" then Walk.Leave() return end
	local mini, mv = session.mini, session.move
	local height = not session.noclip and bit.band(mv.buttons, IN_DUCK) ~= 0 and 28 or 64
	local eye = mv.origin + Vector(0, 0, height)
	local origin = mini.ent:LocalToWorld((eye - mini.mapCenter) * mini.scale + mini.boxCenter)
	local angles = mini.ent:LocalToWorldAngles(mv.angles)
	local near = math.max(0.001, mini.scale * 0.5)
	PocketMap.Water.NoteView(origin, angles, fov, near, zfar)
	return { origin = origin, angles = angles, fov = fov, znear = near, zfar = zfar, drawviewer = true }
end

---The block the player is looking at and is close enough to use.
local function aimedBlock(ply)
	local trace = ply:GetEyeTrace()
	local ent = trace.Entity
	if not IsValid(ent) or ent:GetClass() ~= "ent_pocketmap" then return end
	if trace.HitPos:DistToSqr(ply:EyePos()) > REACH_SQR then return end
	return ent
end

-- Reload on a block walks in, reload inside walks out. In a walk the normal noclip binding controls the local camera session.
-- Registered in cl_hooks.lua, so it exists as long as a tiny map does.
PocketMap.Hooks.Register("PlayerBindPress", "PocketMap_WalkKey", function(ply, bind, pressed)
	bind = string.lower(string.Trim(bind))

	if Walk.session then
		if bind == "noclip" then
			if pressed then Walk.ToggleNoclip() end
			return true
		elseif bind == "+reload" then
			if pressed then Walk.Leave() end
			return true
		end
		return
	end

	if bind == "+reload" then
		local ent = aimedBlock(ply)
		if not ent or not ent.Miniature or ent.Miniature.state ~= "ready" then return end
		if pressed then Walk.Enter(ent) end
		return true
	end
end)
