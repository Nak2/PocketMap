PocketMap = PocketMap or {}

local FIT_MARGIN = 0.97
local SKY_FIT_MARGIN = 0.95
local DEFAULT_SKY_SCALE = 16
local LEAFS_PER_YIELD = 4000

---@return number # the farthest corner of the leaf from the point, squared
local function farthestCornerSqr( leaf, point )
	local lo, hi = leaf.mins, leaf.maxs
	local dx = math.max( math.abs( lo.x - point.x ), math.abs( hi.x - point.x ) )
	local dy = math.max( math.abs( lo.y - point.y ), math.abs( hi.y - point.y ) )
	local dz = math.max( math.abs( lo.z - point.z ), math.abs( hi.z - point.z ) )
	return dx * dx + dy * dy + dz * dz
end

local function growBounds( bounds, leaf )
	local lo, hi = leaf.mins, leaf.maxs
	bounds.loX, bounds.loY, bounds.loZ = math.min( bounds.loX, lo.x ), math.min( bounds.loY, lo.y ), math.min( bounds.loZ, lo.z )
	bounds.hiX, bounds.hiY, bounds.hiZ = math.max( bounds.hiX, hi.x ), math.max( bounds.hiY, hi.y ), math.max( bounds.hiZ, hi.z )
end

local function newBounds()
	return { loX = math.huge, loY = math.huge, loZ = math.huge, hiX = -math.huge, hiY = -math.huge, hiZ = -math.huge }
end

local function hasVolume( bounds )
	return bounds.loX < bounds.hiX and bounds.loY < bounds.hiY and bounds.loZ < bounds.hiZ
end

---The playable space is every open leaf outside the sky room. The reach of the sky room is measured from the sky camera.
---@return table? bounds # nil if the leaves enclose no volume
---@return number reach # how far the sky room reaches from the sky camera
local function measureLeafs( bsp, skyArea, skyOrigin, yield )
	local bounds = newBounds()
	local reachSqr = 0
	local counted = 0

	for _, leaf in pairs( bsp:GetLeafs() ) do
		if leaf.area == skyArea then
			reachSqr = math.max( reachSqr, farthestCornerSqr( leaf, skyOrigin ) )
		elseif leaf.cluster >= 0 then
			growBounds( bounds, leaf )
		end

		counted = counted + 1
		if yield and counted % LEAFS_PER_YIELD == 0 then yield() end
	end

	return hasVolume( bounds ) and bounds or nil, math.sqrt( reachSqr )
end

---The 3D skybox keeps its small scenery in a room of its own. Returns the sky fields of the fit, and the bounds of the playable space.
---@return table? sky # skyArea, skyOrigin, skyScale, skyReach
---@return Vector? mins
---@return Vector? maxs
local function fitSkyRoom( bsp, yield )
	if not bsp:HasSkyBox() then return nil end

	local skyOrigin = bsp:GetSkyBoxPos()
	local skyLeaf = bsp:PointInLeaf( 0, skyOrigin )
	if not skyLeaf or skyLeaf.area <= 0 then return nil end

	local bounds, reach = measureLeafs( bsp, skyLeaf.area, skyOrigin, yield )
	local sky = {
		skyArea = skyLeaf.area,
		skyOrigin = skyOrigin,
		skyScale = tonumber( bsp:GetSkyBoxScale() ) or DEFAULT_SKY_SCALE,
		skyReach = reach,
	}

	if not bounds then return sky end
	return sky, Vector( bounds.loX - 1, bounds.loY - 1, bounds.loZ - 1 ), Vector( bounds.hiX + 1, bounds.hiY + 1, bounds.hiZ + 1 )
end

local function scaleToFit( size, box )
	return math.min( box.x / math.max( size.x, 1 ), box.y / math.max( size.y, 1 ), box.z / math.max( size.z, 1 ) ) * FIT_MARGIN
end

---The skybox is drawn at the scale of the map (usually 16x), far bigger than the block. It is drawn smaller, so the
---farthest corner of the sky room is inside the sphere in the block.
local function effectiveSkyScale( fit, box )
	local halfBlock = math.min( box.x, box.y, box.z ) / 2
	local fitRadius = halfBlock / fit.scale * SKY_FIT_MARGIN
	return math.min( fit.skyScale, fitRadius / fit.skyReach )
end

---Fits a map into the inside of a block.
---@param bsp BSPObject
---@param ent Entity # The block (BoxMins / BoxMaxs)
---@param yield function? # Called now and then during the slow parts, to let a loader spread the work over frames
---@return table? fit # { mins, maxs, mapCenter, boxCenter, scale, skyArea, skyOrigin, skyScale, skyReach, skyScaleEff }
---@return string? err
function PocketMap.FitMap( bsp, ent, yield )
	local world = bsp:GetBModels()[0]
	if not world then return nil, "The map has no world model." end

	local fit, skyMins, skyMaxs = {}, nil, nil
	local sky
	sky, skyMins, skyMaxs = fitSkyRoom( bsp, yield )
	if sky then table.Merge( fit, sky ) end

	local mins, maxs = skyMins or world.mins, skyMaxs or world.maxs
	local box = ent.BoxMaxs - ent.BoxMins

	fit.mins, fit.maxs = mins, maxs
	fit.mapCenter = ( mins + maxs ) / 2
	fit.boxCenter = ( ent.BoxMins + ent.BoxMaxs ) / 2
	fit.scale = scaleToFit( maxs - mins, box )

	if fit.skyOrigin and fit.skyReach > 0 then
		fit.skyScaleEff = effectiveSkyScale( fit, box )
	end

	return fit
end
