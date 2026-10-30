if not PocketMap.Mini then return end

local active = PocketMap.Active
local polygonKey = PocketMap.Faces.PolygonKey

concommand.Add( "pocketmap_info", function()
	for mini in pairs( active ) do
		print( ( "[PocketMap] %s: %s, %d world meshes (%d brush entity faces, %d skipped as the same polygon), %d prop models (%d static props + %d entities), %d props drawn" ):format(
			mini.mapName, mini.state, #mini.objects, mini.brushFaces, mini.skippedFaces, #mini.propGroups, mini.staticCount, mini.entityCount, mini.propsDrawn ) )
		print( ( "           %d entities hidden by the map, %d models missing%s" ):format(
			mini.hiddenEntities, mini.missingModels, #mini.missingNames > 0 and ( ", e.g. " .. table.concat( mini.missingNames, ", " ) ) or "" ) )
		print( ( "           materials: %d loaded, the slowest took %.3f s" ):format( mini.materialsLoaded, mini.slowestMaterial ) )
		print( ( "           sky backdrop: %s (skyname %s), %d faces with the sky debug material left out" ):format(
			mini.skyBackdrop and "on" or "off", tostring( mini.skyName ), mini.skippedSkyFaces or 0 ) )

		if mini.skyOrigin then
			print( ( "           3D skybox: %d faces in %d meshes, scale %s, %d props in the sky room" ):format(
				mini.skyFaceCount or 0, #mini.skyObjects, tostring( mini.skyScale ), mini.skyProps or 0 ) )
		end

		if mini.lightmapTexture then
			print( ( "           lightmap atlas: %s, %s, %d faces, %s" ):format(
				tostring( mini.atlasSize ), tostring( mini.atlasFormat ), mini.atlasFaces or 0, mini.atlasTarget and mini.atlasTarget:GetName() or "?" ) )
		else
			print( "           lightmap atlas: none" .. ( mini.atlasFail and ( " (" .. mini.atlasFail .. ")" ) or "" ) )
		end

		if mini.atlasObject then
			print( ( "           animated light: %d faces, layers %s" ):format(
				mini.atlasObject:GetAnimatedFaceCount(), mini.atlasLayerTarget and mini.atlasLayerTarget:GetName() or "?" ) )
		end

		print( ( "           detail: %d sprites in %d meshes + %d models. lighting: %s" ):format(
			mini.detailSprites, #mini.detailMeshes, mini.detailModels, mini.lighting ) )
	end
end )

local function addDebugCommand( name, callback )
	concommand.Add( name, function( ... )
		if GetConVar( "developer" ):GetInt() > 0 then callback( ... ) end
	end )
end

-- pocketmap_zprobe [radius]: the faces around the spot you aim at on a block, to find what z-fights
addDebugCommand( "pocketmap_zprobe", function( _, _, args )
	local radius = tonumber( args[1] ) or 8
	local ply = LocalPlayer()
	local eye, dir = ply:EyePos(), ply:GetAimVector()

	for mini in pairs( active ) do
		if mini.state ~= "removed" and mini.scaleVec and mini.bsp then
			-- The aim ray in the map's own space, and where it hits the map
			mini:UpdateMatrix()
			local inverse = mini.matrix:GetInverse()
			local a = inverse * eye
			local delta = ( inverse * ( eye + dir * 4000 ) ) - a
			local length = delta:Length()

			local entry = length > 0.001 and util.IntersectRayWithOBB( a, delta, mini.mapCenter, angle_zero,
				mini.mapMins - mini.mapCenter, mini.mapMaxs - mini.mapCenter )
			if entry then
				local trace = mini.bsp:SurfaceTraceLine( entry, entry + ( delta / length ) * ( mini.mapMaxs - mini.mapMins ):Length() )
				if trace.Hit then
					local point = trace.HitPos
					print( string.format( "[PocketMap] %s: aiming at %s, faces within %.1f units:", mini.mapName, tostring( point ), radius ) )

					local found = {}
					for _, face in pairs( mini.bsp:GetFaces() ) do
						-- The corners as they are drawn: the world as it is, a brush entity moved to where the entity is
						local points
						if face:IsWorld() then
							points = face:GetVertexs()
						else
							points = {}
							for i, vertex in ipairs( face:GenerateVertexData() or {} ) do points[i] = vertex.pos end
						end

						if points and #points >= 3 then
							local mins, maxs = Vector( points[1] ), Vector( points[1] )
							for _, p in ipairs( points ) do
								mins = Vector( math.min( mins.x, p.x ), math.min( mins.y, p.y ), math.min( mins.z, p.z ) )
								maxs = Vector( math.max( maxs.x, p.x ), math.max( maxs.y, p.y ), math.max( maxs.z, p.z ) )
							end

							if point.x >= mins.x - radius and point.x <= maxs.x + radius and point.y >= mins.y - radius and point.y <= maxs.y + radius
								and point.z >= mins.z - radius and point.z <= maxs.z + radius then
								local normal = ( points[2] - points[1] ):Cross( points[3] - points[1] ):GetNormalized()
								local distance = normal:Dot( point - points[1] )
								if math.abs( distance ) <= radius then
									local entity = face:GetEntity()
									found[#found + 1] = {
										distance = distance,
										text = string.format( "  face %d  %s  %s  %s%s  %s", face.__id, face:GetTexture() or "?",
											face:IsWorld() and "world" or ( "brush entity " .. tostring( entity and entity.classname ) ),
											face.lightofs >= 0 and "lightmap" or "NO lightmap", face:IsDisplacement() and "  displacement" or "",
											string.format( "plane distance %.2f", distance ) ),
									}
								end
							end
						end
						face:ClearMeshData()
					end

					table.sort( found, function( x, y ) return math.abs( x.distance ) < math.abs( y.distance ) end )
					for i = 1, math.min( #found, 20 ) do print( found[i].text ) end
					if #found == 0 then print( "  none: try a bigger radius" ) end
				end
			end
		end
	end
end )

-- pocketmap_findprop x y z [radius]: props near a point of the map (its own coordinates) in the draw list of a block
addDebugCommand( "pocketmap_findprop", function( _, _, args )
	local x, y, z, radius = tonumber( args[1] ), tonumber( args[2] ), tonumber( args[3] ), tonumber( args[4] ) or 128
	if not ( x and y and z ) then print( "[PocketMap] Usage: pocketmap_findprop x y z [radius]" ) return end

	local point = Vector( x, y, z )
	for mini in pairs( active ) do
		if mini.mapCenter and mini.state ~= "removed" then
			local found = 0
			for _, group in ipairs( mini.propGroups ) do
				for _, p in ipairs( group.sky and {} or group.props ) do
					local mapPos = ( p.lpos - mini.boxCenter ) / mini.scale + mini.mapCenter
					if mapPos:Distance( point ) <= radius then
						found = found + 1
						print( string.format( "[PocketMap] %s: %s at %s, scale %.4f, skin %d, drawn %s",
							mini.mapName, group.model, tostring( mapPos ), p.lscale, p.skin,
							group.meshes and ( #group.meshes .. " mesh part(s)" ) or "as an entity" ) )
					end
				end
			end
			if found == 0 then
				print( string.format( "[PocketMap] %s: no prop within %d of %s in the draw list (%d props, %d models, %d missing model files)",
					mini.mapName, radius, tostring( point ), mini.staticCount + mini.entityCount, #mini.propGroups, mini.missingModels ) )
			end
		end
	end
end )

-- pocketmap_dupdebug <mapname>: faces that are the same polygon (the loader draws those once)
addDebugCommand( "pocketmap_dupdebug", function( _, _, args )
	local bsp, err = NikNaks.Map( tostring( args[1] ) )
	if not bsp then print( "[PocketMap] Could not open the map (error " .. tostring( err ) .. ")." ) return end

	local byKey, order = {}, {}
	for _, face in pairs( bsp:GetFaces() ) do
		if face:IsWorld() and face:ShouldRender() then
			local key = polygonKey( face )
			if key then
				local list = byKey[key]
				if not list then
					list = {}
					byKey[key] = list
					order[#order + 1] = key
				end
				list[#list + 1] = face
			end
		end
	end

	local groups, dispPairs, lightPairs, sameTexture, examples = 0, 0, 0, 0, {}
	for _, key in ipairs( order ) do
		local list = byKey[key]
		if #list > 1 then
			groups = groups + 1

			local hasDisp, hasLit, hasUnlit, textures = false, false, false, {}
			local parts = {}
			for _, face in ipairs( list ) do
				if face.dispinfo > -1 then hasDisp = true end
				if face.lightofs >= 0 then hasLit = true else hasUnlit = true end
				textures[face:GetTexture() or "?"] = true
				parts[#parts + 1] = string.format( "#%d %s%s%s", face.__id, face:GetTexture() or "?",
					face.dispinfo > -1 and " [displacement]" or "", face.lightofs >= 0 and " [lit]" or " [no lightmap]" )
			end

			if hasDisp then dispPairs = dispPairs + 1 end
			if hasLit and hasUnlit then lightPairs = lightPairs + 1 end
			if table.Count( textures ) == 1 then sameTexture = sameTexture + 1 end
			if #examples < 12 then examples[#examples + 1] = table.concat( parts, "   +   " ) end
		end
	end

	print( string.format( "[PocketMap] %s: %d polygons that are in the map more than once", bsp:GetMapName(), groups ) )
	print( string.format( "           %d involve a displacement, %d are a lit + an unlit face, %d use the same texture twice", dispPairs, lightPairs, sameTexture ) )
	for _, text in ipairs( examples ) do print( "           " .. text ) end
end )

-- pocketmap_dispdebug <mapname>: displacements that could be drawn twice
addDebugCommand( "pocketmap_dispdebug", function( _, _, args )
	local bsp, err = NikNaks.Map( tostring( args[1] ) )
	if not bsp then print( "[PocketMap] Could not open the map (error " .. tostring( err ) .. ")." ) return end

	local faces = bsp:GetFaces()
	local list, byFace = bsp:GetDispInfo()

	local dispFaces, perDispinfo, mismatched, sameStart, examples = 0, {}, 0, {}, {}
	local lightMismatch = 0
	local duplicates = 0
	local function example( text ) if #examples < 12 then examples[#examples + 1] = text end end

	for _, face in pairs( faces ) do
		if face.dispinfo > -1 then
			dispFaces = dispFaces + 1
			perDispinfo[face.dispinfo] = ( perDispinfo[face.dispinfo] or 0 ) + 1

			local info = list[face.dispinfo]
			if not info then
				example( string.format( "face %d has dispinfo %d, which doesn't exist", face.__id, face.dispinfo ) )
			elseif info.MapFace ~= face.__id then
				mismatched = mismatched + 1
				example( string.format( "face %d uses dispinfo %d, but that dispinfo's MapFace is %d", face.__id, face.dispinfo, info.MapFace ) )
			end

			-- A displacement's lightmap should have a luxel for each of its vertices (2^power + 1 on each side)
			if info then
				local side = 2 ^ info.power + 1
				local w, h = face.LightmapTextureSizeInLuxels[1] + 1, face.LightmapTextureSizeInLuxels[2] + 1
				if w ~= side or h ~= side then
					lightMismatch = lightMismatch + 1
					example( string.format( "face %d: the displacement is %dx%d vertices, its lightmap %dx%d luxels", face.__id, side, side, w, h ) )
				end
			end

			-- Two displacements starting at the same spot lie on top of each other
			if info then
				local p = info.startPosition
				local key = string.format( "%.0f %.0f %.0f", p.x, p.y, p.z )
				if sameStart[key] then
					duplicates = duplicates + 1
					example( string.format( "faces %d and %d have displacements starting at the same spot (%s)", sameStart[key], face.__id, key ) )
				else
					sameStart[key] = face.__id
				end
			end
		end
	end

	local shared = 0
	for index, n in pairs( perDispinfo ) do
		if n > 1 then
			shared = shared + 1
			example( string.format( "dispinfo %d is used by %d faces", index, n ) )
		end
	end

	print( string.format( "[PocketMap] %s: %d displacement faces, %d dispinfos in the lump", bsp:GetMapName(), dispFaces, #list + 1 ) )
	print( string.format( "           %d faces whose dispinfo points back at another face (MapFace)", mismatched ) )
	print( string.format( "           %d dispinfos shared by more than one face", shared ) )
	print( string.format( "           %d displacements starting at the same spot as another", duplicates ) )
	print( string.format( "           %d displacements whose lightmap is not one luxel per vertex", lightMismatch ) )
	for _, text in ipairs( examples ) do print( "           " .. text ) end
end )
