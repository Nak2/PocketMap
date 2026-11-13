-- A local issue log with original BSP coordinates, ready to paste into an LLM.
PocketMap.NoteLog = PocketMap.NoteLog or {}
local NoteLog = PocketMap.NoteLog
local SAVE_FILE = "pocketmap/user_notes.json"

local function formatVector( v )
	return string.format( "Vector(%.2f, %.2f, %.2f)", v.x, v.y, v.z )
end

local function formatAngle( a )
	return string.format( "Angle(%.2f, %.2f, %.2f)", a.p, a.y, a.r )
end

local function loadNotes()
	local json = file.Read( SAVE_FILE, "DATA" )
	local stored = json and util.JSONToTable( json )
	local notes = {}
	if istable( stored ) and istable( stored.notes ) then
		for _, note in ipairs( stored.notes ) do
			if istable( note ) and isstring( note.description )
				and isstring( note.map ) and isstring( note.source )
				and isstring( note.position ) and isstring( note.eyePosition ) and isstring( note.angle ) then
				notes[#notes + 1] = note
			end
		end
	end
	return notes
end

if not NoteLog.notes then
	NoteLog.notes = loadNotes()
end

local function renumberNotes()
	for i, note in ipairs( NoteLog.notes ) do note.id = i end
	NoteLog.nextId = #NoteLog.notes + 1
end

-- Normalize older saved logs too, including ones with gaps from deleted notes.
renumberNotes()

local function saveNotes()
	renumberNotes()
	file.CreateDir( "pocketmap" )
	file.Write( SAVE_FILE, util.TableToJSON( { notes = NoteLog.notes, nextId = NoteLog.nextId }, true ) )
end

local function captureView()
	local session = PocketMap.Walk and PocketMap.Walk.session
	if session and session.mini and session.move then
		local origin = session.move.origin
		return {
			map = session.mini.mapName,
			source = "PocketMap (original BSP coordinates)",
			position = formatVector( origin ),
			eyePosition = formatVector( origin + PocketMap.Walk.EyeOffset( session ) ),
			angle = formatAngle( session.move.angles ),
		}
	end

	local ply = LocalPlayer()
	if not IsValid( ply ) then return end
	return {
		map = game.GetMap(),
		source = "Native map",
		position = formatVector( ply:GetPos() ),
		eyePosition = formatVector( ply:EyePos() ),
		angle = formatAngle( ply:EyeAngles() ),
	}
end

local function exportNotes()
	local parts = {}
	for _, note in ipairs( NoteLog.notes ) do
		parts[#parts + 1] = string.format(
			"USER NOTE %d\nMap: %s\nSource: %s\nPosition: %s\nEye Position: %s\nView Angle: %s\nDescription:\n%s",
			note.id, note.map, note.source, note.position, note.eyePosition, note.angle, note.description
		)
	end
	return table.concat( parts, "\n\n" )
end

local function makeLabel( parent, text )
	local label = vgui.Create( "DLabel", parent )
	label:Dock( TOP )
	label:SetTall( 22 )
	label:SetText( text )
	return label
end

local EDIT_FIELDS = {
	{ key = "description", label = "Description", height = 110, multiline = true },
	{ key = "map", label = "Map" },
	{ key = "source", label = "Source" },
	{ key = "position", label = "Position" },
	{ key = "eyePosition", label = "Eye Position" },
	{ key = "angle", label = "View Angle" },
}

local function editNote( note, onSaved )
	if IsValid( NoteLog.editFrame ) then NoteLog.editFrame:Close() end

	local frame = vgui.Create( "DFrame" )
	NoteLog.editFrame = frame
	frame:SetTitle( "Edit USER NOTE " .. note.id )
	frame:SetSize( math.min( 640, ScrW() - 60 ), math.min( 550, ScrH() - 60 ) )
	frame:Center()
	frame:MakePopup()

	local content = vgui.Create( "DPanel", frame )
	content:Dock( FILL )
	content:DockPadding( 8, 8, 8, 8 )
	content.Paint = nil

	local entries = {}
	for _, spec in ipairs( EDIT_FIELDS ) do
		makeLabel( content, spec.label .. ":" )
		local entry = vgui.Create( "DTextEntry", content )
		entry:Dock( TOP )
		entry:DockMargin( 0, 0, 0, 4 )
		entry:SetTall( spec.height or 26 )
		entry:SetMultiline( spec.multiline or false )
		entry:SetText( note[spec.key] )
		entries[spec.key] = entry
	end

	local buttons = vgui.Create( "DPanel", content )
	buttons:Dock( TOP )
	buttons:DockMargin( 0, 8, 0, 0 )
	buttons:SetTall( 28 )
	buttons.Paint = nil

	local save = vgui.Create( "DButton", buttons )
	save:Dock( LEFT )
	save:SetWide( 105 )
	save:SetText( "Save Changes" )

	local recapture = vgui.Create( "DButton", buttons )
	recapture:Dock( LEFT )
	recapture:DockMargin( 8, 0, 0, 0 )
	recapture:SetWide( 145 )
	recapture:SetText( "Use Current View" )
	recapture:SetTooltip( "Replace map, source, position and angle with your current location." )
	recapture.DoClick = function()
		local view = captureView()
		if not view then return end
		for key, value in pairs( view ) do entries[key]:SetText( value ) end
	end

	local cancel = vgui.Create( "DButton", buttons )
	cancel:Dock( LEFT )
	cancel:DockMargin( 8, 0, 0, 0 )
	cancel:SetWide( 75 )
	cancel:SetText( "Cancel" )
	cancel.DoClick = function() frame:Close() end

	local status = makeLabel( content, "" )
	status:DockMargin( 0, 4, 0, 0 )
	save.DoClick = function()
		local values = {}
		for _, spec in ipairs( EDIT_FIELDS ) do
			local value = string.Trim( entries[spec.key]:GetValue() )
			if value == "" then
				status:SetText( spec.label .. " cannot be empty." )
				return
			end
			values[spec.key] = value
		end
		-- The note may have been deleted while this editor was open.
		local found = false
		for _, saved in ipairs( NoteLog.notes ) do
			if saved == note then found = true break end
		end
		if not found then return frame:Close() end
		for key, value in pairs( values ) do note[key] = value end
		saveNotes()
		onSaved( note )
		frame:Close()
	end
end

concommand.Add( "pocketmap_note", function()
	if IsValid( NoteLog.frame ) then
		NoteLog.frame:MakePopup()
		NoteLog.frame:MoveToFront()
		return
	end

	local frame = vgui.Create( "DFrame" )
	NoteLog.frame = frame
	frame:SetTitle( "PocketMap - User Notes" )
	frame:SetSize( math.min( 800, ScrW() - 60 ), math.min( 690, ScrH() - 60 ) )
	frame:Center()
	frame:MakePopup()

	local content = vgui.Create( "DPanel", frame )
	content:Dock( FILL )
	content:DockPadding( 8, 8, 8, 8 )
	content.Paint = nil

	makeLabel( content, "Describe the problem:" )
	local description = vgui.Create( "DTextEntry", content )
	description:Dock( TOP )
	description:DockMargin( 0, 0, 0, 8 )
	description:SetTall( 90 )
	description:SetMultiline( true )
	description:SetPlaceholderText( "What is broken or different from the native map?" )

	local controls = vgui.Create( "DPanel", content )
	controls:Dock( TOP )
	controls:DockMargin( 0, 0, 0, 8 )
	controls:SetTall( 28 )
	controls.Paint = nil

	local add = vgui.Create( "DButton", controls )
	add:Dock( LEFT )
	add:SetWide( 105 )
	add:SetText( "Add Note" )

	local copy = vgui.Create( "DButton", controls )
	copy:Dock( LEFT )
	copy:DockMargin( 8, 0, 0, 0 )
	copy:SetWide( 105 )
	copy:SetText( "Copy All" )

	local status = vgui.Create( "DLabel", controls )
	status:Dock( FILL )
	status:DockMargin( 12, 0, 0, 0 )
	status:SetText( "Coordinates are captured when you add a note." )

	makeLabel( content, "Copyable log (read only):" )
	local output = vgui.Create( "DTextEntry", content )
	output:Dock( TOP )
	output:DockMargin( 0, 0, 0, 8 )
	output:SetTall( math.floor( frame:GetTall() * 0.35 ) )
	output:SetMultiline( true )
	output:SetEditable( false )

	makeLabel( content, "Saved notes - edit or delete individual entries below:" )
	local scroll = vgui.Create( "DScrollPanel", content )
	scroll:Dock( FILL )

	local rows = {}
	local function refresh()
		output:SetText( exportNotes() )
		copy:SetEnabled( #NoteLog.notes > 0 )
		for _, row in ipairs( rows ) do row:Remove() end
		rows = {}
		for _, note in ipairs( NoteLog.notes ) do
			local row = scroll:Add( "DPanel" )
			row:Dock( TOP )
			row:DockMargin( 0, 0, 0, 4 )
			row:SetTall( 28 )
			row.Paint = nil
			rows[#rows + 1] = row

			local remove = vgui.Create( "DButton", row )
			remove:Dock( RIGHT )
			remove:SetWide( 64 )
			remove:SetText( "Delete" )
			remove:SetTooltip( "Clear this note and renumber the remaining notes." )
			remove.DoClick = function()
				local removedNumber = note.id
				for i, saved in ipairs( NoteLog.notes ) do
					if saved == note then table.remove( NoteLog.notes, i ) break end
				end
				saveNotes()
				refresh()
				status:SetText( "Deleted USER NOTE " .. removedNumber .. "; notes renumbered." )
			end

			local edit = vgui.Create( "DButton", row )
			edit:Dock( RIGHT )
			edit:DockMargin( 0, 0, 6, 0 )
			edit:SetWide( 64 )
			edit:SetText( "Edit" )
			edit.DoClick = function()
				editNote( note, function( saved )
					refresh()
					status:SetText( "Saved changes to USER NOTE " .. saved.id .. "." )
				end )
			end

			local preview = string.gsub( note.description, "%s+", " " )
			local label = vgui.Create( "DLabel", row )
			label:Dock( FILL )
			label:SetText( "USER NOTE " .. note.id .. " [" .. note.map .. "]  " .. string.sub( preview, 1, 90 ) )
		end
	end

	add.DoClick = function()
		local text = string.Trim( description:GetValue() )
		if text == "" then
			status:SetText( "Type a description first." )
			return
		end
		local view = captureView()
		if not view then
			status:SetText( "No valid player position to capture." )
			return
		end
		view.id = #NoteLog.notes + 1
		view.description = text
		NoteLog.notes[#NoteLog.notes + 1] = view
		saveNotes()
		refresh()
		status:SetText( "Added USER NOTE " .. view.id .. " on " .. view.map .. "." )
		description:SetText( "" )
		description:RequestFocus()
	end

	copy.DoClick = function()
		SetClipboardText( exportNotes() )
		status:SetText( "Copied all notes to clipboard." )
	end

	refresh()
	description:RequestFocus()
end )
