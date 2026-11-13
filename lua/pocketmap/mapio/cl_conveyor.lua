-- Conveyors carry a grounded walker without moving real Source entities.
local IO = PocketMap.MapIO
local NOT_SOLID, VISUAL_ONLY = 2, 1

local function setup( state, record )
	local current = IO.State( state, record )
	if not current.conveyor then
		current.conveyor = { direction = IO.Direction( record ), speed = IO.Number( record.entity, "speed", 100 ) }
	end
	return current.conveyor
end

IO.Register( "func_conveyor", {
	solid = function( _, record ) return bit.band( IO.Number( record.entity, "spawnflags", 0 ), NOT_SOLID ) == 0 end,
	setspeed = function( state, record, value )
		local speed = tonumber( value )
		if speed then setup( state, record ).speed = speed end
	end,
	start = function( state, record ) IO.State( state, record ).enabled = true end,
	stop = function( state, record ) IO.State( state, record ).enabled = false end,
} )

IO.OnStep( "Conveyors", function( session, state, dt )
	if session.noclip or not session.onground then return end
	local mins, maxs = IO.PlayerHull( session )
	for _, record in ipairs( IO.OfClass( state.world, "func_conveyor" ) ) do
		local flags = IO.Number( record.entity, "spawnflags", 0 )
		local conveyor = setup( state, record )
		local lo, hi = IO.Bounds( record, state )
		local move = session.move
		local touching = lo and bit.band( flags, VISUAL_ONLY + NOT_SOLID ) == 0
			and IO.Overlaps( session, record, mins, maxs )
			and math.abs( move.origin.z + mins.z - hi.z ) <= 2
		if touching and IO.Enabled( state, record ) and conveyor.speed ~= 0 then
			local nextPos = move.origin + conveyor.direction * ( conveyor.speed * dt )
			local trace = session:TraceHull( move.origin, nextPos, mins, maxs )
			move.origin = move.origin + ( nextPos - move.origin ) * trace.Fraction
		end
	end
end )
