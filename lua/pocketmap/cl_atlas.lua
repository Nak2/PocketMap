-- The baked light of a map in one render target, packed by bsp:CreateLightmapAtlas. The targets come from the pool in cl_rt.lua.
-- Faces lit by a flickering or pulsing style keep their light in a second, smaller target, and cl_lightanim.lua redraws them.

PocketMap = PocketMap or {}
PocketMap.Atlas = {}
local Atlas = PocketMap.Atlas

local STATUS_BASE = 0.05
local STATUS_RANGE = 0.1

local function acquireTarget( mini, width, height )
	mini.atlasFormat = "IMAGE_FORMAT_RGBA16161616F"
	local rt = PocketMap.RT.Acquire( width, height, { float = true } )

	if not rt then
		mini.atlasFormat = "IMAGE_FORMAT_RGBA8888"
		rt = PocketMap.RT.Acquire( width, height )
	end

	mini.atlasTarget = rt
	return rt
end

---Nil when no face is animated, or when there is no room: the animated styles then stay at the weight they start at.
local function acquireLayerTarget( mini, atlas )
	local width, height = atlas:GetLayerSize()
	if not width then return nil end

	mini.atlasLayerTarget = PocketMap.RT.Acquire( width, height )
	return mini.atlasLayerTarget
end

local function reportProgress( mini )
	return function( fraction ) mini:SetStatus( "Writing the lightmap", STATUS_BASE + STATUS_RANGE * fraction ) end
end

local function planAtlas( mini, faces, hdr, lightToggle )
	local styles = mini.lightStyles
	local weights = lightToggle and PocketMap.LightStyles.WeightsAtTick( styles, PocketMap.LightStyles.CurrentTick() ) or false

	return mini.bsp:CreateLightmapAtlas( {
		hdr = hdr,
		lightToggle = weights,
		animatedStyles = lightToggle and styles.animated or nil,
		progress = reportProgress( mini ),
	}, faces )
end

---Runs inside the loader (it yields).
---@param mini table
---@param faces BSPFaceObject[] # the faces that will be drawn
---@param hdr boolean # use the HDR lighting
---@param lightToggle boolean # false: the first light style of a face only
---@return ITexture? rt # nil if the atlas can't be made
---@return function? lightUV # for MeshBuilderOptions.lightUV
function Atlas.Build( mini, faces, hdr, lightToggle )
	local atlas, failure = planAtlas( mini, faces, hdr, lightToggle )
	if not atlas then
		mini.atlasFail = failure
		return nil
	end

	local width, height, smoothing = atlas:GetSize()
	local rt = acquireTarget( mini, width, height )
	if not rt then
		mini.atlasFail = ( "no render target for %dx%d: the %d MB limit of Pocket Map is used up, remove a map" ):format(
			width, height, PocketMap.RT.BudgetMegabytes() )
		return nil
	end

	atlas:Write( rt, acquireLayerTarget( mini, atlas ) or false )

	if atlas:IsAnimated() then mini.atlasObject = atlas end
	mini.atlasSize = width .. "x" .. height .. " (x" .. smoothing .. ")"
	mini.atlasFaces = atlas:GetFaceCount()
	mini.litFaces = atlas:GetFaceCount()
	return rt, atlas:GetLightUV()
end
