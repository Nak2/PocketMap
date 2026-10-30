
-- ** IMPORTANT ** NEVER MAKE AN RT OUTSIDE OF THIS SYSTEM, THIS IS FOR MAKING AND CLEARING RTS
--
-- Render targets can't be freed, and GetRenderTargetEx gives back the same one for a name that exists. So a target is
-- never named after a map or a block: it is named after what it IS (size, format, depth, flags) and a slot number.
-- Whoever needs one acquires it and releases it when done. A released target is the next one handed out for the same
-- spec, so the number of targets is the most that were in use at once, not the number of maps that were loaded.
--
--   local rt = PocketMap.RT.Acquire( 2048, 1024, { float = true } )
--   PocketMap.RT.Clear( rt, 0, 0, 0, 255 )
--   ...
--   PocketMap.RT.Release( rt )

PocketMap = PocketMap or {}
PocketMap.RT = PocketMap.RT or {}
local RT = PocketMap.RT

---@class PocketMapRTSpec
---@field float boolean? # RGBA16161616F instead of RGBA8888
---@field depth boolean? # a depth buffer of its own
---@field flags number? # texture flags

local NAME_PREFIX = "PocketMap_RT_"

-- Targets stay in memory for the whole session, so the number of maps is limited, and so is the memory they may use.
local cvMaxMaps = CreateClientConVar( "pocketmap_maxmaps", "5", true, false, "Most maps that can be loaded at once. Each needs a lightmap texture of up to 64 MB of video memory.", 1, 32 )

local ATLAS_MEGABYTES = 64
local WATER_MEGABYTES = 40

---@return number
function RT.MaxMaps()
	return cvMaxMaps:GetInt()
end

---One atlas per map, and the targets of the water.
---@return number
function RT.BudgetMegabytes()
	return RT.MaxMaps() * ATLAS_MEGABYTES + WATER_MEGABYTES
end

---A map that failed to load holds nothing.
---@return boolean
function RT.IsAtMapLimit()
	local loaded = 0
	for mini in pairs( PocketMap.Active or {} ) do
		if mini.state ~= "error" then loaded = loaded + 1 end
	end
	return loaded >= RT.MaxMaps()
end

local acquiredSlot = {} -- rt -> { key, slot }, only while the rt is acquired
local freeSlots = {}    -- key -> stack of slots that were released
local slotCount = {}    -- key -> slots made so far
local usedMegabytes = 0

---@return string
local function specKey( width, height, spec )
	return string.format( "%s%s%d_%dx%d", spec.float and "f" or "b", spec.depth and "d" or "n", spec.flags or 0, width, height )
end

local function takeSlot( key )
	local free = freeSlots[key]
	if free and #free > 0 then return table.remove( free ) end

	slotCount[key] = ( slotCount[key] or 0 ) + 1
	return slotCount[key]
end

local function giveSlotBack( key, slot )
	freeSlots[key] = freeSlots[key] or {}
	freeSlots[key][#freeSlots[key] + 1] = slot
end

local function createTarget( key, slot, width, height, spec )
	local format = spec.float and IMAGE_FORMAT_RGBA16161616F or IMAGE_FORMAT_RGBA8888
	local depth = spec.depth and MATERIAL_RT_DEPTH_SEPARATE or MATERIAL_RT_DEPTH_NONE

	return GetRenderTargetEx( NAME_PREFIX .. key .. "_" .. slot, width, height, RT_SIZE_LITERAL, depth, spec.flags or 0, 0, format )
end

---Color is 4 bytes a pixel, 8 for float, plus 4 for a depth buffer. An estimate: the card may pad.
local function megabytesOf( width, height, float, depth )
	local bytes = ( float and 8 or 4 ) + ( depth and 4 or 0 )
	return width * height * bytes / 1024 / 1024
end

local function hasFreeSlot( key )
	return freeSlots[key] ~= nil and #freeSlots[key] > 0
end

---Reusing a released target costs nothing. A new one must fit in the budget.
local function fitsBudget( key, width, height, spec )
	return hasFreeSlot( key ) or usedMegabytes + megabytesOf( width, height, spec.float, spec.depth ) <= RT.BudgetMegabytes()
end

---Hands out a target of this size and spec. It holds whatever the last user left in it: clear it if that matters.
---@param width number
---@param height number
---@param spec PocketMapRTSpec?
---@return ITexture? rt # nil if the memory budget is used up, or the card can't make it (a float target on an old card)
function RT.Acquire( width, height, spec )
	spec = spec or {}

	local key = specKey( width, height, spec )
	if not fitsBudget( key, width, height, spec ) then return nil end

	local reused = hasFreeSlot( key )
	local slot = takeSlot( key )
	local rt = createTarget( key, slot, width, height, spec )

	if not rt then
		giveSlotBack( key, slot )
		return nil
	end

	if not reused then usedMegabytes = usedMegabytes + megabytesOf( width, height, spec.float, spec.depth ) end
	acquiredSlot[rt] = { key = key, slot = slot }
	return rt
end

---Gives a target back. It stays in memory and is handed out again by the next Acquire of the same spec.
---@param rt ITexture?
function RT.Release( rt )
	local held = rt and acquiredSlot[rt]
	if not held then return end

	acquiredSlot[rt] = nil
	giveSlotBack( held.key, held.slot )
end

---@param rt ITexture
---@param clearDepth boolean? # needs the depth buffer of the spec
function RT.Clear( rt, r, g, b, a, clearDepth )
	render.PushRenderTarget( rt )
	render.Clear( r or 0, g or 0, b or 0, a or 0, clearDepth or false, clearDepth or false )
	render.PopRenderTarget()
end

---@return number made # targets that exist
---@return number inUse # targets that are acquired right now
function RT.Count()
	local made, inUse = 0, 0
	for _, count in pairs( slotCount ) do made = made + count end
	for _ in pairs( acquiredSlot ) do inUse = inUse + 1 end
	return made, inUse
end

concommand.Add( "pocketmap_rtinfo", function()
	local made, inUse = RT.Count()
	print( ( "[PocketMap] %d render targets made, %d in use, about %.0f of %d MB, up to %d maps" ):format( made, inUse, usedMegabytes, RT.BudgetMegabytes(), RT.MaxMaps() ) )

	for key, count in SortedPairs( slotCount ) do
		local float, depth, _, width, height = key:match( "^(%a)(%a)(%d+)_(%d+)x(%d+)$" )
		local megabytes = count * megabytesOf( tonumber( width ), tonumber( height ), float == "f", depth == "d" )
		print( ( "           %s: %d made, %d free, about %.0f MB" ):format( key, count, freeSlots[key] and #freeSlots[key] or 0, megabytes ) )
	end
end )

-- Users: the lightmap atlas (cl_atlas.lua, one per loaded map) and the water (cl_water.lua, a reflection and a refraction
-- per water height of a block, and a tiny flat pair per fog color).
