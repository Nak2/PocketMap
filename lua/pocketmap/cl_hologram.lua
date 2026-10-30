-- The hologram that fills a block with no tiny map: blue when idle, red when this client doesn't have the map.
-- Only the point arrays and the vectors below are reused between frames, so it makes no garbage of its own.

PocketMap = PocketMap or {}

local DISTANCE_SQR = 1800 * 1800
local GRID = 14
local GRID_HALF = 150
local MOTES = 16
local CORNER_ARM = 38
local BROKEN_SHARE = 0.22
local GLITCH_DIM = 0.25
local BACKDROP_COLOR = Color( 0, 0, 0, 20 )

local pointX, pointY, pointZ, pointLight = {}, {}, {}, {}

local lineFrom, lineTo = Vector(), Vector()
local moteLocal = Vector()
local lineColor = Color( 255, 255, 255, 255 )
local glowMaterial

local function hillHeight( x, y, t )
	return 24 * math.sin( x * 0.03 + t * 1.2 ) + 18 * math.sin( y * 0.04 - t * 0.9 ) + 12 * math.sin( ( x + y ) * 0.05 + t * 1.6 )
end

---@param light number # 0 - 1: bright in the middle and where the scanner is
local function setLineColor( light, alpha, missing )
	local glow = 40 + 215 * light * light

	if missing then
		lineColor.r, lineColor.g, lineColor.b = 255, glow, glow
	else
		lineColor.r, lineColor.g, lineColor.b = glow, 160 + 95 * light, 255
	end
	lineColor.a = alpha
end

local function line( ax, ay, az, bx, by, bz )
	lineFrom:SetUnpacked( ax, ay, az )
	lineTo:SetUnpacked( bx, by, bz )
	render.DrawLine( lineFrom, lineTo, lineColor, false )
end

---@return boolean # whether the picture is dimmed right now (missing style only)
local function isGlitching( t, missing )
	return missing and math.sin( t * 13 ) * math.sin( t * 5.3 ) > 0.8
end

local function fillLandscapePoints( t, cx, cy, floorZ )
	local turn = t * 0.3
	local cosT, sinT = math.cos( turn ), math.sin( turn )
	local scan = ( ( t * 0.45 ) % 1 ) * ( GRID_HALF * 2.6 ) - GRID_HALF * 1.3
	local step = GRID_HALF * 2 / GRID
	local stride = GRID + 1

	for i = 0, GRID do
		for j = 0, GRID do
			local gx, gy = -GRID_HALF + i * step, -GRID_HALF + j * step
			local at = i * stride + j + 1
			pointX[at] = cx + gx * cosT - gy * sinT
			pointY[at] = cy + gx * sinT + gy * cosT
			pointZ[at] = floorZ + hillHeight( gx, gy, t )

			local edge = math.max( 0, 1 - math.sqrt( gx * gx + gy * gy ) / ( GRID_HALF * 1.25 ) )
			local band = math.max( 0, 1 - math.abs( gx - scan ) / 28 )
			pointLight[at] = math.min( 1, 0.25 + 0.55 * edge + band )
		end
	end
end

---A line that has come loose: its middle leaves its place in a direction of its own, fades, and starts over.
local function drawLooseLine( a, b, t, h, glitch, alpha )
	local ax, ay, az, bx, by, bz = pointX[a], pointY[a], pointZ[a], pointX[b], pointY[b], pointZ[b]
	local phase = ( t * 0.3 + h * 40 ) % 1
	local dx, dy, dz = math.sin( h * 311 ) * 70 * phase, math.cos( h * 173 ) * 70 * phase, ( 25 + h * 120 ) * phase

	local x0, y0, z0 = ax + ( bx - ax ) * 0.3, ay + ( by - ay ) * 0.3, az + ( bz - az ) * 0.3
	local x1, y1, z1 = ax + ( bx - ax ) * 0.7, ay + ( by - ay ) * 0.7, az + ( bz - az ) * 0.7

	lineColor.r, lineColor.g, lineColor.b = 255, 235, 225
	lineColor.a = math.max( alpha, 160 * glitch ) * ( 1 - phase )
	line( x0 + dx, y0 + dy, z0 + dz, x1 + dx, y1 + dy, z1 + dz )
end

---@return number # the same 0 - 1 for the same line every frame
local function lineSeed( a, b )
	return ( ( a * 73 + b * 151 ) % 97 ) / 97
end

local function landscapeAlpha( light, glitch, missing )
	local base, range = 30, 225
	if missing then base, range = 90, 165 end
	return ( base + range * light ) * glitch
end

---@param a number # index of the first point
---@param b number # index of the second
local function drawLandscapeLine( a, b, t, glitch, missing )
	local light = ( pointLight[a] + pointLight[b] ) * 0.5
	local alpha = landscapeAlpha( light, glitch, missing )

	if missing then
		local seed = lineSeed( a, b )
		if seed < BROKEN_SHARE then
			drawLooseLine( a, b, t, seed, glitch, alpha )
			return
		end
	end

	setLineColor( light, alpha, missing )
	line( pointX[a], pointY[a], pointZ[a], pointX[b], pointY[b], pointZ[b] )
end

local function drawLandscape( t, glitch, missing )
	local stride = GRID + 1

	for i = 0, GRID do
		for j = 0, GRID - 1 do
			drawLandscapeLine( i * stride + j + 1, i * stride + j + 2, t, glitch, missing )
			drawLandscapeLine( j * stride + i + 1, ( j + 1 ) * stride + i + 1, t, glitch, missing )
		end
	end
end

---Drawn inside out (culling reversed) so only the inner faces show, like the walls of a dark room.
local function drawBackdrop( mins, maxs )
	render.CullMode( MATERIAL_CULLMODE_CW )
	render.DrawBox( vector_origin, angle_zero, mins, maxs, BACKDROP_COLOR, false )
	render.CullMode( MATERIAL_CULLMODE_CCW )
end

local function setCornerColor( t, glitch, missing )
	if missing then
		lineColor.r, lineColor.g, lineColor.b = 255, 215, 205
	else
		lineColor.r, lineColor.g, lineColor.b = 120, 220, 255
	end

	local pulse = 0.55 + 0.45 * math.sin( t * 2.2 )
	lineColor.a = ( 90 + 150 * pulse ) * glitch
end

local function drawCornerArms( x, y, z, sx, sy, sz )
	line( x, y, z, x - sx * CORNER_ARM, y, z )
	line( x, y, z, x, y - sy * CORNER_ARM, z )
	line( x, y, z, x, y, z - sz * CORNER_ARM )
end

local function drawCorners( t, mins, maxs, cx, cy, glitch, missing )
	local hx, hy, hz = ( maxs.x - mins.x ) / 2 * 0.92, ( maxs.y - mins.y ) / 2 * 0.92, ( maxs.z - mins.z ) / 2 * 0.96
	local cz = ( mins.z + maxs.z ) / 2
	setCornerColor( t, glitch, missing )

	local corner = 0
	for sx = -1, 1, 2 do
		for sy = -1, 1, 2 do
			for sz = -1, 1, 2 do
				corner = corner + 1
				local flickersOut = missing and math.sin( t * 5 + corner * 2.3 ) > 0.8
				if not flickersOut then drawCornerArms( cx + sx * hx, cy + sy * hy, cz + sz * hz, sx, sy, sz ) end
			end
		end
	end
end

local function setMoteColor( k, fade, glitch, missing )
	if not missing then
		lineColor.r, lineColor.g, lineColor.b = 140, 230, 255
	elseif k % 2 == 0 then
		lineColor.r, lineColor.g, lineColor.b = 255, 80, 60
	else
		lineColor.r, lineColor.g, lineColor.b = 255, 235, 225
	end
	lineColor.a = 255 * fade * glitch
end

---Motes of light rise out of the landscape and fade near the top. They are spread by the golden angle.
local function drawMotes( ent, t, cx, cy, floorZ, maxsZ, glitch, missing )
	glowMaterial = glowMaterial or Material( "sprites/light_glow02_add" )
	render.SetMaterial( glowMaterial )

	local height = maxsZ - floorZ - 30
	for k = 1, MOTES do
		local rise = ( ( t * ( 14 + k * 1.3 ) + k * 41 ) % height ) / height
		local angle = k * 2.399 + t * ( 0.25 + 0.03 * k )
		local radius = 30 + ( k * 17 ) % ( GRID_HALF - 20 )
		local fade = math.sin( rise * math.pi )

		moteLocal:SetUnpacked( cx + math.cos( angle ) * radius, cy + math.sin( angle ) * radius, floorZ + 20 + rise * height )
		setMoteColor( k, fade, glitch, missing )
		render.DrawSprite( ent:LocalToWorld( moteLocal ), 10 + 8 * fade, 10 + 8 * fade, lineColor )
	end
end

---@param ent Entity # the block
---@param missing boolean? # true = the red style: the map of the block is not on this client
function PocketMap.DrawHologram( ent, missing )
	if EyePos():DistToSqr( ent:GetPos() ) > DISTANCE_SQR then return end

	local t = CurTime()
	local mins, maxs = ent.BoxMins, ent.BoxMaxs
	local cx, cy = ( mins.x + maxs.x ) / 2, ( mins.y + maxs.y ) / 2
	local floorZ = mins.z + ( maxs.z - mins.z ) * 0.28
	local glitch = isGlitching( t, missing ) and GLITCH_DIM or 1

	fillLandscapePoints( t, cx, cy, floorZ )

	cam.PushModelMatrix( ent:GetWorldTransformMatrix() )
	render.SetColorMaterial()
	drawBackdrop( mins, maxs )
	drawLandscape( t, glitch, missing )
	drawCorners( t, mins, maxs, cx, cy, glitch, missing )
	cam.PopModelMatrix()

	drawMotes( ent, t, cx, cy, floorZ, maxs.z, glitch, missing )
end
