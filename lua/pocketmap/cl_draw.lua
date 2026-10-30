-- Drawing a loaded map. The engine draws a block in two passes (opaque, translucent), and the views that use the stencil (the
-- sky behind the map, the 3D skybox, the flashlight) can't be split, so they are all drawn in the translucent call.

if not PocketMap.Mini then return end

local Mini = PocketMap.Mini
local Water = PocketMap.Water
local Sky = PocketMap.Sky
local Detail = PocketMap.Detail
local Props = PocketMap.Props

local FLASHLIGHT_STRENGTH = 0.6
local FLASHLIGHT_SIZE = 0.9

local beamTexture

---The beam texture of the flashlight, the cookie the engine projects.
local function getBeamTexture()
	if beamTexture == nil then
		local material = Material( "effects/flashlight001" )
		beamTexture = not material:IsError() and material:GetTexture( "$basetexture" ) or false
	end
	return beamTexture or nil
end

local function activeFlashlightBeam()
	if FLASHLIGHT_STRENGTH <= 0 or not LocalPlayer():FlashlightIsOn() then return nil end
	return getBeamTexture()
end

---Mark every pixel the map draws with 1, to limit the flashlight spot to those.
local function beginStencil()
	render.ClearStencil()
	render.SetStencilEnable( true )
	render.SetStencilWriteMask( 255 )
	render.SetStencilTestMask( 255 )
	render.SetStencilReferenceValue( 1 )
	render.SetStencilCompareFunction( STENCIL_ALWAYS )
	render.SetStencilPassOperation( STENCIL_REPLACE )
	render.SetStencilFailOperation( STENCIL_KEEP )
	render.SetStencilZFailOperation( STENCIL_KEEP )
end

---Multiplied in as dst * ( 1 + beam ): it brightens what is lit instead of adding white.
local function drawFlashlightSpot( beam )
	render.SetStencilCompareFunction( STENCIL_EQUAL )
	render.SetStencilPassOperation( STENCIL_KEEP )

	local size = ScrH() * FLASHLIGHT_SIZE
	cam.Start2D()
		render.OverrideBlend( true, BLEND_DST_COLOR, BLEND_ONE, BLENDFUNC_ADD )
		render.SetColorModulation( FLASHLIGHT_STRENGTH, FLASHLIGHT_STRENGTH, FLASHLIGHT_STRENGTH )
		render.DrawTextureToScreenRect( beam, ScrW() / 2 - size / 2, ScrH() / 2 - size / 2, size, size )
		render.SetColorModulation( 1, 1, 1 )
		render.OverrideBlend( false )
	cam.End2D()
end

---Without an atlas the map is drawn fullbright.
local function drawOptions( mini )
	local options = mini.drawOptions
	if options and options.lightmap == mini.lightmapTexture then return options end

	options = { light = false, lightmap = mini.lightmapTexture, fullbright = mini.lightmapTexture == nil }
	mini.drawOptions = options
	return options
end

---The reflection and refraction of the water are a second and third draw of the map, so they only get the opaque world:
---no props, plants or glass, which is most of the cost of a draw.
---@param pass "opaque"|"translucent"|nil # nil draws both halves
local function drawContents( mini, options, pass )
	local matrix, objects = mini.matrix, mini.objects
	local lite = Water.pass ~= nil
	local doOpaque, doTranslucent = pass ~= "translucent", pass ~= "opaque" and not lite

	if doOpaque then
		for i = 1, #objects do objects[i]:DrawOpaque( matrix, options ) end
		Water.Draw( mini )

		if not lite then
			if not Detail.Blends( mini ) then Detail.Draw( mini ) end
			Props.Draw( mini, "opaque" )
		end
	end

	if doTranslucent then
		Props.Draw( mini, "translucent" )

		-- A blended sprite sheet must not write depth, or the sprites would cut out what is behind them
		if Detail.Blends( mini ) then
			render.OverrideDepthEnable( true, false )
			Detail.Draw( mini )
			render.OverrideDepthEnable( true, true )
		end

		for i = 1, #objects do objects[i]:DrawTranslucent( matrix, options ) end
		render.OverrideDepthEnable( true, true )
	end
end

function Mini:WaterDrawOptions()
	return drawOptions( self )
end

---The whole tiny map, both halves and no sky, in the current 3D view. The refraction and the reflection of the water use it.
function Mini:DrawScene( options )
	self:UpdateMatrix()
	render.OverrideDepthEnable( true, true )
	drawContents( self, options, nil )
	render.OverrideDepthEnable( false )
end

---@param pass "opaque"|"translucent"|nil
function Mini:Draw( pass )
	if self.state == "removed" or not self.scaleVec then return end
	if #self.objects == 0 and #self.propGroups == 0 and #self.detailMeshes == 0 then return end

	self:UpdateMatrix()

	local onScreen = not render.GetRenderTarget()
	if self.waterPlanes and #self.waterPlanes > 0 and onScreen then Water.Calibrate() end

	local options = drawOptions( self )
	local flashlight = activeFlashlightBeam()
	local sky = #self.skyObjects > 0 and onScreen and self:EyeInside()
	local backdrop = self.skyBackdrop ~= nil and onScreen

	local usesStencil = flashlight or sky or backdrop
	if usesStencil and pass == "opaque" then return end
	if usesStencil then
		pass = nil
		beginStencil()
	end

	if backdrop then Sky.DrawBackdrop( self ) end
	if sky then Sky.Draw3D( self, options ) end

	render.OverrideDepthEnable( true, true )
	drawContents( self, options, pass )
	render.OverrideDepthEnable( false )

	if flashlight then drawFlashlightSpot( flashlight ) end
	if usesStencil then render.SetStencilEnable( false ) end
end
