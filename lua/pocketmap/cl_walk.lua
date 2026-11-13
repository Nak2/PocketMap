-- A local camera and movement session, simulated in the original BSP coordinates.
-- Replace any always-installed hooks left by the previous walk implementation.
hook.Remove("CreateMove", "PocketMap_Walk")
hook.Remove("PlayerBindPress", "PocketMap_Noclip")
PocketMap.Walk = PocketMap.Walk or {}
local Walk = PocketMap.Walk
local Session = {}
Session.__index = Session

-- Animate the view independently from movement ticks, using the movement
-- settings on the player. This also handles changing direction mid-duck.
function Walk.EyeOffset(session)
	local ply = LocalPlayer()
	local standing = ply:GetViewOffset()
	local ducked = ply:GetViewOffsetDucked()
	-- The view transition leads the collision-hull switch. Source retains
	-- the old hull until the duck/unduck animation completes.
	local target = not session.noclip and session.duckTarget and ducked or standing
	local now = RealTime()
	local current = session.viewOffset
	if not current then
		current = Vector(standing.x, standing.y, standing.z)
		session.viewOffset = current
	end

	local function progress()
		local duration = session.viewDuration or 0
		local fraction = duration > 0 and math.Clamp((now - session.viewStarted) / duration, 0, 1) or 1
		return fraction * fraction * (3 - 2 * fraction)
	end

	if session.viewTarget then
		local fraction = progress()
		current.x = Lerp(fraction, session.viewFrom.x, session.viewTarget.x)
		current.y = Lerp(fraction, session.viewFrom.y, session.viewTarget.y)
		current.z = Lerp(fraction, session.viewFrom.z, session.viewTarget.z)
		if fraction >= 1 then
			-- Source's duck flag becomes visible only after the transition ends.
			session.crouchFlag = session.viewTarget:DistToSqr(ducked) < 0.001
		end
	end

	if not session.viewTarget or session.viewTarget:DistToSqr(target) > 0.000001 then
		session.viewFrom = Vector(current.x, current.y, current.z)
		session.viewTarget = Vector(target.x, target.y, target.z)
		-- The native crouch eye animation starts on the following movement tick.
		-- Match that delay so the camera doesn't drop a frame ahead of the hull.
		session.viewStarted = now + engine.TickInterval()
		local duration = session.duckTarget and ply:GetDuckSpeed() or ply:GetUnDuckSpeed()
		session.viewDuration = math.max(0, duration or 0)
	end

	return current
end

-- Query the BSP's spatial partition instead of scanning every leaf on every
-- ground, stair, ladder and slide probe. Child indices < 0 encode leaf indices.
function Session:QueryLeafs(lo, hi)
	local result, stack = {}, { 0 }
	local lx, ly, lz, hx, hy, hz = lo.x, lo.y, lo.z, hi.x, hi.y, hi.z
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
				local nx, ny, nz = n.x, n.y, n.z
				local low = nx * (nx < 0 and hx or lx) + ny * (ny < 0 and hy or ly) + nz * (nz < 0 and hz or lz) - dist
				local high = nx * (nx < 0 and lx or hx) + ny * (ny < 0 and ly or hy) + nz * (nz < 0 and lz or hz) - dist
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
	-- Vector component access crosses the engine boundary. Read each input
	-- once instead of doing that again for every side of every queried brush.
	local sx, sy, sz = start.x, start.y, start.z
	local ex, ey, ez = finish.x, finish.y, finish.z
	local minX, minY, minZ = mins.x, mins.y, mins.z
	local maxX, maxY, maxZ = maxs.x, maxs.y, maxs.z
	out = out or {}
	out.Fraction, out.Hit, out.StartSolid, out.AllSolid = 1, false, false, false
	out.HitWorld, out.Entity = false, game.GetWorld()
	out.HitNormal = Vector(0, 0, 0)
	out.Contents, out.SurfaceProps = 0, 0
	out.Displacement = false
	out.Texinfo, out.SurfaceName = nil, nil -- the surface that was hit, for the sound of a step: a texinfo, or the name of a surface property
	local lo = {x = math.min(sx, ex) + minX, y = math.min(sy, ey) + minY, z = math.min(sz, ez) + minZ}
	local hi = {x = math.max(sx, ex) + maxX, y = math.max(sy, ey) + maxY, z = math.max(sz, ez) + maxZ}
	local seen = {}
	for _, leaf in ipairs(self:QueryLeafs(lo, hi)) do
		for _, brush in ipairs(leaf:GetBrushes()) do
			if not seen[brush] and bit.band(brush.contents, mask or MASK_PLAYERSOLID) ~= 0 then
				seen[brush] = true
				local enter, leave, normal, hitTexinfo = -1, 1, nil, nil
				local outside, endOutside, rejected = false, false, false
				for _, side in ipairs(brush.sides) do
					local n, dist = side.plane.normal, side.plane.dist
					local nx, ny, nz = n.x, n.y, n.z
					local offset = nx * (nx < 0 and maxX or minX) + ny * (ny < 0 and maxY or minY) + nz * (nz < 0 and maxZ or minZ)
					local d1 = nx * sx + ny * sy + nz * sz + offset - dist
					local d2 = nx * ex + ny * ey + nz * ez + offset - dist
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
	PocketMap.MapIO.Trace(self, start, finish, mins, maxs, out)
	out.Hit = out.Fraction < 1 or out.StartSolid
	out.HitWorld = out.Hit
	out.HitPos = {x = sx + (ex - sx) * out.Fraction, y = sy + (ey - sy) * out.Fraction, z = sz + (ez - sz) * out.Fraction}
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
	if PocketMap.Flashlight then PocketMap.Flashlight.Stop() end
	local session = Walk.session
	Walk.session = nil
	if PocketMap.GamemodeMovement then PocketMap.GamemodeMovement.Reset() end
	hook.Remove("CreateMove", MOVE_HOOK)
	hook.Remove("SetupMove", MOVE_HOOK)
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
		local mins, maxs = PocketMap.Movement.PlayerHull(LocalPlayer(), duck)
		local trace = session:TraceHull(mv.origin, mv.origin, mins, maxs)
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
	local mins, maxs = PocketMap.Movement.PlayerHull(LocalPlayer(), false)
	return not session:TraceHull(position, position, mins, maxs).StartSolid
end

local function randomClearSpawn(session)
	local spawns = spawnEntities(session.bsp)
	table.Shuffle(spawns)

	for _, ent in ipairs(spawns) do
		local position = spawnPosition(ent)
		if isSpawnClear(session, position) then return position, isangle(ent.angles) and ent.angles or Angle(0, 0, 0) end
	end
end

local createMove, setupMove, runStep

-- Source-map traces without creating a player or changing the active session.
function Walk.CollisionSession(mini, io)
	return setmetatable({ mini = mini, bsp = mini.bsp, nodes = mini.bsp:GetNodes(), leafs = mini.bsp:GetLeafs(),
		displacements = mini.displacementCollision, physics = mini.physics or nil, io = io or PocketMap.MapIO.NewSession(mini) }, Session)
end

local function newWalkSession(ply, mini, io)
	local session = Walk.CollisionSession(mini, io)
	local pos, angles = randomClearSpawn(session)
	if not pos then return end
	session.move = setmetatable({ origin = pos, velocity = Vector(), angles = angles, moveAngles = angles, buttons = 0, oldButtons = 0, forward = 0, side = 0, up = 0, maxSpeed = 320, maxClientSpeed = 320, impulse = 0, constraintCenter = Vector(), constraintRadius = 0, constraintWidth = 0, constraintSpeedFactor = 1, finalStepHeight = 0, finalIdealVelocity = Vector(), finalJumpVelocity = Vector() }, { __index = Move })
	session.yawOffset = angles.y - ply:EyeAngles().y
	session.ducking, session.duckTarget, session.crouchFlag = false, false, false
	session.enteredAt = RealTime()
	session.command, session.inputs = 0, {}
	return session
end

function Walk.Respawn()
	local previous, ply = Walk.session, LocalPlayer()
	if not previous or not IsValid(ply) or not ply:Alive() then return false end
	local mini = previous.mini
	if not IsValid(mini.ent) or mini.state ~= "ready" then return false end
	-- A new movement session clears crouching, fall speed, ladders and cached
	-- commands. Keep the miniature's doors and other map logic as they were.
	local session = newWalkSession(ply, mini, previous.io)
	if not session then return false end
	session.io.touching = {}
	if PocketMap.GamemodeMovement then PocketMap.GamemodeMovement.Reset() end
	Walk.session = session
	sendWalkState(session, true, false)
	return true
end

net.Receive("PocketMap_Respawn", function()
	local block, session = net.ReadEntity(), Walk.session
	if session and session.mini.ent == block then session.respawnReady = true end
end)

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

	local session = newWalkSession(ply, mini)
	if not session then chat.AddText("[PocketMap] No clear player spawn was found in this map.") return end
	Walk.session = session
	hook.Add("CreateMove", MOVE_HOOK, createMove)
	hook.Add("SetupMove", MOVE_HOOK, setupMove)
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
	if mini.entityRefresh then
		session.inputs = {}
		cmd:ClearMovement()
		cmd:ClearButtons()
		return
	end
	if not IsValid(ply) or ply:InVehicle() or not IsValid(mini.ent) or mini.state ~= "ready" then Walk.Leave() return end
	if not ply:Alive() then
		session.waitingForRespawn, session.inputs = true, {}
		cmd:ClearMovement()
		return -- Keep attack/use available for the gamemode's normal respawn.
	end
	if session.respawnReady then
		if Walk.Respawn() then session = Walk.session end
	end
	if session.waitingForRespawn then cmd:ClearMovement() return end

	local number = cmd:CommandNumber()
	if number > 0 and number > session.command and not session.inputs[number] then
		session.inputs[number] = {
			buttons = cmd:GetButtons(), forward = cmd:GetForwardMove(), side = cmd:GetSideMove(), up = cmd:GetUpMove(),
			angles = cmd:GetViewAngles(), impulse = cmd:GetImpulse(),
		}
	end
	-- Singleplayer has no client prediction: SetupMove never runs on the client,
	if game.SinglePlayer() then runStep(ply, session, cmd, number) end
	cmd:ClearMovement()
	cmd:ClearButtons()
end

-- Applies the stashed input for one user command and runs the virtual step.
function runStep(ply, session, cmd, number)
	local input = session.inputs[number]
	if not input or number <= session.command then return end

	session.command = number
	for stashed in pairs(session.inputs) do
		if stashed <= number then session.inputs[stashed] = nil end
	end

	local mv = session.move
	mv.oldButtons = mv.buttons
	mv.buttons, mv.forward, mv.side, mv.up = input.buttons, input.forward, input.side, input.up
	mv.angles = Angle(input.angles.p, input.angles.y + session.yawOffset, 0)
	mv.moveAngles = mv.angles
	mv.maxSpeed, mv.maxClientSpeed = ply:GetRunSpeed(), ply:GetRunSpeed()
	mv.speedModified = false
	mv.impulse = input.impulse
	PocketMap.GamemodeMovement.Step(ply, mv, cmd, session)
	PocketMap.MapIO.Step( session, engine.TickInterval() )
	if isNoclippingOutsideBlock(session) then
		Walk.Leave()
	else
		updateFootstepsOnce(session)
		sendWalkStateIfDue(session)
	end
end

function setupMove(ply, _, cmd)
	local session = Walk.session
	if not session or session.mini.entityRefresh or ply ~= LocalPlayer() or not ply:Alive() or session.waitingForRespawn or PocketMap.GamemodeMovement.active then return end
	runStep(ply, session, cmd, cmd:CommandNumber())
end

function Walk.View(fov, zfar)
	local session = Walk.session
	if session and session.mini.entityRefresh then return session.lastView end
	if not session or not IsValid(session.mini.ent) or session.mini.state ~= "ready" then Walk.Leave() return end
	local mini, mv = session.mini, session.move
	local eye = mv.origin + Walk.EyeOffset(session)
	local origin = mini.ent:LocalToWorld((eye - mini.mapCenter) * mini.scale + mini.boxCenter)
	local angles = mini.ent:LocalToWorldAngles(mv.angles)
	-- Keep the source map's normal 7-unit near clip after scaling it into the
	-- miniature. Half a source unit exhausts depth precision at distant props,
	-- causing faces to flicker as the camera moves.
	local near = math.max(0.001, mini.scale * 7)
	PocketMap.Water.NoteView(origin, angles, fov, near, zfar)
	local view = { origin = origin, angles = angles, fov = fov, znear = near, zfar = zfar, drawviewer = true }
	session.lastView = view
	return view
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

-- Refresh the callbacks and collision methods without dropping a live walk.
if Walk.session then
	setmetatable(Walk.session, Session)
	hook.Add("CreateMove", MOVE_HOOK, createMove)
	hook.Add("SetupMove", MOVE_HOOK, setupMove)
	hook.Add("HUDPaint", HUD_HOOK, drawWalkHud)
end
