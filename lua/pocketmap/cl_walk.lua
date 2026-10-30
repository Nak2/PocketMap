-- A local camera and movement session, simulated in the original BSP coordinates.
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
	local lo = {x = math.min(start.x, finish.x) + mins.x, y = math.min(start.y, finish.y) + mins.y, z = math.min(start.z, finish.z) + mins.z}
	local hi = {x = math.max(start.x, finish.x) + maxs.x, y = math.max(start.y, finish.y) + maxs.y, z = math.max(start.z, finish.z) + maxs.z}
	local seen = {}
	for _, leaf in ipairs(self:QueryLeafs(lo, hi)) do
		for _, brush in ipairs(leaf:GetBrushes()) do
			if not seen[brush] and bit.band(brush.contents, mask or MASK_PLAYERSOLID) ~= 0 then
				seen[brush] = true
				local enter, leave, normal = -1, 1, nil
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
							if f > enter then enter, normal = f, n end
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
						out.Contents = brush.contents
					end
				end
			end
		end
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

function Walk.Leave()
	Walk.session = nil
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
	session.noclip = not session.noclip
	mv.velocity = Vector()
	chat.AddText("[PocketMap] Noclip " .. (session.noclip and "on" or "off") .. ".")
end

concommand.Add("pocketmap_noclip", Walk.ToggleNoclip)

-- Consume the normal noclip binding so it controls the local camera session.
hook.Add("PlayerBindPress", "PocketMap_Noclip", function(_, bind, pressed)
	if Walk.session and string.lower(string.Trim(bind)) == "noclip" then
		if pressed then Walk.ToggleNoclip() end
		return true
	end
end)

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

concommand.Add("pocketmap_walk", function()
	if Walk.session then Walk.Leave() return end
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() or ply:InVehicle() then return end
	local ent = ply:GetEyeTrace().Entity
	local mini = IsValid(ent) and ent.Miniature
	if not mini or mini.state ~= "ready" then
		chat.AddText("[PocketMap] Aim at a loaded Pocket Map first.")
		return
	end
	local session = setmetatable({ mini = mini, bsp = mini.bsp, nodes = mini.bsp:GetNodes(), leafs = mini.bsp:GetLeafs() }, Session)
	local pos, angles = spawnPoint(session)
	if not pos then chat.AddText("[PocketMap] No clear player spawn was found in this map.") return end
	session.move = setmetatable({ origin = pos, velocity = Vector(), angles = angles, moveAngles = angles, buttons = 0, oldButtons = 0, forward = 0, side = 0, up = 0, maxSpeed = 320, maxClientSpeed = 320, impulse = 0, constraintCenter = Vector(), constraintRadius = 0, constraintWidth = 0, constraintSpeedFactor = 1, finalStepHeight = 0, finalIdealVelocity = Vector(), finalJumpVelocity = Vector() }, { __index = Move })
	session.yawOffset = angles.y - ply:EyeAngles().y
	Walk.session = session
	chat.AddText("[PocketMap] Walking: WASD, Space to jump, Ctrl to crouch. Your noclip key (default V) toggles flight. Run pocketmap_walk again to leave.")
end)

hook.Add("CreateMove", "PocketMap_Walk", function(cmd)
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
		end
	end
	cmd:ClearMovement()
	cmd:ClearButtons()
end)

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
