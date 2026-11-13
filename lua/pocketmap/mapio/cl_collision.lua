-- Bounds and movement traces for session-owned brush and prop poses.
local IO = PocketMap.MapIO

-- Hull / bmodel overlap is shared by triggers, buttons and movers.
-- Prop doors have their own model-space bounds. The brush fallback was centered
-- on the wrong Z and much thicker than common door models, leaving invisible
-- collision in the doorway even when the visible door was correctly placed.
local doorModelBounds = IO.doorModelBounds or {}
IO.doorModelBounds = doorModelBounds

local function solidModelBounds( record )
	if record.class ~= "prop_door_rotating" then
		return record.model and record.model.mins, record.model and record.model.maxs
	end
	local path = IO.Value( record.entity, "model" )
	if type( path ) ~= "string" or not path:lower():find( "%.mdl$" ) then
		return Vector( -24, -24, -8 ), Vector( 24, 24, 80 )
	end
	local key = path:lower()
	local bounds = doorModelBounds[key]
	if bounds == nil then
		bounds = false
		local model = ClientsideModel( path, RENDERGROUP_OTHER )
		if IsValid( model ) then
			model:SetNoDraw( true )
			local mins, maxs = model:GetModelBounds()
			if mins and maxs and ( maxs - mins ):LengthSqr() > 1 then
				bounds = { mins = mins, maxs = maxs }
			end
			model:Remove()
		end
		doorModelBounds[key] = bounds
	end
	if bounds then return bounds.mins, bounds.maxs end
	return Vector( -24, -24, -8 ), Vector( 24, 24, 80 )
end

function IO.Bounds( record, state )
	local mins, maxs = solidModelBounds( record )
	if not mins then return nil end
	local offset = IO.Position( state, record )
	local angles = IO.Rotation( state, record )
	if angles.p == 0 and angles.y == 0 and angles.r == 0 then return mins + offset, maxs + offset end
	-- Rotated brush models use their axis-aligned envelope for fast player traces.
	local lo, hi = Vector( math.huge, math.huge, math.huge ), Vector( -math.huge, -math.huge, -math.huge )
	for x = 0, 1 do for y = 0, 1 do for z = 0, 1 do
		local corner = Vector( x == 0 and mins.x or maxs.x, y == 0 and mins.y or maxs.y, z == 0 and mins.z or maxs.z )
		local rotated = LocalToWorld( corner, Angle(), offset, angles )
		lo.x, lo.y, lo.z = math.min( lo.x, rotated.x ), math.min( lo.y, rotated.y ), math.min( lo.z, rotated.z )
		hi.x, hi.y, hi.z = math.max( hi.x, rotated.x ), math.max( hi.y, rotated.y ), math.max( hi.z, rotated.z )
	end end end
	return lo, hi
end

function IO.Overlaps( session, record, mins, maxs )
	-- Triggers are normally stationary. Keep their transformed envelope per
	-- session instead of allocating vectors (or rotating eight corners) on
	-- every movement tick. Scalar pose keys also detect in-place mutations.
	local state = session.io
	local pose = state and state.records[record] or record
	local origin, angles = pose.origin, pose.angles
	if not origin or not angles then return false end
	local cache = state and state.overlapBounds
	local entry = cache and cache[record]
	local x, y, z, p, yaw, r = origin.x, origin.y, origin.z, angles.p, angles.y, angles.r
	if not entry or entry.model ~= record.model or entry.x ~= x or entry.y ~= y or entry.z ~= z
		or entry.p ~= p or entry.yaw ~= yaw or entry.r ~= r then
		local lo, hi = IO.Bounds( record, state )
		entry = { model = record.model, x = x, y = y, z = z, p = p, yaw = yaw, r = r, lo = lo, hi = hi }
		if state then
			state.overlapBounds = cache or {}
			state.overlapBounds[record] = entry
		end
	end
	local lo, hi = entry.lo, entry.hi
	if not lo then return false end
	local pos = session.move.origin
	if not mins then mins, maxs = IO.PlayerHull( session ) end
	return pos.x + maxs.x >= lo.x and pos.x + mins.x <= hi.x
		and pos.y + maxs.y >= lo.y and pos.y + mins.y <= hi.y
		and pos.z + maxs.z >= lo.z and pos.z + mins.z <= hi.z
end

-- Index brush bounds once per walking session, then refresh moved brushes as
-- commands advance. Every ground, wall and stair probe shares this index.
local TRACE_CELL_SIZE = 256
local TRACE_AXES = { "x", "y", "z" }
local TRACE_WORLD_AXES = { Vector( 1, 0, 0 ), Vector( 0, 1, 0 ), Vector( 0, 0, 1 ) }

-- An OBB narrow phase keeps the player hull aligned with the map while the
-- prop door swings. Its AABB is still used for cheap spatial lookup.
local function doorTraceShape( record, state )
	if record.class ~= "prop_door_rotating" then return end
	local mins, maxs = solidModelBounds( record )
	local origin, angles = IO.Position( state, record ), IO.Rotation( state, record )
	return {
		center = LocalToWorld( ( mins + maxs ) * 0.5, Angle(), origin, angles ),
		half = ( maxs - mins ) * 0.5,
		axes = { angles:Forward(), -angles:Right(), angles:Up() },
	}
end

local function brushTraceShapes( record, state )
	if not record.model then return end
	local source = record.model:GetBrushes()
	if #source == 0 then return end
	local origin, angles = IO.Position( state, record ), IO.Rotation( state, record )
	local rotated = angles.p ~= 0 or angles.y ~= 0 or angles.r ~= 0
	local result = {}
	for _, brush in ipairs( source ) do
		local sides = {}
		for i, side in ipairs( brush.sides ) do
			local normal = side.plane.normal
			if rotated then normal = LocalToWorld( normal, angle_zero, vector_origin, angles ) end
			sides[i] = { normal = normal, dist = side.plane.dist + normal:Dot( origin ), texinfo = side.texinfo }
		end
		result[#result + 1] = { sides = sides, contents = brush.contents }
	end
	return result
end

local function traceCells( lo, hi )
	return math.floor( lo.x / TRACE_CELL_SIZE ), math.floor( hi.x / TRACE_CELL_SIZE ),
		math.floor( lo.y / TRACE_CELL_SIZE ), math.floor( hi.y / TRACE_CELL_SIZE )
end

local function removeTraceEntry( grid, entry )
	for x = entry.x1, entry.x2 do
		local column = grid.cells[x]
		for y = entry.y1, entry.y2 do
			local cell = column[y]
			for i = #cell, 1, -1 do
				if cell[i] == entry then table.remove( cell, i ) break end
			end
			if #cell == 0 then column[y] = nil end
		end
		if not next( column ) then grid.cells[x] = nil end
	end
end

local function setTraceBounds( grid, entry, lo, hi )
	local x1, x2, y1, y2 = traceCells( lo, hi )
	if entry.x1 and ( entry.x1 ~= x1 or entry.x2 ~= x2 or entry.y1 ~= y1 or entry.y2 ~= y2 ) then
		removeTraceEntry( grid, entry )
	end
	if entry.x1 ~= x1 or entry.x2 ~= x2 or entry.y1 ~= y1 or entry.y2 ~= y2 then
		for x = x1, x2 do
			local column = grid.cells[x]
			if not column then column = {} grid.cells[x] = column end
			for y = y1, y2 do
				local cell = column[y]
				if not cell then cell = {} column[y] = cell end
				cell[#cell + 1] = entry
			end
		end
	end
	entry.x1, entry.x2, entry.y1, entry.y2 = x1, x2, y1, y2
	entry.lo, entry.hi = lo, hi
end

local function rememberTracePose( entry, origin, angles )
	entry.px, entry.py, entry.pz = origin.x, origin.y, origin.z
	entry.pitch, entry.yaw, entry.roll = angles.p, angles.y, angles.r
end

local function traceGrid( session, state )
	local grid = session.mapIOTraceGrid
	if not grid or grid.world ~= state.world or not grid.byRecord or not grid.hasBrushShapes then
		grid = { world = state.world, cells = {}, entries = {}, byRecord = {}, hasBrushShapes = true }
		for _, record in ipairs( state.world.solids ) do
			local handler = IO.classes[record.class]
			if handler and handler.solid and ( handler.solid == true or handler.solid( state, record ) ) then
				local current = state.records[record]
				local origin = current and current.origin or record.origin
				local angles = current and current.angles or record.angles
				local entry = { record = record }
				rememberTracePose( entry, origin, angles )
				local lo, hi = IO.Bounds( record, state )
				if lo then
					setTraceBounds( grid, entry, lo, hi )
					entry.doorShape = doorTraceShape( record, state )
					entry.brushShapes = not entry.doorShape and brushTraceShapes( record, state ) or nil
					grid.entries[#grid.entries + 1] = entry
					grid.byRecord[record] = entry
				end
			end
		end
		session.mapIOTraceGrid = grid
		state.traceDirty = nil -- initial bounds already include every current pose
	end
	local dirty = state.traceDirty
	if dirty then
		for record in pairs( dirty ) do
			local entry = grid.byRecord[record]
			if entry then
				local current = state.records[record]
				local origin = current and current.origin or record.origin
				local angles = current and current.angles or record.angles
				if origin.x ~= entry.px or origin.y ~= entry.py or origin.z ~= entry.pz
					or angles.p ~= entry.pitch or angles.y ~= entry.yaw or angles.r ~= entry.roll then
					rememberTracePose( entry, origin, angles )
					local lo, hi = IO.Bounds( record, state )
					if lo then
						setTraceBounds( grid, entry, lo, hi )
						entry.doorShape = doorTraceShape( record, state )
						entry.brushShapes = not entry.doorShape and brushTraceShapes( record, state ) or nil
					end
				end
			end
		end
		state.traceDirty = nil
	end
	return grid
end

local function traceSolid( record, lo, hi, start, finish, mins, maxs, out )
	local enter, leave, normalAxis, normalSign = 0, 1, nil, nil
	local inside = true
	for _, axis in ipairs( TRACE_AXES ) do
		local low, high = lo[axis] - maxs[axis], hi[axis] - mins[axis]
		local a, b = start[axis], finish[axis]
		if a < low or a > high then inside = false end
		if math.abs( b - a ) < 0.000001 then
			if a < low or a > high then return end
		else
			local t1, t2 = ( low - a ) / ( b - a ), ( high - a ) / ( b - a )
			local sign = -1
			if t1 > t2 then t1, t2, sign = t2, t1, 1 end
			if t1 > enter then
				enter = t1
				normalAxis, normalSign = axis, sign
			end
			leave = math.min( leave, t2 )
		end
	end
	if inside then
		out.StartSolid = true
		if finish.x >= lo.x - maxs.x and finish.x <= hi.x - mins.x
			and finish.y >= lo.y - maxs.y and finish.y <= hi.y - mins.y
			and finish.z >= lo.z - maxs.z and finish.z <= hi.z - mins.z then
			out.AllSolid, out.Fraction, out.Entity = true, 0, record
		end
	elseif enter <= leave and enter < out.Fraction and normalAxis then
		out.Fraction = math.max( 0, enter - 0.0001 )
		out.HitNormal = Vector( normalAxis == "x" and normalSign or 0,
			normalAxis == "y" and normalSign or 0, normalAxis == "z" and normalSign or 0 )
		out.Entity = record
		out.Contents = CONTENTS_SOLID or 1
	end
end

-- Swept SAT: exact overlap times for the moving, axis-aligned player box and
-- the rotated door box, including corner contacts. At most 15 separating axes.
local function traceDoor( record, shape, start, finish, mins, maxs, out )
	-- Movement traces pass xyz tables; SAT axes still use actual Vectors.
	local center = Vector( start.x + ( mins.x + maxs.x ) * 0.5,
		start.y + ( mins.y + maxs.y ) * 0.5, start.z + ( mins.z + maxs.z ) * 0.5 )
	local delta = center - shape.center
	local motion = Vector( finish.x - start.x, finish.y - start.y, finish.z - start.z )
	local half = Vector( ( maxs.x - mins.x ) * 0.5, ( maxs.y - mins.y ) * 0.5,
		( maxs.z - mins.z ) * 0.5 )
	local doorHalf, doorAxes = shape.half, shape.axes
	local enter, leave = -math.huge, math.huge
	local normal, normalSign
	local startsInside, endsInside = true, true
	local function axisOverlap( axis )
		local lenSqr = axis:LengthSqr()
		if lenSqr < 0.00000001 then return true end
		if math.abs( lenSqr - 1 ) > 0.000001 then axis = axis / math.sqrt( lenSqr ) end
		local radius = math.abs( axis.x ) * half.x + math.abs( axis.y ) * half.y + math.abs( axis.z ) * half.z
			+ math.abs( axis:Dot( doorAxes[1] ) ) * doorHalf.x
			+ math.abs( axis:Dot( doorAxes[2] ) ) * doorHalf.y
			+ math.abs( axis:Dot( doorAxes[3] ) ) * doorHalf.z
		local distance = delta:Dot( axis )
		local speed = motion:Dot( axis )
		if math.abs( distance ) > radius then startsInside = false end
		if math.abs( distance + speed ) > radius then endsInside = false end
		if math.abs( speed ) < 0.000001 then return math.abs( distance ) <= radius end
		local first, last = ( -radius - distance ) / speed, ( radius - distance ) / speed
		if first > last then first, last = last, first end
		if first > enter then enter, normal, normalSign = first, axis, speed > 0 and -1 or 1 end
		leave = math.min( leave, last )
		return enter <= leave
	end
	for i = 1, 3 do
		if not axisOverlap( TRACE_WORLD_AXES[i] ) or not axisOverlap( doorAxes[i] ) then return end
	end
	for i = 1, 3 do
		for j = 1, 3 do
			if not axisOverlap( TRACE_WORLD_AXES[i]:Cross( doorAxes[j] ) ) then return end
		end
	end
	if startsInside then
		out.StartSolid = true
		if endsInside then
			out.AllSolid, out.Fraction, out.Entity = true, 0, record
		end
	elseif enter >= 0 and enter <= leave and enter < out.Fraction and normal then
		out.Fraction = math.max( 0, enter - 0.0001 )
		out.HitNormal = normal * normalSign
		out.Entity = record
		out.Contents = CONTENTS_SOLID or 1
	end
end

-- Clip a swept hull against each convex brush. The AABB grid is only the broad phase;
-- gaps in a multi-brush model and empty corners around rotating brushes remain traversable.
local function traceBrushes( record, brushes, start, finish, mins, maxs, out )
	for _, brush in ipairs( brushes ) do
		local enter, leave, normal, texinfo = -1, 1
		local outside, endOutside, rejected = false, false, false
		for _, side in ipairs( brush.sides ) do
			local n = side.normal
			local offset = n.x * ( n.x < 0 and maxs.x or mins.x )
				+ n.y * ( n.y < 0 and maxs.y or mins.y ) + n.z * ( n.z < 0 and maxs.z or mins.z )
			local first = n.x * start.x + n.y * start.y + n.z * start.z + offset - side.dist
			local last = n.x * finish.x + n.y * finish.y + n.z * finish.z + offset - side.dist
			if first > 0 then outside = true end
			if last > 0 then endOutside = true end
			if first > 0 and last >= first - 0.0000001 then rejected = true break end
			if first > 0 or last > 0 then
				if first > last then
					local fraction = ( first - 0.03125 ) / ( first - last )
					if fraction > enter then enter, normal, texinfo = fraction, n, side.texinfo end
				else
					leave = math.min( leave, ( first + 0.03125 ) / ( first - last ) )
				end
			end
		end
		if not rejected then
			if not outside then
				out.StartSolid = true
				if not endOutside then out.AllSolid, out.Fraction, out.Entity = true, 0, record end
			elseif enter < leave and enter > -1 and enter < out.Fraction then
				out.Fraction, out.HitNormal, out.Entity = math.max( 0, enter ), normal, record
				out.Contents, out.Texinfo = brush.contents, texinfo
			end
		end
	end
end

-- The same local BSP coordinates as Session:TraceHull, without spawning actual entities.
function IO.Trace( session, start, finish, mins, maxs, out )
	if PocketMap.Settings and not PocketMap.Settings.Enabled( session.mini, "dynamic_collision" ) then return out end
	local state = session.io
	if not state or not state.world or not state.world.solids then return end
	local grid = traceGrid( session, state )
	local loX, hiX = math.min( start.x, finish.x ) + mins.x, math.max( start.x, finish.x ) + maxs.x
	local loY, hiY = math.min( start.y, finish.y ) + mins.y, math.max( start.y, finish.y ) + maxs.y
	local x1, x2 = math.floor( loX / TRACE_CELL_SIZE ), math.floor( hiX / TRACE_CELL_SIZE )
	local y1, y2 = math.floor( loY / TRACE_CELL_SIZE ), math.floor( hiY / TRACE_CELL_SIZE )
	local z1 = math.min( start.z, finish.z ) + mins.z
	local z2 = math.max( start.z, finish.z ) + maxs.z
	-- One monotonically increasing query marker avoids allocating a seen table
	-- for every ground/step/wall probe spanning multiple hash cells.
	local query = ( grid.query or 0 ) + 1
	grid.query = query
	for x = x1, x2 do
		local column = grid.cells[x]
		if column then
			for y = y1, y2 do
				local cell = column[y]
				if cell then
					for _, entry in ipairs( cell ) do
						if entry.query ~= query and entry.record ~= session.mapIOIgnore then
							entry.query = query
							if entry.lo.x <= hiX and entry.hi.x >= loX
								and entry.lo.y <= hiY and entry.hi.y >= loY
								and entry.lo.z <= z2 and entry.hi.z >= z1 then
								if entry.doorShape then
									traceDoor( entry.record, entry.doorShape, start, finish, mins, maxs, out )
								elseif entry.brushShapes then
									traceBrushes( entry.record, entry.brushShapes, start, finish, mins, maxs, out )
								else
									traceSolid( entry.record, entry.lo, entry.hi, start, finish, mins, maxs, out )
								end
							end
						end
					end
				end
			end
		end
	end
end

local ZERO_VECTOR = Vector()
-- Use traces share the movement narrow phases, including rotated prop doors.
function IO.TraceEntity( state, record, start, finish, mins, maxs, out )
	local lo, hi = IO.Bounds( record, state )
	if not lo then return out end
	local shape = doorTraceShape( record, state )
	if shape then traceDoor( record, shape, start, finish, mins, maxs, out )
	else
		local brushes = brushTraceShapes( record, state )
		if brushes then traceBrushes( record, brushes, start, finish, mins, maxs, out )
		else traceSolid( record, lo, hi, start, finish, mins, maxs, out ) end
	end
	return out
end

-- Resolve a target from the rendered eye and reject intervening BSP, props and movers.
function IO.Use( session, state )
	if not session.move:KeyPressed( IN_USE ) then return end
	local eye = session.move.origin + PocketMap.Walk.EyeOffset( session )
	local finish = eye + session.move.angles:Forward() * 96
	local best = { Fraction = 1 }
	for _, record in ipairs( state.world.useTargets ) do
		local handlers = IO.classes[record.class]
		if handlers and handlers.use and IO.Enabled( state, record )
			and ( not handlers.canUse or handlers.canUse( state, record ) ) then
			IO.TraceEntity( state, record, eye, finish, ZERO_VECTOR, ZERO_VECTOR, best )
		end
	end
	if not best.Entity then return end
	local blocked = session:TraceHull( eye, finish, ZERO_VECTOR, ZERO_VECTOR, MASK_SOLID )
	if not blocked.StartSolid and ( blocked.Entity == best.Entity or best.Fraction <= blocked.Fraction + 0.0001 ) then
		IO.Input( state, best.Entity, "use", "", state.activator, best.Entity )
	end
end

-- Translate passengers with their ground mover, tracing the configured hull against other geometry.
function IO.Carry( session, record, delta )
	if session.noclip or not session.onground or session.groundRecord ~= record then return end
	local move = session.move
	local mins, maxs = IO.PlayerHull( session )
	session.mapIOIgnore = record
	local trace = session:TraceHull( move.origin, move.origin + delta, mins, maxs )
	session.mapIOIgnore = nil
	move.origin = move.origin + delta * trace.Fraction
end
