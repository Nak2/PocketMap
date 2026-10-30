-- Collision with the terrain and the static props, from the collision data the map was compiled with (the same data the engine uses):
-- the collision of every displacement (lump 28, bsp:GetPhysDisps) and the .phy file of every solid static prop (NikNaks.Physics.Load).
-- Both are VPHY solids: a number of convex pieces ("ledges"), each a closed polyhedron of triangles.
--
-- A box swept against a convex piece is a separating axis test (the same as cl_displacements.lua does for one triangle): the axes are
-- the normals of the faces, the three axes of the box, and the edges of the piece crossed with those. The piece is a range on each axis,
-- worked out once, so a trace costs a few dozen multiplications per piece. The pieces of a source (a displacement, a placed prop) are
-- built when a trace comes near it.
--
-- Pieces are found through a grid of cells. Building takes a moment (every .phy file is read), so it is done when somebody first walks in a map
-- (Physics.Prepare), spread over frames, and kept for that tiny map.

PocketMap.Physics = {}
local Physics = PocketMap.Physics

local EPSILON = 0.03125 -- how far from a surface a box stops, as the brushes and the engine do
local CELL = 512
local MAX_CELLS = 512 -- a source over more cells than this is tested every time instead
local PREPARE_SECONDS = 0.006 -- of a frame
local SOLID_VPHYSICS = 6 -- the collision of a static prop (0 none, 2 a box)
local PARALLEL = 0.0000001

local floor, sqrt, abs, min, max = math.floor, math.sqrt, math.abs, math.min, math.max

local cvTerrain = CreateClientConVar( "pocketmap_physics_terrain", "0", true, false,
	"Walk on the collision the map was compiled with for terrain, instead of the triangles of the displacements. Experimental.", 0, 1 )

-- Pieces ---------------------------------------------------------------------------------------------------------------

---Axes are kept flat: x, y, z of a unit vector, then where the piece begins and ends along it.
---@return table? piece
local function buildPiece( ledge, points, place )
	local vx, vy, vz, count, index = {}, {}, {}, 0, {}
	for _, triangle in ipairs( ledge.tris ) do
		for k = 1, 3 do
			local i = triangle[k]
			if not index[i] then
				count = count + 1
				index[i] = count
				local p = points[i]
				if place then vx[count], vy[count], vz[count] = place( p ) else vx[count], vy[count], vz[count] = p.x, p.y, p.z end
			end
		end
	end
	if count < 4 then return end

	local axes, axisCount, seen = {}, 0, {}
	local function addAxis( x, y, z )
		local length = sqrt( x * x + y * y + z * z )
		if length < 0.000001 then return end
		x, y, z = x / length, y / length, z / length

		-- An axis and its opposite are the same axis
		if x < -0.0001 or ( abs( x ) <= 0.0001 and ( y < -0.0001 or ( abs( y ) <= 0.0001 and z < 0 ) ) ) then x, y, z = -x, -y, -z end

		local key = ( floor( x * 1000 + 0.5 ) + 1000 ) + 2001 * ( ( floor( y * 1000 + 0.5 ) + 1000 ) + 2001 * ( floor( z * 1000 + 0.5 ) + 1000 ) )
		if seen[key] then return end
		seen[key] = true

		local low, high = math.huge, -math.huge
		for v = 1, count do
			local d = x * vx[v] + y * vy[v] + z * vz[v]
			if d < low then low = d end
			if d > high then high = d end
		end

		axes[axisCount + 1], axes[axisCount + 2], axes[axisCount + 3], axes[axisCount + 4], axes[axisCount + 5] = x, y, z, low, high
		axisCount = axisCount + 5
	end

	addAxis( 1, 0, 0 )
	addAxis( 0, 1, 0 )
	addAxis( 0, 0, 1 )

	local edges = {}
	for _, triangle in ipairs( ledge.tris ) do
		local a, b, c = index[triangle[1]], index[triangle[2]], index[triangle[3]]

		-- The normal of the face
		local ux, uy, uz = vx[b] - vx[a], vy[b] - vy[a], vz[b] - vz[a]
		local wx, wy, wz = vx[c] - vx[a], vy[c] - vy[a], vz[c] - vz[a]
		addAxis( uy * wz - uz * wy, uz * wx - ux * wz, ux * wy - uy * wx )

		-- The edges, once each, crossed with the axes of the box
		for _, edge in ipairs( { { a, b }, { b, c }, { c, a } } ) do
			local p, q = edge[1], edge[2]
			if p > q then p, q = q, p end

			local key = p * 100000 + q
			if not edges[key] then
				edges[key] = true
				local ex, ey, ez = vx[q] - vx[p], vy[q] - vy[p], vz[q] - vz[p]
				addAxis( 0, ez, -ey )
				addAxis( -ez, 0, ex )
				addAxis( ey, -ex, 0 )
			end
		end
	end

	-- Its box: the first three axes
	return {
		axes = axes, count = axisCount,
		minX = axes[4], minY = axes[9], minZ = axes[14], maxX = axes[5], maxY = axes[10], maxZ = axes[15],
	}
end

---@return table[] pieces
local function buildPieces( source )
	local pieces, points = {}, source.mesh.points
	for _, ledge in ipairs( source.mesh.ledges ) do
		local piece = buildPiece( ledge, points, source.place )
		if piece then pieces[#pieces + 1] = piece end
	end

	source.pieces = pieces
	return pieces
end

-- The sweep --------------------------------------------------------------------------------------------------------------

---A box (center s, half size e) moving by d against one convex piece. Writes to `out` if that is a hit before out.Fraction.
local function sweepPiece( piece, source, sx, sy, sz, dx, dy, dz, ex, ey, ez, out )
	local axes = piece.axes
	local enter, leave = -math.huge, math.huge
	local hitX, hitY, hitZ
	local startInside, endInside = true, true

	for i = 1, piece.count, 5 do
		local ax, ay, az, lo, hi = axes[i], axes[i + 1], axes[i + 2], axes[i + 3], axes[i + 4]
		local radius = ex * abs( ax ) + ey * abs( ay ) + ez * abs( az )
		local origin = ax * sx + ay * sy + az * sz
		local delta = ax * dx + ay * dy + az * dz

		-- Where the center of the box is inside the piece along this axis
		local low, high = lo - radius, hi + radius

		-- A box that is beside the piece and moves away or along it (a surf ramp is tangent) cannot hit it
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
			-- The box stops EPSILON before the piece
			local first, last, sign
			if delta > 0 then
				first, last, sign = ( low - EPSILON - origin ) / delta, ( high + EPSILON - origin ) / delta, -1
			else
				first, last, sign = ( high + EPSILON - origin ) / delta, ( low - EPSILON - origin ) / delta, 1
			end

			if first > enter then enter, hitX, hitY, hitZ = first, ax * sign, ay * sign, az * sign end
			if last < leave then leave = last end

			-- It can't be earlier than what was found, and it is a miss if it leaves one axis before it enters another
			if enter > leave or enter >= out.Fraction then return end
		end
	end

	-- Standing in it
	if startInside then
		out.StartSolid = true
		if endInside then out.AllSolid, out.Fraction = true, 0 end
		return
	end

	if enter < leave and enter < out.Fraction and hitX then
		out.Fraction = max( 0, enter )
		out.HitNormal = { x = hitX, y = hitY, z = hitZ }
		out.Contents, out.Texinfo, out.SurfaceName = source.contents, source.texinfo, source.surfaceprop
		out.Displacement = source.terrain == true
	end
end

-- The grid -----------------------------------------------------------------------------------------------------------------

local function cellKey( ix, iy, iz )
	return ( ix + 512 ) + 1024 * ( ( iy + 512 ) + 1024 * ( iz + 512 ) )
end

local function addSource( set, source )
	set.sources = set.sources + 1

	local x0, y0, z0 = floor( source.minX / CELL ), floor( source.minY / CELL ), floor( source.minZ / CELL )
	local x1, y1, z1 = floor( source.maxX / CELL ), floor( source.maxY / CELL ), floor( source.maxZ / CELL )
	if ( x1 - x0 + 1 ) * ( y1 - y0 + 1 ) * ( z1 - z0 + 1 ) > MAX_CELLS then
		set.big[#set.big + 1] = source
		return
	end

	local grid = set.grid
	for ix = x0, x1 do
		for iy = y0, y1 do
			for iz = z0, z1 do
				local key = cellKey( ix, iy, iz )
				local list = grid[key]
				if not list then
					list = {}
					grid[key] = list
				end
				list[#list + 1] = source
			end
		end
	end
end

-- Building ---------------------------------------------------------------------------------------------------------------

---A prop's mesh is in the model's own space: scaled, turned and moved to where the prop stands (the same as PropCraft's placed()).
local function propPlacement( prop )
	local scale = prop.UniformScale or 1
	local angles, origin = prop.Angles, prop.Origin
	local forward, right, up = angles:Forward(), -angles:Right(), angles:Up()

	return function( p )
		local x, y, z = p.x * scale, p.y * scale, p.z * scale
		return origin.x + x * forward.x + y * right.x + z * up.x, origin.y + x * forward.y + y * right.y + z * up.y, origin.z + x * forward.z + y * right.z + z * up.z
	end
end

---Reads the collision of a map. Runs as a coroutine: `yield` is called now and then.
---@param bsp BSPObject
---@param yield function
---@return table set
function Physics.Build( bsp, yield )
	local set = { grid = {}, big = {}, stamp = 0, sources = 0, terrain = 0, props = 0 }
	local started = SysTime()

	-- The terrain: lump 28 has the collision of every displacement, in the order of the displacement list
	local blobs = cvTerrain:GetBool() and bsp:GetPhysDisps() or {}
	local failed, firstError = 0, nil
	if #blobs > 0 then
		local data = bsp:GetLump( 28 )
		local infos, faces = bsp:GetDispInfo(), bsp:GetFaces()

		for i, blob in ipairs( blobs ) do
			local info = infos[blob.index]

			-- The high bit of minTess says the rest of it holds flags (builddisp.cpp, InitDispInfo). NikNaks reads the low half as
			-- flags and the high half as minTess, so that is negative. SURF_NOHULL_COLL (0x4): hulls pass through
			local noHull = info and info.minTess < 0 and bit.band( info.flags or 0, 0x4 ) ~= 0

			if blob.size > 0 and not noHull then
				local mesh, err = NikNaks.Physics.ParseSolid( data, blob.bit, blob.size )
				if not mesh then
					failed = failed + 1
					firstError = firstError or err
				else
					local mins, maxs = NikNaks.Physics.MeshBounds( mesh )
					local face = info and faces[info.MapFace]
					addSource( set, {
						mesh = mesh, terrain = true, contents = info and info.contents or CONTENTS_SOLID, texinfo = face and face.texinfo,
						minX = mins.x, minY = mins.y, minZ = mins.z, maxX = maxs.x, maxY = maxs.y, maxZ = maxs.z,
					} )
					set.terrain = set.terrain + 1
				end
			end

			if i % 8 == 0 then yield() end
		end
	end

	-- The static props that are solid in the map and have a .phy file
	local models, done = {}, 0
	for _, prop in pairs( bsp:GetStaticProps() ) do
		if prop.Solid == SOLID_VPHYSICS and prop.PropType then
			local meshes = models[prop.PropType]
			if meshes == nil then
				local ok, loaded = pcall( NikNaks.Physics.Load, prop.PropType )
				meshes = ok and loaded or false
				models[prop.PropType] = meshes
				yield()
			end

			if meshes then
				local place = propPlacement( prop )
				for _, mesh in ipairs( meshes ) do
					-- The box of the prop: the corners of the box of its mesh
					local lo, hi = NikNaks.Physics.MeshBounds( mesh )
					local minX, minY, minZ, maxX, maxY, maxZ = math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge
					for cx = 0, 1 do
						for cy = 0, 1 do
							for cz = 0, 1 do
								local x, y, z = place( Vector( cx == 0 and lo.x or hi.x, cy == 0 and lo.y or hi.y, cz == 0 and lo.z or hi.z ) )
								minX, minY, minZ, maxX, maxY, maxZ = min( minX, x ), min( minY, y ), min( minZ, z ), max( maxX, x ), max( maxY, y ), max( maxZ, z )
							end
						end
					end

					addSource( set, {
						mesh = mesh, place = place, contents = CONTENTS_SOLID, surfaceprop = mesh.surfaceprop,
						minX = minX, minY = minY, minZ = minZ, maxX = maxX, maxY = maxY, maxZ = maxZ,
					} )
				end
				set.props = set.props + 1
			end
		end

		done = done + 1
		if done % 40 == 0 then yield() end
	end

	print( ( "[PocketMap] %s: collision of %d static props and %d displacements (pocketmap_physics_terrain %s), read in %.1f s" ):format(
		bsp:GetMapName(), set.props, set.terrain, cvTerrain:GetBool() and "on" or "off", SysTime() - started ) )
	if failed > 0 then
		print( ( "[PocketMap] %d displacement blobs could not be read, the first: %s" ):format( failed, tostring( firstError ) ) )
	end
	return set
end

---Reads the collision of the map of a tiny map in the background, then calls `done`. `mini.physics` is the result, or false if it failed
---(the walk then has brushes, and the displacements of cl_displacements.lua).
---@param mini table
---@param done function
function Physics.Prepare( mini, done )
	if mini.physics ~= nil then done() return end
	if mini.physicsPreparing then return end
	mini.physicsPreparing = true

	local co = coroutine.create( function() mini.physics = Physics.Build( mini.bsp, coroutine.yield ) end )
	local name = "PocketMap_PhysicsPrepare" .. tostring( mini )

	local function finish()
		hook.Remove( "Think", name )
		mini.physicsPreparing = nil
		done()
	end

	hook.Add( "Think", name, function()
		if mini.state == "removed" then
			hook.Remove( "Think", name )
			return
		end

		local deadline = SysTime() + PREPARE_SECONDS
		repeat
			local ok, err = coroutine.resume( co )
			if not ok then
				mini.physics = false
				ErrorNoHalt( "[PocketMap] The collision of the map could not be read: " .. tostring( err ) .. "\n" )
				finish()
				return
			end
		until coroutine.status( co ) == "dead" or SysTime() >= deadline

		if coroutine.status( co ) == "dead" then finish() end
	end )
end

-- Tracing ------------------------------------------------------------------------------------------------------------------

---Adds what the box hits to `out`, if that is before what is in it.
---@param set table # from Physics.Build
---@param lo table # the bounds of the sweep: x, y, z
---@param hi table
function Physics.Trace( set, start, finish, mins, maxs, mask, lo, hi, out )
	if out.AllSolid then return end
	mask = mask or MASK_PLAYERSOLID

	local ex, ey, ez = ( maxs.x - mins.x ) / 2, ( maxs.y - mins.y ) / 2, ( maxs.z - mins.z ) / 2
	local sx, sy, sz = start.x + mins.x + ex, start.y + mins.y + ey, start.z + mins.z + ez
	local dx, dy, dz = finish.x - start.x, finish.y - start.y, finish.z - start.z

	set.stamp = set.stamp + 1
	local stamp = set.stamp
	local loX, loY, loZ, hiX, hiY, hiZ = lo.x - EPSILON, lo.y - EPSILON, lo.z - EPSILON, hi.x + EPSILON, hi.y + EPSILON, hi.z + EPSILON

	local function consider( source )
		if source.stamp == stamp then return end
		source.stamp = stamp

		if bit.band( source.contents, mask ) == 0 then return end
		if source.maxX < loX or source.minX > hiX or source.maxY < loY or source.minY > hiY or source.maxZ < loZ or source.minZ > hiZ then return end

		for _, piece in ipairs( source.pieces or buildPieces( source ) ) do
			if piece.maxX >= loX and piece.minX <= hiX and piece.maxY >= loY and piece.minY <= hiY and piece.maxZ >= loZ and piece.minZ <= hiZ then
				sweepPiece( piece, source, sx, sy, sz, dx, dy, dz, ex, ey, ez, out )
				if out.AllSolid then return end
			end
		end
	end

	for _, source in ipairs( set.big ) do consider( source ) end

	local grid = set.grid
	for ix = floor( loX / CELL ), floor( hiX / CELL ) do
		for iy = floor( loY / CELL ), floor( hiY / CELL ) do
			for iz = floor( loZ / CELL ), floor( hiZ / CELL ) do
				local list = grid[cellKey( ix, iy, iz )]
				if list then
					for _, source in ipairs( list ) do consider( source ) end
				end
			end
		end
	end
end
