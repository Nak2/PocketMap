include( "shared.lua" )

local THINK_INTERVAL = 0.25
local MISSING_RECHECK_INTERVAL = 5
local HINT_RANGE_SQR = 600 * 600
local THUMB_SPIN = 35
local THUMB_SIZE = 64
local THUMB_ALPHA = 180
local GLASS_ALPHA_EMPTY = 0.15
local GLASS_ALPHA_LOADED = 0.12
local HINT_HEIGHT_ABOVE_BOX = 12
local HINT_SCALE = 0.4
local WATER_TARGET_PATTERN = "^_rt_water"

local COLOR_HINT = Color( 200, 200, 200 )
local COLOR_ERROR = Color( 255, 110, 100 )
local hintOffset = Vector()
local hintAngle = Angle( 0, 0, 90 )

function ENT:Initialize()
	self.LoadedMap = ""
	self.MapMissing = false
	self.ExpectedMap = nil
	self:SetRenderMode( RENDERMODE_TRANSCOLOR )
end

function ENT:OnRemove()
	self:DropMiniature()
end

---@return boolean
function ENT:IsMapPending()
	local wanted = self:GetMapName()
	return wanted ~= "" and wanted ~= self.LoadedMap and not self.MapMissing
end

function ENT:DropMiniature()
	if self.Miniature then
		self.Miniature:Destroy()
		self.Miniature = nil
	end
	self.LoadedMap = nil
	self.LimitHit = false
end

function ENT:AcceptMap()
	local wanted = self:GetMapName()

	self:DropMiniature()
	self.LoadedMap = wanted

	if wanted == "" or self.MapMissing or not PocketMap.NewMiniature then return end

	if PocketMap.RT.IsAtMapLimit() then
		self.LimitHit = true
		return
	end

	self.Miniature = PocketMap.NewMiniature( self, wanted )
end

---@return boolean
function ENT:HasMiniatureFailed()
	return self.Miniature ~= nil and self.Miniature.state == "error"
end

---Picking the map the block already has loads it again.
---@return boolean
function ENT:CanRetryLoad()
	return self:HasMiniatureFailed() or self.LimitHit == true
end

local function loadThumbnail( name )
	local path = "maps/thumb/" .. name .. ".png"
	if name == "" or not file.Exists( path, "GAME" ) then return false end

	local material = Material( path, "smooth" )
	return not material:IsError() and material or false
end

local function isMapInstalled( name )
	return file.Exists( "maps/" .. name .. ".bsp", "GAME" )
end

function ENT:UpdateThumbnail( wanted )
	if wanted == self.ThumbFor then return end

	self.ThumbFor = wanted
	self.Thumb = loadThumbnail( wanted )
end

---Checked when the name changes, and again now and then for a map that was missing (the player may have just subscribed).
function ENT:UpdateMapMissing( wanted )
	local nameChanged = wanted ~= self.MissingCheckedFor
	local recheckDue = self.MapMissing and CurTime() >= ( self.NextMissingCheck or 0 )
	if not nameChanged and not recheckDue then return end

	self.MissingCheckedFor = wanted
	self.NextMissingCheck = CurTime() + MISSING_RECHECK_INTERVAL
	self.MapMissing = wanted ~= "" and not isMapInstalled( wanted )
end

function ENT:IsOwnPickArrived( wanted )
	return self.ExpectedMap == wanted and ( wanted == "" or not self.MapMissing )
end

---A map this client did not pick: the old miniature is not what the block shows any more, so it is dropped and the hint
---asks for E (or says the map is not installed).
function ENT:FollowMapName( wanted )
	if wanted == self.LoadedMap then return end

	if self:IsOwnPickArrived( wanted ) then
		self.ExpectedMap = nil
		self:AcceptMap()
	elseif self.Miniature or self.LoadedMap then
		self:DropMiniature()
	end
end

function ENT:Think()
	local wanted = self:GetMapName()

	self:UpdateThumbnail( wanted )
	self:UpdateMapMissing( wanted )
	self:FollowMapName( wanted )

	self:SetNextClientThink( CurTime() + THINK_INTERVAL )
	return true
end

local function isShadowDepthPass( flags )
	return flags ~= nil and bit.band( flags, STUDIO_SHADOWDEPTHTEXTURE ) ~= 0
end

local function isWaterReflectionPass()
	local target = render.GetRenderTarget()
	return target ~= nil and string.find( target:GetName(), WATER_TARGET_PATTERN ) ~= nil
end

local function shouldSkipDraw( flags )
	return isShadowDepthPass( flags ) or isWaterReflectionPass()
end

local function drawAsGlass( ent, alpha )
	render.SetBlend( alpha )
	ent:DrawModel()
	render.SetBlend( 1 )
end

local function isInHintRange( block )
	return LocalPlayer():EyePos():DistToSqr( block:GetPos() ) <= HINT_RANGE_SQR
end

function ENT:Draw( flags )
	if halo.RenderedEntity() == self then
		self:DrawModel()
		return
	end

	if shouldSkipDraw( flags ) then return end

	local mini = self.Miniature
	if mini and mini.state ~= "error" then mini:Draw( "opaque" ) end
end

function ENT:DrawTranslucent( flags )
	if halo.RenderedEntity() == self then
		self:Draw( flags )
		return
	end

	if shouldSkipDraw( flags ) then return end

	local mini = self.Miniature
	if mini and not self:HasMiniatureFailed() then
		self:DrawLoadedMiniature( mini )
	else
		self:DrawEmptyBlock( mini )
	end
end

function ENT:DrawLoadedMiniature( mini )
	mini:Draw( "translucent" )
	drawAsGlass( self, GLASS_ALPHA_LOADED )
	mini:DrawStatus()
	if mini.state == "ready" then self:DrawPickAnotherMapHint() end
end

---@param failed table? # the miniature, if it failed to load
function ENT:DrawEmptyBlock( failed )
	PocketMap.DrawHologram( self, self.MapMissing or self.LimitHit or failed ~= nil )

	if self:IsMapPending() then self:DrawThumbnail() end

	drawAsGlass( self, GLASS_ALPHA_EMPTY )
	self:DrawHint( failed )
end

function ENT:DrawThumbnail()
	local material = self.Thumb
	if not material or not isInHintRange( self ) then return end

	local center = self:LocalToWorld( ( self.BoxMins + self.BoxMaxs ) / 2 )
	local turn = math.rad( CurTime() * THUMB_SPIN )
	local normal = self:LocalToWorld( Vector( math.sin( turn ), -math.cos( turn ), 0 ) ) - self:GetPos()

	render.SetMaterial( material )
	render.DrawQuadEasy( center, normal, THUMB_SIZE, THUMB_SIZE, color_white, THUMB_ALPHA )
	render.DrawQuadEasy( center, -normal, THUMB_SIZE, THUMB_SIZE, color_white, THUMB_ALPHA )
end

---@return string text
---@return string? detail
---@return table color
function ENT:GetHintText( failed )
	local name = self:GetMapName()

	if failed then
		return "Could not load " .. name, string.sub( tostring( failed.status ), 1, 110 ), COLOR_ERROR
	end
	if self.LimitHit then
		return "Map limit reached (" .. PocketMap.RT.MaxMaps() .. ")", "Remove a map, or raise pocketmap_maxmaps", COLOR_ERROR
	end
	if self.MapMissing then
		return "Map not installed: " .. name, "Subscribe to it, or put maps/" .. name .. ".bsp in your game", COLOR_ERROR
	end
	if self:IsMapPending() then
		return "Press E to load " .. name, nil, COLOR_HINT
	end
	return "Press E to pick a map", nil, COLOR_HINT
end

function ENT:DrawHint( failed )
	if not isInHintRange( self ) then return end

	self:DrawHintText( self:GetHintText( failed ) )
end

function ENT:DrawPickAnotherMapHint()
	local walk = PocketMap.Walk
	if walk and walk.session or not isInHintRange( self ) then return end

	self:DrawHintText( "Press E to pick another map", nil, COLOR_HINT )
end

function ENT:DrawHintText( text, detail, color )
	hintOffset.z = self.BoxMaxs.z + HINT_HEIGHT_ABOVE_BOX
	hintAngle.y = LocalPlayer():EyeAngles().y - 90

	cam.Start3D2D( self:LocalToWorld( hintOffset ), hintAngle, HINT_SCALE )
		draw.SimpleTextOutlined( "Pocket Map", "DermaLarge", 0, 0, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM, 1, color_black )
		draw.SimpleTextOutlined( text, "DermaDefaultBold", 0, 4, color, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, color_black )
		if detail then
			draw.SimpleTextOutlined( detail, "DermaDefault", 0, 22, COLOR_HINT, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, color_black )
		end
	cam.End3D2D()
end
