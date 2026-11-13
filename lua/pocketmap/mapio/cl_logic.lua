-- Common map-start and relay wiring. Entity simulation never invokes host-map inputs.
local IO = PocketMap.MapIO
local REMOVE_ON_FIRE, ALLOW_FAST_RETRIGGER = 1, 2

IO.Register( "logic_auto", {} )
IO.Register( "logic_relay", {
	trigger = function( state, record, value, activator )
		if not IO.Enabled( state, record ) then return end
		local current = IO.State( state, record )
		local flags = IO.Number( record.entity, "spawnflags", 0 )
		if bit.band( flags, ALLOW_FAST_RETRIGGER ) == 0 and ( current.readyAt or -1 ) >= state.time then return end
		local delay = 0
		for _, event in ipairs( record.outputs.ontrigger or {} ) do delay = math.max( delay, event.delay ) end
		current.readyAt = state.time + delay
		IO.Fire( state, record, "OnTrigger", activator, record, value )
		if bit.band( flags, REMOVE_ON_FIRE ) ~= 0 then current.enabled = false end
	end,
	enablerefire = function( state, record ) IO.State( state, record ).readyAt = nil end,
} )
