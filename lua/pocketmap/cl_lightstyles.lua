-- Light styles. A face has up to 4 lightmaps, one per style: style 0 is always on, 1-11 are the engine's animated patterns, and a
-- light with a name gets a style of 32 or more that the map switches or animates. A pattern is a string with a letter per tenth of a
-- second: 'a' is dark, 'm' is normal, 'z' is twice as bright.

PocketMap = PocketMap or {}
PocketMap.LightStyles = {}
local LightStyles = PocketMap.LightStyles

local FIRST_SWITCHABLE_STYLE = 32
local SPAWNFLAG_STARTS_OFF = 1
local TICKS_PER_SECOND = 10
local LETTER_A = 97
local LETTER_STEPS = 12

local STYLE_PRESETS = {
	[1] = "mmnmmommommnonmmonqnmmo",
	[2] = "abcdefghijklmnopqrstuvwxyzyxwvutsrqponmlkjihgfedcba",
	[3] = "mmmmmaaaaammmmmaaaaaabcdefgabcdefg",
	[4] = "mamamamamama",
	[5] = "jklmnopqrstuvwxyzyxwvutsrqponmlkj",
	[6] = "nmonqnmomnmomomno",
	[7] = "mmmaaaabcdefgmmmmaaaammmaamm",
	[8] = "mmmaaammmaaammmabcdefaaaammmmabcdefmmmaaaa",
	[9] = "aaaaaaaazzzzzzzz",
	[10] = "mmamammmmammamamaaamammma",
	[11] = "abcdefghijklmnopqrrqponmlkjihgfedcba",
}

---@return number # 0 to about 2
local function letterBrightness( letter )
	return ( letter - LETTER_A ) / LETTER_STEPS
end

---The brightness of a pattern, averaged over its length.
local function patternBrightness( pattern )
	if pattern == "" then return 1 end

	local sum = 0
	for i = 1, #pattern do sum = sum + letterBrightness( pattern:byte( i ) ) end
	return sum / #pattern
end

local function changesOverTime( pattern )
	return #pattern > 1 and pattern ~= pattern:sub( 1, 1 ):rep( #pattern )
end

local function lowerCaseKeys( entity )
	local keys = {}
	for key, value in pairs( entity ) do
		if isstring( key ) then keys[key:lower()] = value end
	end
	return keys
end

local function isSwitchableLight( keys )
	local class = tostring( keys.classname or "" ):lower()
	local style = tonumber( keys.style )

	return class:sub( 1, 5 ) == "light" and class ~= "light_dynamic" and style ~= nil and style >= FIRST_SWITCHABLE_STYLE
end

---What a named light does when the map starts (game/server/lights.cpp, CLight::Spawn).
local function startPattern( keys )
	if bit.band( tonumber( keys.spawnflags ) or 0, SPAWNFLAG_STARTS_OFF ) ~= 0 then return "a" end
	if isstring( keys.pattern ) and keys.pattern ~= "" then return keys.pattern:lower() end

	local default = tonumber( keys.defaultstyle )
	return default and STYLE_PRESETS[default] or "m"
end

local function collectPatterns( entities )
	local patterns, owners = {}, {}
	for style, pattern in pairs( STYLE_PRESETS ) do patterns[style] = pattern end

	for _, entity in pairs( entities ) do
		local keys = lowerCaseKeys( entity )
		if isSwitchableLight( keys ) then
			local style = tonumber( keys.style )
			patterns[style] = startPattern( keys )
			owners[style] = entity
		end
	end

	return patterns, owners
end

---@class PocketMapLightStyles
---@field weights table<number, number> # style -> its average brightness, or what the hook said
---@field patterns table<number, string> # style -> pattern, for the styles that change over time
---@field animated table<number, true> # the styles that change over time

---Other addons can fix a style with the PocketMap_LightStyle hook, which stops it from animating:
---hook.Add( "PocketMap_LightStyle", "name", function( mapName, style, weight, entity ) return 0.3 end )
---@param entities table[]
---@param mapName string
---@return PocketMapLightStyles
function LightStyles.Analyze( entities, mapName )
	local patterns, owners = collectPatterns( entities )
	local styles = { weights = {}, patterns = {}, animated = {} }

	for style, pattern in pairs( patterns ) do
		styles.weights[style] = patternBrightness( pattern )

		if changesOverTime( pattern ) then
			styles.patterns[style] = pattern
			styles.animated[style] = true
		end
	end

	for style = 0, 255 do
		local weight = hook.Run( "PocketMap_LightStyle", mapName, style, styles.weights[style] or 1, owners[style] )
		if isnumber( weight ) then
			styles.weights[style] = weight
			styles.animated[style] = nil
		end
	end

	return styles
end

---@return number
function LightStyles.CurrentTick()
	return math.floor( CurTime() * TICKS_PER_SECOND )
end

---@param styles PocketMapLightStyles
---@param tick number # LightStyles.CurrentTick()
---@return number weight
function LightStyles.WeightAtTick( styles, style, tick )
	local pattern = styles.patterns[style]
	if pattern and styles.animated[style] then
		return letterBrightness( pattern:byte( tick % #pattern + 1 ) )
	end

	return styles.weights[style] or ( ( style > 0 and style < FIRST_SWITCHABLE_STYLE ) and 0.5 or 1 )
end

---Every style at its weight in this tick, for an atlas that is about to be written.
---@param styles PocketMapLightStyles
---@return table<number, number>
function LightStyles.WeightsAtTick( styles, tick )
	local weights = table.Copy( styles.weights )
	for style in pairs( styles.animated ) do weights[style] = LightStyles.WeightAtTick( styles, style, tick ) end
	return weights
end
