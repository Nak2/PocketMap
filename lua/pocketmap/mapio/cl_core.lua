-- Hammer inputs and outputs run in source-map coordinates, independently for each walker.
-- BSP records are immutable. A session owns its poses, pending outputs and fire counts.
PocketMap.MapIO = PocketMap.MapIO or {}
local IO = PocketMap.MapIO
local Entities = PocketMap.Entities
local EMPTY = {}
local MAX_EVENTS_PER_STEP = 128
local DEFAULT_MINS, DEFAULT_MAXS = Vector( -16, -16, 0 ), Vector( 16, 16, 72 )

IO.classes = IO.classes or {}
IO.dynamic = IO.dynamic or {}
IO.registrationVersion = IO.registrationVersion or 0

-- Named callbacks replace themselves on auto-refresh without inspecting Lua source paths.
if not IO.stepNames then IO.steps, IO.stepNames = {}, {} end
if not IO.drawNames then IO.draws, IO.drawNames = {}, {} end

local function registerCallback( callbacks, names, name, callback )
	local index = names[name]
	if not index then
		index = #callbacks + 1
		names[name] = index
	end
	callbacks[index] = callback
end

function IO.DynamicClass( class )
	IO.dynamic[class] = true
end

IO.Value = NikNaks.EntityValue or IO.Value

function IO.Number( entity, name, default )
	return tonumber( IO.Value( entity, name ) ) or default
end

function IO.Vector( value )
	if isvector( value ) then return Vector( value.x, value.y, value.z ) end
	if type( value ) ~= "string" then return nil end
	local x, y, z = value:match( "^%s*([%+%-%.%deE]+)%s+([%+%-%.%deE]+)%s+([%+%-%.%deE]+)" )
	if not ( tonumber( x ) and tonumber( y ) and tonumber( z ) ) then return nil end
	return Vector( tonumber( x ), tonumber( y ), tonumber( z ) )
end

function IO.Angle( value )
	if isangle( value ) then return Angle( value.p, value.y, value.r ) end
	local vec = IO.Vector( value )
	return vec and Angle( vec.x, vec.y, vec.z ) or Angle()
end

function IO.Register( class, handlers )
	IO.classes[class] = handlers
	IO.registrationVersion = IO.registrationVersion + 1
end

function IO.OnStep( name, callback )
	registerCallback( IO.steps, IO.stepNames, name, callback )
end

function IO.OnDraw( name, callback )
	registerCallback( IO.draws, IO.drawNames, name, callback )
end

-- Hammer brush movers use a direction and travel distance, not world coordinates.
function IO.Direction( record )
	-- Hammer stores movedir as pitch/yaw/roll. Pitch -90 points upward;
	-- treating those three values as a vector makes vertical doors immobile.
	local value = IO.Value( record.entity, "movedir" )
	if isangle( value ) then return value:Forward() end
	local angles = IO.Vector( value )
	if angles then return Angle( angles.x, angles.y, angles.z ):Forward() end
	local angle = tonumber( IO.Value( record.entity, "angle" ) )
	if angle == -1 then return Vector( 0, 0, 1 ) end
	if angle == -2 then return Vector( 0, 0, -1 ) end
	if angle then return Angle( 0, angle, 0 ):Forward() end
	return record.angles:Forward()
end

-- Source's rotation flags choose Euler components: yaw by default, then roll or pitch.
function IO.AngularDirection( record )
	local flags = IO.Number( record.entity, "spawnflags", 0 )
	local axis = bit.band( flags, 64 ) ~= 0 and Angle( 0, 0, 1 )
		or bit.band( flags, 128 ) ~= 0 and Angle( 1, 0, 0 ) or Angle( 0, 1, 0 )
	return bit.band( flags, 2 ) ~= 0 and axis * -1 or axis
end

function IO.Travel( record, direction )
	if not record.model then return 0 end
	local size = record.model.maxs - record.model.mins
	return math.abs( direction.x ) * size.x + math.abs( direction.y ) * size.y + math.abs( direction.z ) * size.z
end

local function outputs( entity )
	local result = {}
	for key, value in pairs( entity ) do
		if type( key ) == "string" and key:sub( 1, 2 ):lower() == "on" then
			local events = result[key:lower()] or {}
			for _, raw in ipairs( type( value ) == "table" and value or { value } ) do
				local event = NikNaks.ParseEntityOutput( raw )
				if event then
					event.target = string.Trim( event.target ):lower()
					event.input = string.Trim( event.input ):lower()
					events[#events + 1] = event
				end
			end
			result[key:lower()] = events
		end
	end
	return result
end

function IO.Build( mini, entities )
	local world = {
		entities = {}, names = {}, byClass = {}, byEntity = {},
		dynamicModels = {}, solids = {}, useTargets = {},
		registrationVersion = IO.registrationVersion
	}
	local models = mini.bsp:GetBModels()
	local ordered = {}
	for _, entity in pairs( entities ) do ordered[#ordered + 1] = entity end
	table.sort( ordered, function( a, b ) return ( a.index or 0 ) < ( b.index or 0 ) end )
	for _, entity in ipairs( ordered ) do
		local model = IO.Value( entity, "model" )
		local index = type( model ) == "string" and tonumber( model:match( "^%*(%d+)$" ) )
		local record = {
			entity = entity, class = Entities.Class( entity ), name = Entities.Name( entity ), order = #world.entities + 1,
			origin = IO.Vector( IO.Value( entity, "origin" ) ) or Vector(),
			angles = IO.Angle( IO.Value( entity, "angles" ) ), model = index and models[index], modelIndex = index,
			outputs = outputs( entity ), enabled = IO.Number( entity, "StartDisabled", 0 ) ~= 1,
		}
		world.entities[#world.entities + 1] = record
		local handlers = IO.classes[record.class]
		if handlers and handlers.solid then world.solids[#world.solids + 1] = record end
		if handlers and handlers.use then world.useTargets[#world.useTargets + 1] = record end
		world.byEntity[entity] = record
		if index and IO.dynamic[record.class] then world.dynamicModels[index] = record end
		world.byClass[record.class] = world.byClass[record.class] or {}
		world.byClass[record.class][#world.byClass[record.class] + 1] = record
		if record.name then
			world.names[record.name] = world.names[record.name] or {}
			table.insert( world.names[record.name], record )
		end
	end
	mini.mapIO = world
	world.initial = IO.NewSession( mini )
	return world
end

function IO.OfClass( world, class )
	return world.byClass[class] or EMPTY
end

---@class PocketMapIOSession
---@field world table # immutable map records and indexes
---@field records table # record -> session-owned state
---@field queue table # scheduled outputs, ordered by time and sequence
---@field time number

function IO.NewSession( mini )
	if mini.bsp and ( not mini.mapIO or not mini.mapIO.solids or mini.mapIO.registrationVersion ~= IO.registrationVersion ) then
		IO.Build( mini, mini.bsp:GetEntities() )
	end
	local state = {
		mini = mini, world = mini.mapIO, touching = {}, time = 0,
		queue = {}, counts = {}, records = {}
	}
	-- Spawn and collision queries must see authored initial states before the first movement tick.
	for _, record in ipairs( state.world and state.world.entities or EMPTY ) do
		local handlers = IO.classes[record.class]
		if handlers and handlers.initialize then IO.State( state, record ) end
	end
	return state
end

---Obtains writable state. Reads use Position, Rotation and Enabled without allocating.
function IO.State( session, record )
	local state = session.records[record]
	if state then return state end
	state = {
		enabled = record.enabled,
		origin = Vector( record.origin.x, record.origin.y, record.origin.z ),
		angles = Angle( record.angles.p, record.angles.y, record.angles.r ),
	}
	session.records[record] = state
	if record.class == "trigger_teleport" then
		session.teleportMutable = session.teleportMutable or {}
		session.teleportMutable[record] = true
	end
	local handlers = IO.classes[record.class]
	if handlers and handlers.initialize then handlers.initialize( session, record, state ) end
	return state
end

function IO.Enabled( session, record )
	local state = session and session.records[record]
	if state then return state.enabled end
	return record.enabled
end

function IO.Position( session, record )
	local state = session and session.records[record]
	return state and state.origin or record.origin
end

function IO.Rotation( session, record )
	local state = session and session.records[record]
	return state and state.angles or record.angles
end

---Call after changing a session pose, including in-place edits to its vectors or angles.
function IO.PoseChanged( session, record )
	session.traceDirty = session.traceDirty or {}
	session.traceDirty[record] = true
	session.drawRevision = ( session.drawRevision or 0 ) + 1
end

function IO.PlayerHull( session )
	if PocketMap.Movement then return PocketMap.Movement.PlayerHull( LocalPlayer(), session.ducking ) end
	return DEFAULT_MINS, DEFAULT_MAXS
end

function IO.Input( session, target, input, parameter, activator, caller )
	-- Contextual player targets never dispatch inputs to the real host-map player.
	if not target or not target.entity then return end
	input = input:lower()
	session.drawRevision = ( session.drawRevision or 0 ) + 1
	local handlers = IO.classes[target.class]
	local handler = handlers and handlers[input]
	if handler then handler( session, target, parameter, activator, caller ) return end
	if input ~= "enable" and input ~= "disable" and input ~= "toggle" then return end
	local current = IO.State( session, target )
	if input == "enable" then current.enabled = true
	elseif input == "disable" then current.enabled = false
	elseif input == "toggle" then current.enabled = not current.enabled end
end

local function earlier( a, b )
	return a.at < b.at or a.at == b.at and a.sequence < b.sequence
end

-- A stable min-heap only visits due events. Delayed outputs do not shift or scan the queue each tick.
local function enqueue( session, entry )
	session.sequence = ( session.sequence or 0 ) + 1
	entry.sequence = session.sequence
	local queue, index = session.queue, #session.queue + 1
	while index > 1 do
		local parent = math.floor( index / 2 )
		if not earlier( entry, queue[parent] ) then break end
		queue[index], index = queue[parent], parent
	end
	queue[index] = entry
end

local function dequeue( queue )
	local first, last = queue[1], queue[#queue]
	queue[#queue] = nil
	local index, count = 1, #queue
	while index * 2 <= count do
		local child = index * 2
		if child < count and earlier( queue[child + 1], queue[child] ) then child = child + 1 end
		if not earlier( queue[child], last ) then break end
		queue[index], index = queue[child], child
	end
	if count > 0 then queue[index] = last end
	return first
end

function IO.Fire( session, source, name, activator, caller, value )
	for _, event in ipairs( source.outputs[name:lower()] or EMPTY ) do
		local remaining = session.counts[event] or event.remaining
		if remaining ~= 0 then
			if remaining > 0 then session.counts[event] = remaining - 1 end
			enqueue( session, {
				at = session.time + event.delay, event = event, source = source,
				activator = activator, caller = caller or source,
				parameter = event.parameter ~= "" and event.parameter or value or "",
			} )
		end
	end
end

local function dispatch( session, queued )
	local event, targets = queued.event
	if event.target == "!self" then targets = { queued.source }
	elseif event.target == "!caller" then targets = { queued.caller }
	elseif event.target == "!activator" or event.target == "!player" then targets = { queued.activator }
	else targets = session.world.names[event.target] end
	for _, target in ipairs( targets or EMPTY ) do
		IO.Input( session, target, event.input, queued.parameter, queued.activator, queued.caller )
	end
end

function IO.Step( session, dt )
	local state = session.io
	if not state or not state.world then return end
	state.walker, state.activator = session, LocalPlayer()
	state.time = state.time + dt
	if not state.started then
		state.started = true
		for _, record in ipairs( IO.OfClass( state.world, "logic_auto" ) ) do
			IO.Fire( state, record, "OnMapSpawn", state.activator, record )
			IO.Fire( state, record, "OnNewGame", state.activator, record )
		end
	end
	IO.Use( session, state )
	for _, callback in ipairs( IO.steps ) do callback( session, state, dt ) end
	for _ = 1, MAX_EVENTS_PER_STEP do
		local nextEvent = state.queue[1]
		if not nextEvent or nextEvent.at > state.time then break end
		dispatch( state, dequeue( state.queue ) )
	end
end
