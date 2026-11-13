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

local COLOR_BOX = Color( 55, 60, 72 )
local COLOR_HEADER_HOVER = Color( 70, 80, 100 )
local COLOR_TILE = Color( 45, 45, 50 )
local COLOR_TILE_CURRENT = Color( 60, 130, 80 )
local COLOR_TILE_HOVER = Color( 70, 110, 160 )
local COLOR_NO_ICON = Color( 120, 120, 120 )

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
	frame:SetTitle( "Pocket Map" )
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
	tile.Selected = isCurrent
	tile.DoClick = function() onPick( name ) end
	tile.Paint = function( self, w, h ) paintTile( self, w, h, icons, self.Selected ) end
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
local function createMapList( frame, order, byName, icons, current, onPick, rowWidth )
	local scroll = vgui.Create( "DScrollPanel", frame )
	scroll:Dock( FILL )

	local container = scroll:Add( "DPanel" )
	container:Dock( TOP )
	container.Paint = nil

	rowWidth = rowWidth or frame:GetWide() - SCROLL_AND_BORDER_W
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
	end, function( name )
		for _, group in ipairs( groups ) do
			for _, tile in ipairs( group.tiles ) do tile.Selected = tile.MapName == name end
		end
	end
end

local function performancePage( frame, sheet, draft )
	local page = vgui.Create( "DPanel", sheet )
	page:DockPadding( 8, 8, 8, 8 )
	page.Paint = nil
	local presets = createTopBar( page )
	presets:SetTall( 32 )
	frame.PresetButtons, frame.SettingsBoxes = {}, {}
	local status = vgui.Create( "DLabel", page )
	status:Dock( TOP )
	status:SetTall( 36 )
	status:SetTextColor( color_white )
	status:SetText( "Custom settings. Hover an option for its cost and visual impact. Changes apply with OK and Rebuild." )
	status:SetWrap( true )
	local refresh = false
	for _, preset in ipairs( PocketMap.Settings.Presets ) do
		local button = vgui.Create( "DButton", presets )
		button:Dock( LEFT )
		button:DockMargin( 0, 0, 8, 0 )
		button:SetWide( 150 )
		button:SetText( preset.name )
		button:SetTooltip( preset.description )
		button.DoClick = function()
			local values = PocketMap.Settings.Preset( preset.key )
			refresh = true
			for key, box in pairs( frame.SettingsBoxes ) do draft[key] = values[key] box:SetValue( values[key] and 1 or 0 ) end
			refresh = false
			status:SetText( preset.name .. " selected. " .. preset.description )
		end
		frame.PresetButtons[preset.key] = button
	end
	local scroll = vgui.Create( "DScrollPanel", page )
	scroll:Dock( FILL )
	for _, group in ipairs( PocketMap.Settings.Groups ) do
		local form = scroll:Add( "DForm" )
		form:Dock( TOP )
		form:DockMargin( 0, 0, 0, 8 )
		form:SetName( group )
		form:SetExpanded( true )
		form.Paint = paintBox
		for _, option in ipairs( PocketMap.Settings.Options ) do
			if option.group == group then
				local row = vgui.Create( "DPanel", form )
				row:SetTall( 40 )
				row.Paint = nil
				local tooltip = option.detail .. "\n\nCost / benefit: " .. option.cost .. "\nVisual impact: " .. option.visual
					.. "\nActual cost depends on the map and view."
				local checkbox = vgui.Create( "DCheckBoxLabel", row )
				checkbox:Dock( TOP )
				checkbox:SetText( option.name )
				checkbox:SetTextColor( color_white )
				checkbox:SetTooltip( tooltip )
				checkbox:SetValue( draft[option.key] and 1 or 0 )
				checkbox.OnChange = function( _, value )
					draft[option.key] = value == true
					if not refresh then status:SetText( "Custom settings. Hover an option for its cost and visual impact. Changes apply with OK and Rebuild." ) end
				end
				local impact = vgui.Create( "DLabel", row )
				impact:Dock( TOP )
				impact:DockMargin( 20, 2, 0, 0 )
				impact:SetText( option.cost .. "  |  Visual: " .. option.visual )
				impact:SetTextColor( Color( 185, 200, 215 ) )
				impact:SetTooltip( tooltip )
				form:AddItem( row )
				frame.SettingsBoxes[option.key] = checkbox
			end
		end
	end
	return page
end

function PocketMap.OpenMenu( ent )
	if IsValid( PocketMap.Menu ) then PocketMap.Menu:Remove() end

	local order, byName = PocketMap.GroupMaps( listInstalledMaps() )

	local frame = createFrame()
	PocketMap.Menu = frame
	frame.SettingsDraft = PocketMap.Settings.Read( ent )
	frame.PendingMap = ent:GetMapName()
	local footer = vgui.Create( "DPanel", frame )
	footer:Dock( BOTTOM )
	footer:SetTall( 38 )
	footer:DockMargin( 0, 8, 0, 0 )
	footer.Paint = nil
	local apply = vgui.Create( "DButton", footer )
	apply:Dock( RIGHT )
	apply:SetWide( 170 )
	apply:SetText( "OK and Rebuild" )
	frame.RebuildButton = apply
	local cancel = vgui.Create( "DButton", footer )
	cancel:Dock( RIGHT )
	cancel:DockMargin( 0, 0, 8, 0 )
	cancel:SetWide( 90 )
	cancel:SetText( "Cancel" )
	cancel.DoClick = function()frame:Close()end
	local selection = vgui.Create( "DLabel", footer )
	selection:Dock( FILL )
	selection:SetTextColor( color_white )
	selection:SetText( "Selected: " .. ( frame.PendingMap ~= "" and frame.PendingMap or "empty block" ) )
	local sheet = vgui.Create( "DPropertySheet", frame )
	sheet:Dock( FILL )
	sheet:SetFadeTime( 0 )
	frame.PropertySheet = sheet
	local maps = vgui.Create( "DPanel", sheet )
	maps.Paint = nil
	maps:DockPadding( 8, 8, 8, 8 )
	local setSelected

	local function pick( name )
		frame.PendingMap = name
		selection:SetText( "Selected: " .. ( name ~= "" and name or "empty block" ) )
		if setSelected then setSelected( name ) end
	end

	local top = createTopBar( maps )
	addEmptyButton( top, function() pick( "" ) end )
	local filter = addFilterEntry( top, countListedMaps( order, byName ) )

	local setFilter
	setFilter, setSelected = createMapList( maps, order, byName, findIcons(), ent:GetMapName(), pick,
		frame:GetWide() - SCROLL_AND_BORDER_W - 32 )
	filter.OnChange = function( self ) setFilter( self:GetValue() ) end
	sheet:AddSheet( "Maps", maps, "icon16/map.png" )
	local settingsPage = performancePage( frame, sheet, frame.SettingsDraft )
	frame.PerformanceTab = sheet:AddSheet( "Performance", settingsPage, "icon16/cog.png" ).Tab
	apply.DoClick = function()
		if not PocketMap.Settings.Apply( ent, frame.SettingsDraft ) then frame:Close() return end
		local name = frame.PendingMap
		if name ~= "" and name == ent:GetMapName() then ent:AcceptMap()
		else sendSelection( ent, name ) end
		frame:Close()
	end
end

net.Receive( "PocketMap_Open", function()
	local ent = net.ReadEntity()
	if not IsValid( ent ) or ent:GetClass() ~= "ent_pocketmap" then return end

	PocketMap.OpenMenu( ent )
end )
