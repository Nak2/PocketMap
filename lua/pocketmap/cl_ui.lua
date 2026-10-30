PocketMap = PocketMap or {}

local DEFAULT_GROUP = "Half-Life 2"
local FAVOURITES_GROUP = "Favourites"
local TILE_W, TILE_H = 150, 140
local HEADER_H = 28
local SPACING = 6
local TOP_BAR_H = 28
local FRAME_MARGIN = 100
local FRAME_MAX_W, FRAME_MAX_H = 1000, 700
local SCROLL_AND_BORDER_W = 48
local SETTING_BOX_MARGIN = 6

local COLOR_BOX = Color( 55, 60, 72 )
local COLOR_HEADER_HOVER = Color( 70, 80, 100 )
local COLOR_TILE = Color( 45, 45, 50 )
local COLOR_TILE_CURRENT = Color( 60, 130, 80 )
local COLOR_TILE_HOVER = Color( 70, 110, 160 )
local COLOR_NO_ICON = Color( 120, 120, 120 )

local SETTINGS = {
	{
		text = "Baked Models", width = 130, conVar = "pocketmap_propmeshes", default = false, reloadsMap = true,
		tooltip = "On: the meshes of the models are baked into the tiny map when it loads.\nOff: every model is drawn as a model of its own (ClientsideModel). Slower with many props, but the engine lights and draws them. (Models that only work as static props are baked either way.)\nThe map of this block is loaded again when you change it.",
	},
	{
		text = "Light Toggles", width = 120, conVar = "pocketmap_lighttoggle", default = true, reloadsMap = true,
		tooltip = "On: the lights that can be switched (a light with a name, like the sun of gm_construct) and the animated lights are part of the light of the map and of its props.\nOff: only the first lightmap of every face is used.\nThe map of this block is loaded again when you change it.",
	},
	{
		text = "Update Water", width = 120, conVar = "pocketmap_water", default = false, reloadsMap = false,
		tooltip = "On: the water reflects and refracts the tiny map. Costs a lot of FPS: the map is drawn two more times a frame (only while you are inside the block).\nOff: the water is a flat surface.",
	},
}

local function sendSelection( ent, name )
	-- The server sees no change when the block already has this map, so a failed load is retried here
	if name ~= "" and name == ent:GetMapName() and ent:CanRetryLoad() then
		ent:AcceptMap()
	end

	ent.ExpectedMap = name
	net.Start( "PocketMap_Select" )
		net.WriteEntity( ent )
		net.WriteString( name )
	net.SendToServer()
end

local function reloadMapOfBlock( ent )
	if not IsValid( ent ) then return end

	local map = ent:GetMapName()
	if map == "" or ent.LoadedMap ~= map then return end

	timer.Simple( 0, function()
		if IsValid( ent ) then ent:AcceptMap() end
	end )
end

local function listInstalledMaps()
	local maps = {}
	for _, fileName in ipairs( file.Find( "maps/*.bsp", "GAME" ) ) do
		maps[#maps + 1] = string.StripExtension( fileName )
	end
	table.sort( maps )
	return maps
end

---@return table<string, string> # lowercase map name -> material path
local function findIcons()
	local icons = {}
	for _, fileName in ipairs( file.Find( "maps/thumb/*.png", "GAME" ) or {} ) do
		icons[string.lower( string.StripExtension( fileName ) )] = "maps/thumb/" .. fileName
	end
	return icons
end

---A map that is in two groups counts once, and Favourites is only a second view of maps that are listed elsewhere.
local function countListedMaps( order, byName )
	local listed = {}
	for _, group in ipairs( order ) do
		if group ~= FAVOURITES_GROUP then
			for _, name in ipairs( byName[group] ) do listed[name] = true end
		end
	end
	return table.Count( listed )
end

local function paintBox( _, w, h )
	draw.RoundedBox( 4, 0, 0, w, h, COLOR_BOX )
end

local function createFrame()
	local frame = vgui.Create( "DFrame" )
	frame:SetTitle( "Pocket Map - Map Browser" )
	frame:SetSize( math.min( ScrW() - FRAME_MARGIN, FRAME_MAX_W ), math.min( ScrH() - FRAME_MARGIN, FRAME_MAX_H ) )
	frame:Center()
	frame:MakePopup()
	return frame
end

local function createTopBar( frame )
	local top = vgui.Create( "DPanel", frame )
	top:Dock( TOP )
	top:SetTall( TOP_BAR_H )
	top:DockMargin( 0, 0, 0, SPACING )
	top.Paint = nil
	return top
end

local function addEmptyButton( top, onClick )
	local button = vgui.Create( "DButton", top )
	button:Dock( RIGHT )
	button:SetWide( 110 )
	button:SetText( "Empty the block" )
	button.DoClick = onClick
end

local function addSettingBox( top, setting, ent )
	local box = vgui.Create( "DPanel", top )
	box:Dock( RIGHT )
	box:DockMargin( 0, 0, SETTING_BOX_MARGIN, 0 )
	box:SetWide( setting.width )
	box.Paint = paintBox

	local conVar = GetConVar( setting.conVar )

	local checkbox = vgui.Create( "DCheckBoxLabel", box )
	checkbox:SetPos( 8, 6 )
	checkbox:SetText( setting.text )
	checkbox:SetTextColor( color_white )
	checkbox:SetTooltip( setting.tooltip )
	checkbox:SizeToContents()
	checkbox:SetValue( conVar and conVar:GetBool() or ( conVar == nil and setting.default ) )
	checkbox.OnChange = function( _, value )
		RunConsoleCommand( setting.conVar, value and "1" or "0" )
		if setting.reloadsMap then reloadMapOfBlock( ent ) end
	end
end

local function addFilterEntry( top, listedCount )
	local filter = vgui.Create( "DTextEntry", top )
	filter:Dock( FILL )
	filter:SetPlaceholderText( "Search " .. listedCount .. " maps" )
	return filter
end

local function paintGroupHeader( group, header, w, h )
	local color = header:IsHovered() and COLOR_HEADER_HOVER or COLOR_BOX
	draw.RoundedBox( 4, 0, 0, w, h, color )
	draw.SimpleText( group.open and "v" or ">", "DermaDefaultBold", 14, h / 2, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
	draw.SimpleText( group.name .. "  (" .. group.matches .. ")", "DermaDefaultBold", 28, h / 2, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
end

local function tileColor( tile, isCurrent )
	if tile:IsHovered() then return COLOR_TILE_HOVER end
	return isCurrent and COLOR_TILE_CURRENT or COLOR_TILE
end

local function loadTileIcon( tile, icons )
	local path = icons[tile.LowerName]
	tile.Icon = path and Material( path ) or false
end

local function paintTile( tile, w, h, icons, isCurrent )
	draw.RoundedBox( 4, 0, 0, w, h, tileColor( tile, isCurrent ) )

	if tile.Icon == nil then loadTileIcon( tile, icons ) end

	if tile.Icon then
		surface.SetMaterial( tile.Icon )
		surface.SetDrawColor( 255, 255, 255 )
		surface.DrawTexturedRect( 5, 5, w - 10, h - 34 )
	else
		draw.SimpleText( "no icon", "DermaDefault", w / 2, ( h - 24 ) / 2, COLOR_NO_ICON, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
	end

	draw.SimpleText( tile.MapName, "DermaDefault", w / 2, h - 16, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
end

local function createTile( container, name, icons, isCurrent, onPick )
	local tile = vgui.Create( "DButton", container )
	tile:SetSize( TILE_W, TILE_H )
	tile:SetText( "" )
	tile:SetVisible( false )
	tile.MapName = name
	tile.LowerName = string.lower( name )
	tile.DoClick = function() onPick( name ) end
	tile.Paint = function( self, w, h ) paintTile( self, w, h, icons, isCurrent ) end
	return tile
end

---@return table group # { name, header, tiles, matches, expanded, open }
local function createGroup( container, rowWidth, groupName, names, icons, current, onPick, onToggle )
	local group = { name = groupName, tiles = {}, matches = #names, expanded = false }

	local header = vgui.Create( "DButton", container )
	header:SetSize( rowWidth, HEADER_H )
	header:SetText( "" )
	header.DoClick = function()
		group.expanded = not group.expanded
		onToggle()
	end
	header.Paint = function( self, w, h ) paintGroupHeader( group, self, w, h ) end
	group.header = header

	for _, name in ipairs( names ) do
		local isCurrent = name == current
		group.tiles[#group.tiles + 1] = createTile( container, name, icons, isCurrent, onPick )
		if isCurrent then group.expanded = true end
	end

	return group
end

local function hasExpandedGroup( groups )
	for _, group in ipairs( groups ) do
		if group.expanded then return true end
	end
	return false
end

---The group of the current map is open already; without one, Half-Life 2 (or the first group) is.
local function expandDefaultGroup( groups )
	if hasExpandedGroup( groups ) then return end

	local default = groups[1]
	for _, group in ipairs( groups ) do
		if group.name == DEFAULT_GROUP then default = group break end
	end
	if default then default.expanded = true end
end

---Places the visible headers and tiles top to bottom, and returns the height they take.
local function layoutGroups( groups, rowWidth )
	local x, y = 0, 0

	for _, group in ipairs( groups ) do
		if group.header:IsVisible() then
			group.header:SetPos( 0, y )
			y = y + HEADER_H + SPACING

			x = 0
			for _, tile in ipairs( group.tiles ) do
				if tile:IsVisible() then
					if x > 0 and x + TILE_W > rowWidth then
						x = 0
						y = y + TILE_H + SPACING
					end
					tile:SetPos( x, y )
					x = x + TILE_W + SPACING
				end
			end

			if x > 0 then y = y + TILE_H + SPACING end
		end
	end

	return y
end

local function countMatches( group, text )
	local matches = 0
	for _, tile in ipairs( group.tiles ) do
		tile.Match = text == "" or string.find( tile.LowerName, text, 1, true ) ~= nil
		if tile.Match then matches = matches + 1 end
	end
	return matches
end

---A group with no match is hidden. A search opens the groups that have one.
local function applyFilterToGroup( group, text )
	group.matches = countMatches( group, text )
	group.open = group.expanded or ( text ~= "" and group.matches > 0 )
	group.header:SetVisible( group.matches > 0 )

	for _, tile in ipairs( group.tiles ) do
		tile:SetVisible( group.open and tile.Match )
	end
end

---@return fun( text: string ) # shows the maps that match the text
local function createMapList( frame, order, byName, icons, current, onPick )
	local scroll = vgui.Create( "DScrollPanel", frame )
	scroll:Dock( FILL )

	local container = scroll:Add( "DPanel" )
	container:Dock( TOP )
	container.Paint = nil

	local rowWidth = frame:GetWide() - SCROLL_AND_BORDER_W
	local groups = {}
	local filterText = ""

	local function refresh()
		for _, group in ipairs( groups ) do applyFilterToGroup( group, filterText ) end

		container:SetTall( layoutGroups( groups, rowWidth ) )
		container:InvalidateLayout( true )
		scroll:InvalidateLayout( true )
	end

	for _, groupName in ipairs( order ) do
		groups[#groups + 1] = createGroup( container, rowWidth, groupName, byName[groupName], icons, current, onPick, refresh )
	end
	expandDefaultGroup( groups )
	refresh()

	return function( text )
		filterText = string.lower( text )
		refresh()
	end
end

function PocketMap.OpenMenu( ent )
	if IsValid( PocketMap.Menu ) then PocketMap.Menu:Remove() end

	local order, byName = PocketMap.GroupMaps( listInstalledMaps() )

	local frame = createFrame()
	PocketMap.Menu = frame

	local function pick( name )
		sendSelection( ent, name )
		frame:Close()
	end

	local top = createTopBar( frame )
	addEmptyButton( top, function() pick( "" ) end )
	for _, setting in ipairs( SETTINGS ) do addSettingBox( top, setting, ent ) end
	local filter = addFilterEntry( top, countListedMaps( order, byName ) )

	local setFilter = createMapList( frame, order, byName, findIcons(), ent:GetMapName(), pick )
	filter.OnChange = function( self ) setFilter( self:GetValue() ) end
end

net.Receive( "PocketMap_Open", function()
	local ent = net.ReadEntity()
	if not IsValid( ent ) or ent:GetClass() ~= "ent_pocketmap" then return end

	if ent:IsMapPending() then
		ent:AcceptMap()
	else
		PocketMap.OpenMenu( ent )
	end
end )
