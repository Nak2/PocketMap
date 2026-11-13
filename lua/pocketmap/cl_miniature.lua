-- A tiny map: one per block that is loading or showing a map. This file is the object and its life cycle. The rest of the
-- addon is an example of using NikNaks, one topic per file:
--
--   cl_loader.lua      NikNaks.Map, bsp lumps, MeshBuilder       the stages that turn a .bsp into meshes
--   cl_faces.lua       face:IsWorld(), face:GetTexture() ...     which faces are drawn
--   cl_atlas.lua       bsp:CreateLightmapAtlas                   baked light packed into a render target
--   cl_lightstyles.lua light styles of a face                    which lights are on
--   cl_props.lua       bsp:GetStaticProps(), entities            props, grouped by model
--   cl_proplight.lua   leaf:CalculateAmbientCube()               how a prop is lit
--   cl_detail.lua      bsp:GetDetailPropInfo()                   grass and plants
--   cl_sky.lua         skybox textures, sky_camera               the sky behind the map

PocketMap = PocketMap or {}

local BUDGET_SECONDS = 0.002
local MIN_NEAR_PLANE = 0.25
local STATUS_TITLE_HEIGHT = 12
local ENTITY_REFRESH_SECONDS = 10

local STATUS_ERROR = Color( 255, 120, 120 )
local STATUS_TEXT = Color( 200, 200, 200 )
local STATUS_BAR_BACK = Color( 0, 0, 0, 160 )
local STATUS_BAR_FILL = Color( 90, 200, 120 )

local Mini = PocketMap.Mini or {}
Mini.__index = Mini
PocketMap.Mini = Mini

local active = PocketMap.Active or {}
PocketMap.Active = active

local statusOffset = Vector()
local statusAngle = Angle( 0, 0, 90 )

---Creates the tiny map for a block and starts loading it.
---@param ent Entity # the block
---@param mapName string
function PocketMap.NewMiniature( ent, mapName )
	local mini = setmetatable( {
		ent = ent,
		mapName = mapName,
		settings = PocketMap.Settings and PocketMap.Settings.Read( ent ) or nil,
		title = mapName,
		state = "loading", -- loading / ready / error / removed
		status = "Starting",
		progress = 0,

		objects = {},
		skyObjects = {},
		propGroups = {},
		detailMeshes = {},
		missingNames = {},

		staticCount = 0,
		entityCount = 0,
		hiddenEntities = 0,
		missingModels = 0,
		propsDrawn = 0,
		detailSprites = 0,
		detailModels = 0,
		skippedFaces = 0,
		brushFaces = 0,
		litFaces = 0,
		materialsLoaded = 0,
		slowestMaterial = 0,
		lighting = "none",

		matrix = Matrix(),
		propMatrix = Matrix(),
		propScaleVec = Vector(),
	}, Mini )

	mini.co = coroutine.create( function() PocketMap.Loader.Run( mini ) end )
	active[mini] = true
	PocketMap.Hooks.SetActive( true )
	return mini
end

function Mini:SetStatus( text, progress )
	self.status = text
	if progress then self.progress = progress end
end

function Mini:Fail( message )
	self.state = "error"
	self.status = message
	MsgC( Color( 255, 100, 100 ), "[PocketMap] " .. message .. "\n" )
end

local function destroyAll( objects )
	for _, object in ipairs( objects ) do object:Destroy() end
end

function Mini:BeginEntityRefresh()
	if self.state == "removed" or self.entityRefresh then return end
	self.entityRefresh = { ent = self.ent, creation = self.ent:GetCreationID(),
		frame = FrameNumber(), expires = RealTime() + ENTITY_REFRESH_SECONDS }
	local session = PocketMap.Walk and PocketMap.Walk.session
	if session and session.mini == self then session.inputs = {} end
end

function Mini:UpdateEntityRefresh()
	local refresh = self.entityRefresh
	if not refresh then return end
	-- OnRemove can run while the old entity is still valid. Do not mistake
	-- that for its reappearance before the full update has finished this frame.
	if FrameNumber() <= refresh.frame then return end
	local ent = refresh.ent
	if IsValid( ent ) and not ent:IsDormant() then
		if self.ent ~= ent or ent:GetCreationID() ~= refresh.creation then
			self:Destroy()
			return
		end
		local name = ent:GetMapName()
		if name == self.mapName then
			ent.Miniature, ent.LoadedMap = self, self.mapName
			self.entityRefresh, self.matrixFrame = nil, nil
			return
		elseif name ~= "" then
			self:Destroy()
			return
		end
		-- Networked strings can briefly be empty during recreation. A genuine
		-- clear or a block which never returns still expires below.
	end
	if RealTime() >= refresh.expires then self:Destroy() end
end

function Mini:Destroy()
	if self.state == "removed" then return end
	active[self] = nil
	self.state = "removed"
	self.entityRefresh = nil
	if PocketMap.Walk and PocketMap.Walk.session and PocketMap.Walk.session.mini == self then
		PocketMap.Walk.Leave()
	end
	if IsValid( self.ent ) and self.ent.Miniature == self then
		self.ent.Miniature, self.ent.LoadedMap, self.ent.LimitHit = nil, nil, false
	end

	destroyAll( self.objects )
	if PocketMap.Decals then PocketMap.Decals.Destroy( self ) end
	if PocketMap.Flashlight then PocketMap.Flashlight.FreeWorldShadows( self ) end
	if PocketMap.WorldCache then PocketMap.WorldCache.Destroy( self ) end
	self.worldFaceGroups, self.worldFaceClusters, self.worldLightUV = nil, nil, nil
	PocketMap.MapIO.Destroy( self )
	destroyAll( self.skyObjects )
	destroyAll( self.detailMeshes )
	PocketMap.Water.Free( self )
	PocketMap.Sky.Free( self )
	PocketMap.Props.Destroy( self )
	PocketMap.Effects.Destroy( self )
	PocketMap.RT.Release( self.atlasTarget )
	PocketMap.RT.Release( self.atlasLayerTarget )

	-- Sky and world groups can share a skin's meshes, or own a sky-only set.
	local destroyed = {}
	for _, group in ipairs( self.propGroups ) do
		if group.meshes and not destroyed[group.meshes] then
			destroyed[group.meshes] = true
			PocketMap.PropMesh.Destroy( group.meshes )
		end
	end

	self.objects, self.skyObjects, self.detailMeshes, self.propGroups, self.bsp = {}, {}, {}, {}, nil
	self.atlasTarget, self.atlasLayerTarget, self.atlasObject, self.lightmapTexture = nil, nil, nil, nil
	self.displacementCollision = nil

	PocketMap.Hooks.SetActive( next( active ) ~= nil )
end

---Block -> map: the middle of the map goes in the middle of the block, scaled to fit. The engine draws a block more than
---once a frame (opaque and translucent pass, mirrors, cameras), and it doesn't move between them.
function Mini:UpdateMatrix()
	local frame = FrameNumber()
	if self.matrixFrame == frame then return self.transformRevision end
	self.matrixFrame = frame
	local pos, angles = self.ent:GetPos(), self.ent:GetAngles()
	local old = self.transformPose
	if old and old.x == pos.x and old.y == pos.y and old.z == pos.z
		and old.p == angles.p and old.yaw == angles.y and old.r == angles.r and old.scale == self.scale
		and old.center == self.boxCenter and old.mapCenter == self.mapCenter then return self.transformRevision end
	self.transformPose = { x = pos.x, y = pos.y, z = pos.z, p = angles.p, yaw = angles.y, r = angles.r,
		scale = self.scale, center = self.boxCenter, mapCenter = self.mapCenter }
	self.transformRevision = ( self.transformRevision or 0 ) + 1

	local matrix = self.matrix
	matrix:Identity()
	matrix:Translate( self.ent:LocalToWorld( self.boxCenter ) )
	matrix:Rotate( angles )
	matrix:Scale( self.scaleVec )
	matrix:Translate( self.negCenter )
	return self.transformRevision
end

function Mini:BlockPosition( mapPosition )
	return ( mapPosition - self.mapCenter ) * self.scale + self.boxCenter
end

---The origin of the view being rendered decides, not the player: a camera outside the block is outside.
function Mini:EyeInside()
	local view = PocketMap.Scene and PocketMap.Scene.View( self )
	return not self.ent:IsOutsideBox( view and view.origin or EyePos() )
end

-- Loading status ------------------------------------------------------------------------------------------------------

local function isLoading( mini )
	return mini.state ~= "ready" and mini.state ~= "removed"
end

local function titleWithProgress( mini )
	return ( "%s  %d%%" ):format( mini.title, math.floor( mini.progress * 100 ) )
end

---At the top of the screen, for a player inside the block who can't see the text above it.
function Mini:DrawHUD()
	if not isLoading( self ) then return end

	local x, y = ScrW() / 2, 24
	if self.state == "error" then
		draw.SimpleTextOutlined( self.title, "DermaLarge", x, y, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, color_black )
		draw.SimpleTextOutlined( self.status, "DermaDefaultBold", x, y + 34, STATUS_ERROR, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, color_black )
		return
	end

	local width = 400
	draw.SimpleTextOutlined( titleWithProgress( self ), "DermaLarge", x, y, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, color_black )
	draw.SimpleTextOutlined( self.status, "DermaDefault", x, y + 34, STATUS_TEXT, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, color_black )
	draw.RoundedBox( 3, x - width / 2, y + 54, width, 8, STATUS_BAR_BACK )
	draw.RoundedBox( 3, x - width / 2, y + 54, width * self.progress, 8, STATUS_BAR_FILL )
end

---Above the block, for everybody else.
function Mini:DrawStatus()
	if not isLoading( self ) or self:EyeInside() then return end

	statusOffset.z = self.ent.BoxMaxs.z + STATUS_TITLE_HEIGHT
	statusAngle.y = LocalPlayer():EyeAngles().y - 90

	cam.Start3D2D( self.ent:LocalToWorld( statusOffset ), statusAngle, 0.4 )
		if self.state == "error" then
			draw.SimpleTextOutlined( self.title, "DermaLarge", 0, 0, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM, 1, color_black )
			draw.SimpleTextOutlined( self.status, "DermaDefaultBold", 0, 4, STATUS_ERROR, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, color_black )
		else
			draw.SimpleTextOutlined( titleWithProgress( self ), "DermaLarge", 0, 0, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM, 1, color_black )
			draw.SimpleTextOutlined( self.status, "DermaDefault", 0, 4, STATUS_TEXT, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, color_black )
			draw.RoundedBox( 2, -150, 24, 300, 6, STATUS_BAR_BACK )
			draw.RoundedBox( 2, -150, 24, 300 * self.progress, 6, STATUS_BAR_FILL )
		end
	cam.End3D2D()
end

-- Hooks (cl_hooks.lua: only there while a tiny map exists) ---------------------------------------------------------------

---The tiny map is small, so the camera easily gets closer than the near plane (about 7 units) and the map is cut off. While a
---block is close the near plane moves in to half the distance. A hook that returns a view replaces the rest, so all of it is returned.
PocketMap.Hooks.Register( "CalcView", "PocketMap_NearClip", function( ply, origin, angles, fov, znear, zfar )
	if ply:GetViewEntity() ~= ply then return end

	if PocketMap.Walk and PocketMap.Walk.session then
		return PocketMap.Walk.View( fov, zfar )
	end
	local nearest = math.huge
	for mini in pairs( active ) do
		if IsValid( mini.ent ) and mini.scaleVec then
			nearest = math.min( nearest, mini.ent:NearestPoint( origin ):Distance( origin ) )
		end
	end

	local wanted = math.max( nearest * 0.5, MIN_NEAR_PLANE )
	if wanted >= znear then
		PocketMap.Water.NoteView( origin, angles, fov, znear, zfar )
		return
	end

	PocketMap.Water.NoteView( origin, angles, fov, wanted, zfar )
	return { origin = origin, angles = angles, fov = fov, znear = wanted, zfar = zfar }
end )

-- Repair a class left incomplete by an earlier partial auto-refresh. During
-- normal startup these dependencies are loaded later by the autorun loader.
if not Mini.Draw and PocketMap.Props and PocketMap.Detail and PocketMap.Sky and PocketMap.Water then
	include("pocketmap/cl_draw.lua")
end

PocketMap.Hooks.Register( "HUDPaint", "PocketMap_Status", function()
	for mini in pairs( active ) do
		if IsValid( mini.ent ) and isLoading( mini ) and mini:EyeInside() then
			mini:DrawHUD()
			return
		end
	end
end )

---The time budget is shared by the blocks that are loading.
PocketMap.Hooks.Register( "Think", "PocketMap_Load", function()
	local count = table.Count( active )
	if count == 0 then return end

	local perBlock = BUDGET_SECONDS / count
	for mini in pairs( active ) do
		mini:UpdateEntityRefresh()
		if mini.entityRefresh or mini.state == "removed" then
			-- Retain resources while the original network entity is rebuilding.
		elseif IsValid( mini.ent ) then
			PocketMap.Loader.Step( mini, SysTime() + perBlock )
		else
			mini:Destroy()
		end
	end
end )

-- cl_hooks.lua disables its previous registry on a full autorun refresh.
-- Existing miniatures still need the newly registered callbacks installed.
PocketMap.Hooks.SetActive( next( active ) ~= nil )
