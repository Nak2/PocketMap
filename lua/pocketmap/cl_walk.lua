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

function Session:TracePropsAndDisplacements(start, finish, mins, maxs, mask, lo, hi, out)
	if self.physics then PocketMap.Physics.Trace(self.physics, start, finish, mins, maxs, mask, lo, hi, out) end
	if self.displacements then PocketMap.Displacements.Trace(self.displacements, start, finish, mins, maxs, mask, lo, hi, out) end
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
						out.Contents, out.Texinfo, out.SurfaceName = brush.contents, hitTexinfo, nil
					end
				end
			end
		end
	end
	self:TracePropsAndDisplacements(start, finish, mins, maxs, mask, lo, hi, out)
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
local ENTER_SOUND = "ambient/levels/advisor_barn/ol07_advisor_00_09_17.wav"
local LEAVE_SOUND = "ambient/levels/advisor_barn/ol07_advisor_00_12_11.wav"
local ENTER_FADE_SECONDS = 1
local ENTER_FADE_HOLD_FRACTION = 0.2
local ENTER_FADE_COLOR = Color(190, 215, 255)
local TELEPORT_FLASH_EFFECT, TELEPORT_RING_EFFECT = "cball_bounce", "VortDispel"
local TELEPORT_BLOCK_FLASH_RADIUS = 20
local TELEPORT_PLAYER_FLASH_RADIUS = 6
local TELEPORT_PLAYER_FLASH_HEIGHT = 36
local WALK_SEND_INTERVAL = 0.05
local KEY_HINT_CAP_SIZE = 48
local KEY_HINT_GAP = 12
local KEY_HINT_BOTTOM_MARGIN = 48
local KEYCAP_FONT = "PocketMap_KeyCap"
local KEYCAP_DESIGN_SIZE = 128
local KEYCAP_CORNER_RADIUS = 20
local KEYCAP_FACE_CORNER_RADIUS = 16
local KEYCAP_DEPTH = 12
local KEYCAP_BORDER = 8
local KEYCAP_SHADOW_COLOR, KEYCAP_EDGE_COLOR = Color(60, 60, 60), Color(150, 150, 150)
local KEYCAP_FACE_COLOR, KEYCAP_TEXT_COLOR = Color(235, 235, 235), Color(40, 40, 40)

surface.CreateFont(KEYCAP_FONT, { font = "Tahoma", size = 84, weight = 800, antialias = true })

local keyCapMatrix, keyCapTranslation, keyCapScale = Matrix(), Vector(), Vector()

local function playEffect(name, origin, radius)
	local data = EffectData()
	data:SetOrigin(origin)
	data:SetNormal(vector_up)
	data:SetRadius(radius or 0)
	util.Effect(name, data)
end

local function playTeleportEffects(session, ply)
	local block = session.mini.ent
	if IsValid(block) then playEffect(TELEPORT_FLASH_EFFECT, block:LocalToWorld((block.BoxMins + block.BoxMaxs) / 2), TELEPORT_BLOCK_FLASH_RADIUS) end
	if not IsValid(ply) then return end

	local feet = ply:GetPos()
	playEffect(TELEPORT_RING_EFFECT, feet)
	playEffect(TELEPORT_FLASH_EFFECT, feet + vector_up * TELEPORT_PLAYER_FLASH_HEIGHT, TELEPORT_PLAYER_FLASH_RADIUS)
end

local function sendWalkState(session, active, unreliable)
	local block = session.mini.ent
	if not IsValid(block) then return end

	local mini = session.mini
	net.Start("PocketMap_Ply", unreliable)
		net.WriteEntity(block)
		net.WriteBool(active)
		if active then
			net.WriteVector(session.move.velocity * mini.scale)
			net.WriteVector(block:ClampToBox(mini:BlockPosition(session.move.origin)))
			net.WriteAngle(session.move.angles)
		end
	net.SendToServer()
end

local function sendWalkStateIfDue(session)
	if RealTime() < (session.nextSend or 0) then return end

	session.nextSend = RealTime() + WALK_SEND_INTERVAL
	sendWalkState(session, true, true)
end

function Walk.Leave()
	local session = Walk.session
	Walk.session = nil
	hook.Remove("CreateMove", MOVE_HOOK)
	hook.Remove("HUDPaint", HUD_HOOK)
	if not session then return end

	sendWalkState(session, false)
	surface.PlaySound(LEAVE_SOUND)
	playTeleportEffects(session, LocalPlayer())
end

function Walk.ReloadKeyName()
	return string.upper(input.LookupBinding("+reload") or "R")
end

local function drawKeyCap(key)
	local bodyHeight = KEYCAP_DESIGN_SIZE - KEYCAP_DEPTH
	local faceSize = KEYCAP_DESIGN_SIZE - 2 * KEYCAP_BORDER
	draw.RoundedBox(KEYCAP_CORNER_RADIUS, 0, KEYCAP_DEPTH, KEYCAP_DESIGN_SIZE, bodyHeight, KEYCAP_SHADOW_COLOR)
	draw.RoundedBox(KEYCAP_CORNER_RADIUS, 0, 0, KEYCAP_DESIGN_SIZE, bodyHeight, KEYCAP_EDGE_COLOR)
	draw.RoundedBox(KEYCAP_FACE_CORNER_RADIUS, KEYCAP_BORDER, KEYCAP_BORDER, faceSize, bodyHeight - 2 * KEYCAP_BORDER, KEYCAP_FACE_COLOR)
	draw.SimpleText(key, KEYCAP_FONT, KEYCAP_DESIGN_SIZE / 2, bodyHeight / 2, KEYCAP_TEXT_COLOR, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end

-- Everything is drawn at positive coordinates: the clip rectangle of the screen applies before the matrix
local function drawKeyCapCenteredAt(x, y, size, key)
	local scale = size / KEYCAP_DESIGN_SIZE
	keyCapTranslation.x, keyCapTranslation.y = x - size / 2, y - size / 2
	keyCapScale.x, keyCapScale.y, keyCapScale.z = scale, scale, 1

	keyCapMatrix:Identity()
	keyCapMatrix:Translate(keyCapTranslation)
	keyCapMatrix:Scale(keyCapScale)

	cam.PushModelMatrix(keyCapMatrix)
	drawKeyCap(key)
	cam.PopModelMatrix()
end

local function drawKeyHintAsText(key, action)
	draw.SimpleTextOutlined("Press " .. key .. " to " .. action, "DermaLarge", ScrW() / 2, ScrH() - KEY_HINT_BOTTOM_MARGIN, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM, 1, color_black)
end

local function drawKeyHintWithKeyCap(key, action)
	local afterText = "to " .. action
	surface.SetFont("DermaLarge")
	local beforeWidth = surface.GetTextSize("Press")
	local afterWidth = surface.GetTextSize(afterText)
	local left = (ScrW() - (beforeWidth + afterWidth + KEY_HINT_CAP_SIZE + 2 * KEY_HINT_GAP)) / 2
	local centerY = ScrH() - KEY_HINT_BOTTOM_MARGIN - KEY_HINT_CAP_SIZE / 2

	draw.SimpleTextOutlined("Press", "DermaLarge", left, centerY, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, 1, color_black)
	drawKeyCapCenteredAt(left + beforeWidth + KEY_HINT_GAP + KEY_HINT_CAP_SIZE / 2, centerY, KEY_HINT_CAP_SIZE, key)
	draw.SimpleTextOutlined(afterText, "DermaLarge", left + beforeWidth + 2 * KEY_HINT_GAP + KEY_HINT_CAP_SIZE, centerY, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, 1, color_black)
end

local function drawKeyHint(action)
	local key = Walk.ReloadKeyName()
	if #key == 1 then drawKeyHintWithKeyCap(key, action) else drawKeyHintAsText(key, action) end
end

local function drawLeaveHint()
	drawKeyHint("leave")
end

local function enterFadeAlpha(enteredAt)
	local progress = (RealTime() - enteredAt) / ENTER_FADE_SECONDS
	if progress >= 1 then return 0 end
	if progress <= ENTER_FADE_HOLD_FRACTION then return 255 end
	return 255 * (1 - (progress - ENTER_FADE_HOLD_FRACTION) / (1 - ENTER_FADE_HOLD_FRACTION))
end

local function drawEnterFade(enteredAt)
	local alpha = enterFadeAlpha(enteredAt)
	if alpha <= 0 then return end

	surface.SetDrawColor(ENTER_FADE_COLOR.r, ENTER_FADE_COLOR.g, ENTER_FADE_COLOR.b, alpha)
	surface.DrawRect(0, 0, ScrW(), ScrH())
end

local function drawWalkHud()
	drawLeaveHint()
	drawEnterFade(Walk.session.enteredAt)
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
	chat.AddText("[PocketMap] Noclip " .. (session.noclip and "on" or "off") .. ".")
end

concommand.Add("pocketmap_noclip", Walk.ToggleNoclip)

local SPAWN_CLASS_PREFIX = "info_player_"
local SPAWN_CLASSES = { info_player_start = true, info_player_teamspawn = true, info_coop_spawn = true, info_survivor_position = true }
local SPAWN_LIFT = Vector(0, 0, 2)
local STAND_MINS, STAND_MAXS = Vector(-16, -16, 0), Vector(16, 16, 72)

local function isSpawnEntity(ent)
	local class = ent.classname or ""
	return ent.origin ~= nil and (SPAWN_CLASSES[class] or string.StartWith(class, SPAWN_CLASS_PREFIX))
end

local function spawnEntities(bsp)
	local spawns = {}
	for _, ent in pairs(bsp:GetEntities()) do
		if isSpawnEntity(ent) then spawns[#spawns + 1] = ent end
	end
	return spawns
end

local function spawnPosition(ent)
	return (isvector(ent.origin) and ent.origin or Vector(ent.origin)) + SPAWN_LIFT
end

local function isSpawnClear(session, position)
	return not session:TraceHull(position, position, STAND_MINS, STAND_MAXS).StartSolid
end

local function randomClearSpawn(session)
	local spawns = spawnEntities(session.bsp)
	table.Shuffle(spawns)

	for _, ent in ipairs(spawns) do
		local position = spawnPosition(ent)
		if isSpawnClear(session, position) then return position, isangle(ent.angles) and ent.angles or Angle(0, 0, 0) end
	end
end

local createMove

local function prepareCollisionThenEnter(ent, mini)
	PocketMap.Physics.Prepare(mini, function()
		if IsValid(ent) and not Walk.session then Walk.Enter(ent) end
	end)
end

---@param ent Entity
function Walk.Enter(ent)
	local ply = LocalPlayer()
	if Walk.session or not IsValid(ply) or not ply:Alive() or ply:InVehicle() then return end
	local mini = IsValid(ent) and ent.Miniature
	if not mini or mini.state ~= "ready" then
		chat.AddText("[PocketMap] Aim at a loaded Pocket Map first.")
		return
	end

	if mini.physics == nil then return prepareCollisionThenEnter(ent, mini) end

	local session = setmetatable({ mini = mini, bsp = mini.bsp, nodes = mini.bsp:GetNodes(), leafs = mini.bsp:GetLeafs(), displacements = mini.displacementCollision, physics = mini.physics or nil }, Session)
	local pos, angles = randomClearSpawn(session)
	if not pos then chat.AddText("[PocketMap] No clear player spawn was found in this map.") return end
	session.move = setmetatable({ origin = pos, velocity = Vector(), angles = angles, moveAngles = angles, buttons = 0, oldButtons = 0, forward = 0, side = 0, up = 0, maxSpeed = 320, maxClientSpeed = 320, impulse = 0, constraintCenter = Vector(), constraintRadius = 0, constraintWidth = 0, constraintSpeedFactor = 1, finalStepHeight = 0, finalIdealVelocity = Vector(), finalJumpVelocity = Vector() }, { __index = Move })
	session.yawOffset = angles.y - ply:EyeAngles().y
	session.enteredAt = RealTime()
	Walk.session = session
	hook.Add("CreateMove", MOVE_HOOK, createMove)
	hook.Add("HUDPaint", HUD_HOOK, drawWalkHud)
	surface.PlaySound(ENTER_SOUND)
	playTeleportEffects(session, ply)
	sendWalkState(session, true, false)
	chat.AddText("[PocketMap] Walking: WASD, Space to jump, Ctrl to crouch. Your noclip key (default V) toggles flight. Press " .. Walk.ReloadKeyName() .. " to leave.")
end

concommand.Add("pocketmap_walk", function()
	if Walk.session then Walk.Leave() return end
	local ply = LocalPlayer()
	if IsValid(ply) then Walk.Enter(ply:GetEyeTrace().Entity) end
end)

local function isNoclippingOutsideBlock(session)
	if not session.noclip then return false end

	local mini = session.mini
	return mini.ent:IsOutsideBox(mini.ent:LocalToWorld(mini:BlockPosition(session.move.origin)))
end

local function updateFootstepsOnce(session)
	if session.stepsFailed then return end

	local ok, err = pcall(function() PocketMap.Footsteps.Update(session, engine.TickInterval()) end)
	if ok then return end

	session.stepsFailed = true
	ErrorNoHalt("[PocketMap] Footsteps: " .. tostring(err) .. "\n")
end

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
		elseif isNoclippingOutsideBlock(session) then
			Walk.Leave()
		else
			updateFootstepsOnce(session)
			sendWalkStateIfDue(session)
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

local function aimedBlock(ply)
	local trace = ply:GetEyeTrace()
	local ent = trace.Entity
	if not IsValid(ent) or ent:GetClass() ~= "ent_pocketmap" then return end
	if trace.HitPos:DistToSqr(ply:EyePos()) > REACH_SQR then return end
	return ent
end

local function enterableBlock(ply)
	local ent = aimedBlock(ply)
	if ent and ent.Miniature and ent.Miniature.state == "ready" then return ent end
end

PocketMap.Hooks.Register("HUDPaint", "PocketMap_EnterHint", function()
	local ply = LocalPlayer()
	if not Walk.session and IsValid(ply) and enterableBlock(ply) then drawKeyHint("enter") end
end)

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
		local ent = enterableBlock(ply)
		if not ent then return end
		if pressed then Walk.Enter(ent) end
		return true
	end
end)
