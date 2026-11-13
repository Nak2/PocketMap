-- A trigger_teleport moves the virtual walker to its info_teleport_destination.
local IO = PocketMap.MapIO
local EMPTY = {}

-- One trigger entity can contain several convex brushes. Its bmodel bounds
-- enclose the gaps too (surf_ace uses those gaps for drops into later ramps).
local function triggerBrushes( _, record )
	if not record.model then return end
	local brushes = record.model:GetBrushes()
	return #brushes > 0 and brushes or nil
end

-- Brush geometry is immutable after BSP load, while trigger angles can change
-- during a walking session. Cache transformed plane normals until those angles
-- change; this avoids engine LocalToWorld calls for every side on each step.
local function rotatedNormals( session, record, brushes, angles )
	local state = session.io
	local cache = state and state.teleportNormals
	local entry = cache and cache[record]
	if entry and entry.brushes == brushes and entry.p == angles.p
		and entry.y == angles.y and entry.r == angles.r then return entry.normals end
	local normals = {}
	local zeroAngle, zeroVector = Angle(), Vector()
	for i, brush in ipairs( brushes ) do
		local sides = {}
		for j, side in ipairs( brush.sides ) do
			sides[j] = LocalToWorld( side.plane.normal, zeroAngle, zeroVector, angles )
		end
		normals[i] = sides
	end
	if state then
		if not cache then cache = {} state.teleportNormals = cache end
		cache[record] = { brushes = brushes, p = angles.p, y = angles.y,
			r = angles.r, normals = normals }
	end
	return normals
end

function IO.TeleportOverlaps( session, record, mins, maxs )
	if not mins and PocketMap.Movement then mins, maxs = PocketMap.Movement.PlayerHull( LocalPlayer(), session.ducking ) end
	mins, maxs = mins or Vector( -16, -16, 0 ), maxs or Vector( 16, 16, 72 )
	if not IO.Overlaps( session, record, mins, maxs ) then return false end
	local brushes = triggerBrushes( session, record )
	if not brushes then return true end
	local origin, angles = IO.Position( session.io, record ), IO.Rotation( session.io, record )
	local rotated = angles.p ~= 0 or angles.y ~= 0 or angles.r ~= 0
	local normals = rotated and rotatedNormals( session, record, brushes, angles )
	local pos = session.move.origin - origin
	for i, brush in ipairs( brushes ) do
		local inside = true
		for j, side in ipairs( brush.sides ) do
			local plane = side.plane
			local n = rotated and normals[i][j] or plane.normal
			-- Expand each brush plane by the world-aligned player hull, including
			-- BSP bevel planes. Keep the brush origin/rotation in map coordinates.
			local offset = n.x * ( n.x < 0 and maxs.x or mins.x )
				+ n.y * ( n.y < 0 and maxs.y or mins.y )
				+ n.z * ( n.z < 0 and maxs.z or mins.z )
			if n.x * pos.x + n.y * pos.y + n.z * pos.z + offset > plane.dist then
				inside = false
				break
			end
		end
		if inside then return true end
	end
	return false
end

IO.Register( "trigger_teleport", {} )

-- Most Hammer teleport brushes never move. Index their immutable BSP bounds
-- once per map, so a movement command only tests triggers near the player.
-- Explicitly writable trigger states are checked separately. Read-only queries
-- leave the immutable spatial index usable.
local TELEPORT_CELL = 512
local TELEPORT_MAX_CELLS = 64
local function teleportIndex( world )
	local index = world.teleportIndex
	if index and index.ordered then return index end
	index = { cells = {}, broad = {}, ordered = true }
	for order, record in ipairs( IO.OfClass( world, "trigger_teleport" ) ) do
		record.order = record.order or order
		local lo, hi = IO.Bounds( record )
		if lo and hi then
			local x1, x2 = math.floor( lo.x / TELEPORT_CELL ), math.floor( hi.x / TELEPORT_CELL )
			local y1, y2 = math.floor( lo.y / TELEPORT_CELL ), math.floor( hi.y / TELEPORT_CELL )
			if ( x2 - x1 + 1 ) * ( y2 - y1 + 1 ) <= TELEPORT_MAX_CELLS then
				for x = x1, x2 do
					local column = index.cells[x]
					if not column then column = {} index.cells[x] = column end
					for y = y1, y2 do
						local cell = column[y]
						if not cell then cell = {} column[y] = cell end
						cell[#cell + 1] = record
					end
				end
			else
				index.broad[#index.broad + 1] = record
			end
		end
	end
	world.teleportIndex = index
	return index
end

local function triggerOrder( a, b ) return a.order < b.order end

local function addCandidate( candidates, seen, query, record )
	if seen[record] == query then return end
	seen[record] = query
	candidates[#candidates + 1] = record
end

local function teleportCandidates( index, pos, mins, maxs, state )
	local candidates = state.teleportCandidates or {}
	for i = #candidates, 1, -1 do candidates[i] = nil end
	local seen = state.teleportSeen or {}
	local query = ( state.teleportQuery or 0 ) + 1
	state.teleportCandidates, state.teleportSeen, state.teleportQuery = candidates, seen, query
	local x1, x2 = math.floor( ( pos.x + mins.x ) / TELEPORT_CELL ), math.floor( ( pos.x + maxs.x ) / TELEPORT_CELL )
	local y1, y2 = math.floor( ( pos.y + mins.y ) / TELEPORT_CELL ), math.floor( ( pos.y + maxs.y ) / TELEPORT_CELL )
	for x = x1, x2 do
		local column = index.cells[x]
		if column then
			for y = y1, y2 do
				for _, record in ipairs( column[y] or EMPTY ) do addCandidate( candidates, seen, query, record ) end
			end
		end
	end
	for _, record in ipairs( index.broad ) do addCandidate( candidates, seen, query, record ) end
	for record in pairs( state.teleportMutable or EMPTY ) do addCandidate( candidates, seen, query, record ) end
	for record in pairs( state.touching ) do
		if record.class == "trigger_teleport" then addCandidate( candidates, seen, query, record ) end
	end
	table.sort( candidates, triggerOrder )
	return candidates
end

local function destination( state, source )
	local name = IO.Value( source.entity, "target" )
	if type( name ) ~= "string" then return end
	for _, target in ipairs( state.world.names[name:lower()] or EMPTY ) do
		if target.class == "info_teleport_destination" or target.class == "info_target" then return target end
	end
end

local function teleport( session, state, source )
	local target = destination( state, source )
	if not target then return end
	local move = session.move
	local before = move.angles.y
	move.origin = IO.Position( state, target ) + Vector( 0, 0, 2 )
	move.velocity = Vector()
	local angles = IO.Rotation( state, target )
	move.angles = Angle( angles.p, angles.y, 0 )
	move.moveAngles = move.angles
	session.yawOffset = session.yawOffset + angles.y - before
	session.onground = false
	IO.Fire( state, source, "OnStartTouch", state.activator, source )
	IO.Fire( state, source, "OnTrigger", state.activator, source )
end

IO.OnStep( "Teleports", function( session, state )
	local mins, maxs = IO.PlayerHull( session )
	local index = teleportIndex( state.world )
	local candidates = teleportCandidates( index, session.move.origin, mins, maxs, state )
	local nextIndex, previousOrder = 1, -1
	while nextIndex <= #candidates do
		local record = candidates[nextIndex]
		nextIndex = nextIndex + 1
		if record.order > previousOrder then
			previousOrder = record.order
			local wasTouching = state.touching[record]
			local touching = IO.Enabled( state, record ) and IO.TeleportOverlaps( session, record, mins, maxs )
			if touching and not wasTouching then
				teleport( session, state, record )
				-- Requery after a teleport, but process only later entities this tick.
				-- This retains BSP entity order without scanning every distant trigger.
				candidates = teleportCandidates( index, session.move.origin, mins, maxs, state )
				nextIndex = 1
			end
			if not touching and wasTouching then IO.Fire( state, record, "OnEndTouch", state.activator, record ) end
			state.touching[record] = touching or nil
		end
	end
end )
