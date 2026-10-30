-- Redraws the faces lit by an animated light style. Styles change at 10 Hz, and only the block the player is inside of is kept up to date.

if not PocketMap.Mini then return end

local LightStyles = PocketMap.LightStyles

local FACES_PER_FRAME = 64

local tick = 0

local function weightsOf( mini )
	mini.styleWeights = mini.styleWeights or function( style )
		return LightStyles.WeightAtTick( mini.lightStyles, style, tick )
	end
	return mini.styleWeights
end

hook.Add( "Think", "PocketMap_LightStyles", function()
	tick = LightStyles.CurrentTick()

	for mini in pairs( PocketMap.Active ) do
		if mini.atlasObject and mini.state == "ready" and IsValid( mini.ent ) and mini:EyeInside() then
			mini.atlasObject:Update( weightsOf( mini ), FACES_PER_FRAME )
		end
	end
end )
