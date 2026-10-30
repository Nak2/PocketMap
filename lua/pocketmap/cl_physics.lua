PocketMap.Physics = {}
local Physics = PocketMap.Physics

local EPSILON = 0.03125
local PARALLEL = 0.0000001
local MIN_AXIS_LENGTH = 0.000001
local AXIS_SIGN_TOLERANCE = 0.0001
local CELL_SIZE = 512
local MAX_CELLS_PER_SOURCE = 512
local PREPARE_SECONDS = 0.006
local SOLID_VPHYSICS = 6
local MIN_PIECE_VERTICES = 4
local PROPS_PER_YIELD = 40
local EDGE_KEY_STRIDE = 100000

local floor, sqrt, abs, min, max, huge = math.floor, math.sqrt, math.abs, math.min, math.max, math.huge

local query = {}

local function axisKey( x, y, z )
	return ( floor( x * 1000 + 0.5 ) + 1000 ) + 2001 * ( ( floor( y * 1000 + 0.5 ) + 1000 ) + 2001 * ( floor( z * 1000 + 0.5 ) + 1000 ) )
end

local function pointsOppositeToCanonical( x, y, z )
	if x < -AXIS_SIGN_TOLERANCE then return true end
	if abs( x ) > AXIS_SIGN_TOLERANCE then return false end
	if y < -AXIS_SIGN_TOLERANCE then return true end
	return abs( y ) <= AXIS_SIGN_TOLERANCE and z < 0
end

local function projectionRange( vertices, x, y, z )
	local vx, vy, vz = vertices.x, vertices.y, vertices.z
	local low, high = huge, -huge
	for i = 1, vertices.count do
		local d = x * vx[i] + y * vy[i] + z * vz[i]
		if d < low then low = d end
		if d > high then high = d end
	end
	return low, high
end

local function addAxis( list, x, y, z )
	local length = sqrt( x * x + y * y + z * z )
	if length < MIN_AXIS_LENGTH then return end

	x, y, z = x / length, y / length, z / length
	if pointsOppositeToCanonical( x, y, z ) then x, y, z = -x, -y, -z end

	local key = axisKey( x, y, z )
	if list.seen[key] then return end
	list.seen[key] = true

	local low, high = projectionRange( list.vertices, x, y, z )
	local axes, size = list.axes, list.size
	axes[size + 1], axes[size + 2], axes[size + 3], axes[size + 4], axes[size + 5] = x, y, z, low, high
	list.size = size + 5
end

local function addFaceAxis( list, a, b, c )
	local v = list.vertices
	local ux, uy, uz = v.x[b] - v.x[a], v.y[b] - v.y[a], v.z[b] - v.z[a]
	local wx, wy, wz = v.x[c] - v.x[a], v.y[c] - v.y[a], v.z[c] - v.z[a]
	addAxis( list, uy * wz - uz * wy, uz * wx - ux * wz, ux * wy - uy * wx )
end

local function addEdgeAxes( list, seenEdges, a, b )
	if a > b then a, b = b, a end

	local key = a * EDGE_KEY_STRIDE + b
	if seenEdges[key] then return end
	seenEdges[key] = true

	local v = list.vertices
	local ex, ey, ez = v.x[b] - v.x[a], v.y[b] - v.y[a], v.z[b] - v.z[a]
	addAxis( list, 0, ez, -ey )
	addAxis( list, -ez, 0, ex )
	addAxis( list, ey, -ex, 0 )
end

local function collectVertices( ledge, points, place )
	local vertices, indexOf = { x = {}, y = {}, z = {}, count = 0 }, {}
	for _, triangle in ipairs( ledge.tris ) do
		for corner = 1, 3 do
			local pointIndex = triangle[corner]
			if not indexOf[pointIndex] then
				local count = vertices.count + 1
				vertices.count, indexOf[pointIndex] = count, count

				local point = points[pointIndex]
				if place then
					vertices.x[count], vertices.y[count], vertices.z[count] = place( point )
				else
					vertices.x[count], vertices.y[count], vertices.z[count] = point.x, point.y, point.z
				end
			end
		end
	end
	return vertices, indexOf
end

local function buildPiece( ledge, points, place )
	local vertices, indexOf = collectVertices( ledge, points, place )
	if vertices.count < MIN_PIECE_VERTICES then return end

	local list = { vertices = vertices, axes = {}, size = 0, seen = {} }
	addAxis( list, 1, 0, 0 )
	addAxis( list, 0, 1, 0 )
	addAxis( list, 0, 0, 1 )

	local seenEdges = {}
	for _, triangle in ipairs( ledge.tris ) do
		local a, b, c = indexOf[triangle[1]], indexOf[triangle[2]], indexOf[triangle[3]]
		addFaceAxis( list, a, b, c )
		addEdgeAxes( list, seenEdges, a, b )
		addEdgeAxes( list, seenEdges, b, c )
		addEdgeAxes( list, seenEdges, c, a )
	end

	local axes = list.axes
	return {
		axes = axes, count = list.size,
		minX = axes[4], maxX = axes[5], minY = axes[9], maxY = axes[10], minZ = axes[14], maxZ = axes[15],
	}
end

local function buildPieces( source )
	local pieces, points = {}, source.mesh.points
	for _, ledge in ipairs( source.mesh.ledges ) do
		local piece = buildPiece( ledge, points, source.place )
		if piece then pieces[#pieces + 1] = piece end
	end
	source.pieces = pieces
	return pieces
end

local function sweepPiece( piece, source )
	local out = query.out
	local sx, sy, sz, dx, dy, dz, ex, ey, ez = query.sx, query.sy, query.sz, query.dx, query.dy, query.dz, query.ex, query.ey, query.ez
	local axes = piece.axes
	local enter, leave = -huge, huge
	local hitX, hitY, hitZ
	local startInside, endInside = true, true

	for i = 1, piece.count, 5 do
		local ax, ay, az, lo, hi = axes[i], axes[i + 1], axes[i + 2], axes[i + 3], axes[i + 4]
		local radius = ex * abs( ax ) + ey * abs( ay ) + ez * abs( az )
		local origin = ax * sx + ay * sy + az * sz
		local delta = ax * dx + ay * dy + az * dz
		local low, high = lo - radius, hi + radius

		-- Beside the piece and moving away or along it (a surf ramp is tangent) is no hit
		if origin > high then
			if delta >= -PARALLEL then return end
			startInside = false
		elseif origin < low then
			if delta <= PARALLEL then return end
			startInside = false
		end

		local finish = origin + delta
		if finish > high or finish < low then endInside = false end

		if abs( delta ) > PARALLEL then
			local first, last, sign
			if delta > 0 then
				first, last, sign = ( low - EPSILON - origin ) / delta, ( high + EPSILON - origin ) / delta, -1
			else
				first, last, sign = ( high + EPSILON - origin ) / delta, ( low - EPSILON - origin ) / delta, 1
			end

			if first > enter then enter, hitX, hitY, hitZ = first, ax * sign, ay * sign, az * sign end
			if last < leave then leave = last end
			if enter > leave or enter >= out.Fraction then return end
		end
	end

	if startInside then
		out.StartSolid = true
		if endInside then out.AllSolid, out.Fraction = true, 0 end
		return
	end

	if enter < leave and enter < out.Fraction and hitX then
		out.Fraction = max( 0, enter )
		out.HitNormal = { x = hitX, y = hitY, z = hitZ }
		out.Contents, out.Texinfo, out.SurfaceName = source.contents, nil, source.surfaceprop
	end
end

local function boundsOverlap( a, b )
	return a.maxX >= b.minX and a.minX <= b.maxX and a.maxY >= b.minY and a.minY <= b.maxY and a.maxZ >= b.minZ and a.minZ <= b.maxZ
end

local function sweepSource( source )
	if source.stamp == query.stamp then return end
	source.stamp = query.stamp

	if bit.band( source.contents, query.mask ) == 0 or not boundsOverlap( source, query ) then return end

	for _, piece in ipairs( source.pieces or buildPieces( source ) ) do
		if boundsOverlap( piece, query ) then
			sweepPiece( piece, source )
			if query.out.AllSolid then return end
		end
	end
end

local function cellKey( ix, iy, iz )
	return ( ix + 512 ) + 1024 * ( ( iy + 512 ) + 1024 * ( iz + 512 ) )
end

local function cellRange( source )
	return floor( source.minX / CELL_SIZE ), floor( source.minY / CELL_SIZE ), floor( source.minZ / CELL_SIZE ),
		floor( source.maxX / CELL_SIZE ), floor( source.maxY / CELL_SIZE ), floor( source.maxZ / CELL_SIZE )
end

local function addToCell( grid, key, source )
	local list = grid[key]
	if not list then
		list = {}
		grid[key] = list
	end
	list[#list + 1] = source
end

local function addSource( set, source )
	local x0, y0, z0, x1, y1, z1 = cellRange( source )
	if ( x1 - x0 + 1 ) * ( y1 - y0 + 1 ) * ( z1 - z0 + 1 ) > MAX_CELLS_PER_SOURCE then
		set.big[#set.big + 1] = source
		return
	end

	for ix = x0, x1 do
		for iy = y0, y1 do
			for iz = z0, z1 do addToCell( set.grid, cellKey( ix, iy, iz ), source ) end
		end
	end
end

local function propPlacement( prop )
	local scale, angles, origin = prop.UniformScale or 1, prop.Angles, prop.Origin
	local forward, right, up = angles:Forward(), -angles:Right(), angles:Up()

	return function( p )
		local x, y, z = p.x * scale, p.y * scale, p.z * scale
		return origin.x + x * forward.x + y * right.x + z * up.x,
			origin.y + x * forward.y + y * right.y + z * up.y,
			origin.z + x * forward.z + y * right.z + z * up.z
	end
end

local function placedBounds( place, mesh )
	local lo, hi = NikNaks.Physics.MeshBounds( mesh )
	local minX, minY, minZ, maxX, maxY, maxZ = huge, huge, huge, -huge, -huge, -huge
	local corner = {}

	for cx = 0, 1 do
		for cy = 0, 1 do
			for cz = 0, 1 do
				corner.x, corner.y, corner.z = cx == 0 and lo.x or hi.x, cy == 0 and lo.y or hi.y, cz == 0 and lo.z or hi.z
				local x, y, z = place( corner )
				minX, minY, minZ, maxX, maxY, maxZ = min( minX, x ), min( minY, y ), min( minZ, z ), max( maxX, x ), max( maxY, y ), max( maxZ, z )
			end
		end
	end
	return minX, minY, minZ, maxX, maxY, maxZ
end

local function addPropMeshes( set, prop, meshes )
	local place = propPlacement( prop )
	for _, mesh in ipairs( meshes ) do
		local minX, minY, minZ, maxX, maxY, maxZ = placedBounds( place, mesh )
		addSource( set, {
			mesh = mesh, place = place, contents = CONTENTS_SOLID, surfaceprop = mesh.surfaceprop,
			minX = minX, minY = minY, minZ = minZ, maxX = maxX, maxY = maxY, maxZ = maxZ,
		} )
	end
	set.props = set.props + 1
end

local function loadModelMeshes( models, model, yield )
	local meshes = models[model]
	if meshes ~= nil then return meshes end

	local ok, loaded = pcall( NikNaks.Physics.Load, model )
	meshes = ok and loaded or false
	models[model] = meshes
	yield()
	return meshes
end

local function addProps( set, bsp, yield )
	local models, visited = {}, 0
	for _, prop in pairs( bsp:GetStaticProps() ) do
		if prop.Solid == SOLID_VPHYSICS and prop.PropType then
			local meshes = loadModelMeshes( models, prop.PropType, yield )
			if meshes then addPropMeshes( set, prop, meshes ) end
		end

		visited = visited + 1
		if visited % PROPS_PER_YIELD == 0 then yield() end
	end
end

function Physics.Build( bsp, yield )
	local set = { grid = {}, big = {}, stamp = 0, props = 0 }
	local started = SysTime()

	addProps( set, bsp, yield )
	print( ( "[PocketMap] %s: collision of %d static props, read in %.1f s" ):format( bsp:GetMapName(), set.props, SysTime() - started ) )
	return set
end

local function resumeUntil( co, deadline )
	repeat
		local ok, err = coroutine.resume( co )
		if not ok then return false, err end
	until coroutine.status( co ) == "dead" or SysTime() >= deadline
	return true
end

function Physics.Prepare( mini, done )
	if mini.physics ~= nil then done() return end
	if mini.physicsPreparing then return end
	mini.physicsPreparing = true

	local co = coroutine.create( function() mini.physics = Physics.Build( mini.bsp, coroutine.yield ) end )
	local hookName = "PocketMap_PhysicsPrepare" .. tostring( mini )

	local function finish()
		hook.Remove( "Think", hookName )
		mini.physicsPreparing = nil
		done()
	end

	hook.Add( "Think", hookName, function()
		if mini.state == "removed" then return hook.Remove( "Think", hookName ) end

		local ok, err = resumeUntil( co, SysTime() + PREPARE_SECONDS )
		if not ok then
			mini.physics = false
			ErrorNoHalt( "[PocketMap] The collision of the map could not be read: " .. tostring( err ) .. "\n" )
			return finish()
		end

		if coroutine.status( co ) == "dead" then finish() end
	end )
end

local function setQuery( set, start, finish, mins, maxs, mask, out )
	local ex, ey, ez = ( maxs.x - mins.x ) / 2, ( maxs.y - mins.y ) / 2, ( maxs.z - mins.z ) / 2
	local dx, dy, dz = finish.x - start.x, finish.y - start.y, finish.z - start.z

	query.out, query.mask = out, mask
	query.ex, query.ey, query.ez, query.dx, query.dy, query.dz = ex, ey, ez, dx, dy, dz
	query.sx, query.sy, query.sz = start.x + mins.x + ex, start.y + mins.y + ey, start.z + mins.z + ez

	set.stamp = set.stamp + 1
	query.stamp = set.stamp
end

local function setQueryBounds( lo, hi )
	query.minX, query.minY, query.minZ = lo.x - EPSILON, lo.y - EPSILON, lo.z - EPSILON
	query.maxX, query.maxY, query.maxZ = hi.x + EPSILON, hi.y + EPSILON, hi.z + EPSILON
end

function Physics.Trace( set, start, finish, mins, maxs, mask, lo, hi, out )
	if out.AllSolid then return end

	setQuery( set, start, finish, mins, maxs, mask or MASK_PLAYERSOLID, out )
	setQueryBounds( lo, hi )

	for _, source in ipairs( set.big ) do sweepSource( source ) end

	local x0, y0, z0, x1, y1, z1 = cellRange( query )
	for ix = x0, x1 do
		for iy = y0, y1 do
			for iz = z0, z1 do
				local list = set.grid[cellKey( ix, iy, iz )]
				if list then
					for _, source in ipairs( list ) do sweepSource( source ) end
				end
			end
		end
	end
end
