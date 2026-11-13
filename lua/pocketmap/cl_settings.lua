-- Client preferences become an immutable snapshot on each rebuilt miniature.
-- Editing the menu never changes a running renderer or another block.
PocketMap.Settings = PocketMap.Settings or {}
local Settings = PocketMap.Settings
local previousOptions = Settings.Options
Settings.Options, Settings.ByKey = {}, {}
Settings.Groups = { "Water", "Geometry and decoration", "Lighting", "Effects", "Optimizations", "Collision" }
Settings.Presets = {
	{ key = "performance", name = "Performance", description = "Simple water and fewer decorative effects. Keeps essential geometry, lighting, collision and optimizations." },
	{ key = "balanced", name = "Balanced", description = "Keeps the map's main appearance, with cheaper water and fewer small effects." },
	{ key = "fidelity", name = "High Fidelity", description = "All visual features at full quality. Keeps visibility and caching optimizations enabled." },
}
local function add( group, key, name, cost, visual, detail, performance, balanced, fidelity, legacy, default )
	local option = { group = group, key = key, name = name, cost = cost, visual = visual, detail = detail,
		performance = performance, balanced = balanced, fidelity = fidelity, conVar = legacy or "pocketmap_" .. key }
	option.default = default ~= false
	option.cv = GetConVar( option.conVar ) or CreateClientConVar( option.conVar, option.default and "1" or "0", true, false, detail, 0, 1 )
	Settings.Options[#Settings.Options + 1], Settings.ByKey[key] = option, option
end
local W, G, L, E, O, C = unpack( Settings.Groups )
add( W, "water_surface", "Water surfaces", "Medium GPU", "High", "Draws water, including its normal-map shading. Off makes water invisible; swimming and collision are unchanged.", true, true, true )
add( W, "water_reflections", "Water reflections", "Very high CPU/GPU", "High near water", "Renders an additional mirrored map view. Off uses the water's flat fallback reflection instead.", false, false, true )
add( W, "water_refractions", "Water refraction", "Very high CPU/GPU", "High near water", "Renders the map below water into a second view, including water depth. Off uses a flat fallback underwater texture.", false, true, true )
add( W, "water_reflect_props", "Model props in reflections", "High CPU/GPU", "Medium", "Adds model props to water reflections. Requires reflections and the material's entity-reflection support.", false, false, true, nil, false )
add( W, "water_reflect_entities", "Doors and moving brushes in reflections", "Medium to high CPU/GPU", "Medium", "Draws functional map entities into water reflections. Independent of decorative model props; requires material support.", false, false, true )
add( W, "water_refract_props", "Props in refraction", "High CPU/GPU", "Medium", "Draws submerged model props into the refraction view. Requires water refraction.", false, false, true )
add( W, "water_reflect_sky", "Sky in reflections", "Medium GPU", "Medium", "Draws the sky into reflected water. Requires water reflections.", false, true, true )
add( W, "water_high_resolution", "Higher-resolution water", "High GPU / video memory", "Medium", "Uses half-screen-sized water targets. Off uses quarter-screen targets; water reflections/refraction become less sharp.", false, false, true )
add( W, "water_every_frame", "Full-rate water updates", "High CPU/GPU", "Medium while still", "Refreshes both water views every frame. Off budgets stationary views; moving cameras still refresh to keep water aligned.", false, false, true, nil, false )
add( G, "static_props", "Static map props", "High CPU/GPU", "High", "Draws compiled map props such as trees, furniture and rocks. Off hides them, but their collision remains unless separately disabled.", true, true, true )
add( G, "entity_props", "Entity model props", "High CPU/GPU", "High", "Draws authored model entities such as crates and decorative machines. Functional doors remain available. Collision is controlled separately.", true, true, true )
add( G, "moving_brushes", "Moving brush geometry", "Medium to high CPU/GPU", "High", "Draws brush doors, lifts and other functional brush surfaces. Off hides their geometry; map logic and collision still run.", true, true, true )
add( G, "model_doors", "Model doors", "Medium CPU/GPU", "High", "Draws model-based rotating doors. Off hides the models while their interaction and collision remain.", true, true, true )
add( G, "detail_sprites", "Grass and detail sprites", "Medium to high GPU", "Medium", "Draws small grass and plant sprites. Dense patches can be expensive because many pixels overlap.", false, false, true )
add( G, "detail_models", "Detail models", "Medium CPU/GPU", "Low to medium", "Draws small model-based BSP detail decorations. Separate from ordinary static props.", false, true, true )
add( G, "translucent_world", "Glass and blended surfaces", "Medium to high GPU", "High", "Draws blended world materials, including windows and some fences. Off can make those surfaces disappear; their collision remains.", true, true, true )
add( G, "translucent_props", "Translucent model parts", "Medium GPU", "Medium to high", "Draws transparent submaterials of model props and sky props. Alpha-tested opaque parts remain visible.", false, true, true )
add( G, "decals", "Map decals", "Medium CPU/GPU", "Medium", "Draws projected infodecal marks such as stains, signs and damage. Separate from BSP overlays.", false, true, true )
add( G, "overlays", "Map overlays", "Medium CPU/GPU", "Medium to high", "Draws authored overlays such as road markings, signs and large surface details.", false, true, true )
add( G, "sky_world", "3D skybox geometry", "Medium to high CPU/GPU", "High outdoors", "Draws distant buildings and terrain from the 3D skybox. The ordinary sky background remains.", false, true, true )
add( G, "sky_props", "3D skybox props", "Medium CPU/GPU", "Medium outdoors", "Draws model props in the 3D skybox. Independent of skybox geometry.", false, false, true )
add( G, "sky_decals", "3D skybox decals and overlays", "Low to medium GPU", "Low", "Draws surface decorations in the 3D skybox; still respects the decal and overlay switches.", false, false, true )
add( L, "lightmaps", "Surface lightmaps", "Low to medium GPU", "Very high", "Uses the map's baked surface lighting. Off draws world surfaces fullbright. The atlas is still prepared for geometry, decals and other lighting features.", true, true, true )
add( L, "prop_lighting", "Baked prop lighting", "Medium CPU / loading", "High", "Samples and applies the map's lighting to model props. Off uses fullbright prop lighting.", true, true, true )
add( L, "prop_direct", "Direct lights on props", "Low to medium CPU", "Medium", "Adds local directional/point light contributions to props. Requires baked prop lighting; ambient lighting remains when this is off.", false, true, true )
add( L, "directional_prop_ambient", "Directional ambient prop lighting", "Medium CPU", "Medium", "Shades each side of a prop with its own ambient light color. Off keeps local brightness/color but uses one averaged ambient color, reducing lighting state changes.", false, true, true )
add( L, "world_normalmaps", "World normal maps", "Low to high GPU", "Medium", "Keeps bump and normal-map shading on supported world materials. Off makes surface lighting flatter; base textures, opacity and terrain blending remain.", false, true, true )
add( L, "world_detailtextures", "World detail textures", "Low to medium GPU", "Medium at close range", "Adds fine detail-texture layers to supported world materials. Off retains the base texture and terrain blend masks.", false, true, true )
add( L, "world_reflections", "World cubemap reflections", "Medium GPU", "Medium on shiny surfaces", "Keeps environment-map reflections on supported world materials. Separate from live water reflections. Off makes those surfaces less reflective.", false, true, true )
add( L, "world_source_camera", "Accurate world material orientation", "Map-dependent CPU/GPU", "Medium on reflective/seamless surfaces", "Renders the world in source-map coordinates for correct material directions. Off uses the earlier miniature-space path. Depth alignment below applies only when this is on.", true, true, true )
add( L, "world_depth_repair", "Always align world depth", "High CPU/GPU", "Small precision differences possible", "Adds a second opaque-world pass for exact depth alignment. Off uses the source view's ordinary depth and only adds the alignment pass when the pocket flashlight requires it.", false, false, true )
add( L, "lighttoggle", "Switchable map lighting", "Medium loading / updates", "High on affected maps", "Includes named and animated light styles when building surface and prop lighting. Off uses the base light style.", false, true, true, "pocketmap_lighttoggle" )
add( L, "animated_lights", "Animated lightmap updates", "Medium to high CPU/GPU", "Medium on affected maps", "Updates animated and switched surface lightmaps while inside the map. Off keeps the initial lighting. Requires switchable map lighting.", false, true, true )
add( L, "flashlight", "Flashlight lighting", "High CPU/GPU while on", "High in dark areas", "Enables the pocket flashlight and its extra receiving pass. Off hides the beam inside this block.", true, true, true )
add( L, "world_shadows", "Flashlight world and door shadows", "High CPU/GPU while on", "High", "Draws world, moving-brush and functional door geometry into the flashlight shadow map. Requires flashlight lighting.", false, true, true )
add( L, "prop_shadows", "Flashlight decorative prop shadows", "High CPU/GPU while on", "Medium", "Draws static and decorative model props into the flashlight shadow map. Requires flashlight lighting.", false, false, true )
add( E, "fire", "Fire particles", "Medium to high CPU/GPU", "Medium", "Creates and renders authored env_fire particle systems. Off hides flames and their associated smoke.", false, true, true )
add( E, "smoke", "Smoke stacks", "Medium to high CPU/GPU", "Medium", "Creates and updates authored smoke-stack emitters. Many large overlapping particles can be expensive.", false, false, true )
add( E, "particles", "Other particle systems", "Variable; potentially high", "Medium to high", "Runs authored info_particle_system effects. Cost depends on the map and the particle system.", false, true, true )
add( E, "sprites", "Ordinary sprites", "Low to medium GPU", "Medium", "Draws non-glowing authored sprites. Glowing halos have a separate switch.", true, true, true )
add( E, "glows", "Glow sprites and visibility queries", "Medium; can be high", "Medium", "Draws glow halos and runs their visibility queries. Visible glows can require the more expensive engine-backed walking view.", false, false, true )
add( E, "footsteps", "Footstep sounds and surface checks", "Low CPU", "No visual difference", "Performs ground/surface checks and plays virtual footsteps. Off silences your footsteps inside this block.", true, true, true )
add( E, "walkers", "Other players in PocketMaps", "Low to high CPU/GPU", "High in multiplayer", "Draws other players walking in this pocket world. Has little cost when no other players are present.", true, true, true )
add( O, "minimal_preview", "Minimal outside preview", "High savings outside the map", "Bare world geometry outside", "While the camera is outside this block, draws only opaque world geometry with simple fullbright textures. Hides props, water, skyboxes, glass, decals, lighting, effects and players. Entering restores this block's selected settings without rebuilding.", true, true, true )
add( O, "baked_models", "Use baked prop meshes", "Usually saves CPU", "Small shading differences possible", "Bakes compatible prop geometry at load time instead of drawing every prop through an engine model. Uses more build time/memory; static-only models always require this path.", true, true, true, "pocketmap_propmeshes" )
add( O, "direct_scene", "Skip covered host-world rendering", "Potentially high savings", "No intended difference", "Uses the direct walking renderer when compatible with flashlight/effects requirements. Automatically falls back when needed.", true, true, true, "pocketmap_walk_scene" )
add( O, "pvs", "BSP visibility filtering", "Potentially high savings", "No intended difference", "Rejects geometry in BSP visibility clusters that cannot be seen from the active camera. Unknown visibility remains visible.", true, true, true )
add( O, "world_cache", "Cache visible world meshes", "Map-dependent CPU savings", "No intended difference", "Combines only the visible opaque faces into runtime meshes. Uses extra memory and background build work when changing visibility clusters.", true, true, true )
add( O, "defer_world_cache", "Defer visibility mesh builds while moving", "Can save up to the cache build budget", "No intended difference", "Waits until movement stops briefly before compiling a new visibility mesh. Existing meshes remain usable and conservative batches cover cache misses; avoids rebuilding transient visibility sets.", true, true, true )
add( O, "world_frustum_cache", "Cache world camera culling", "Low CPU savings", "No intended difference", "Reuses world visibility tests while the camera and visibility set are unchanged.", true, true, true, "pocketmap_world_frustum_cache" )
add( O, "prop_frustum_cache", "Cache prop camera culling", "Low to medium CPU savings", "No intended difference", "Reuses prop visibility tests while the camera and prop transforms are unchanged.", true, true, true, "pocketmap_prop_frustum_cache" )
add( O, "prop_occlusion", "Occlude hidden props", "Map-dependent savings", "No intended difference", "Checks stationary-view props against solid map surfaces to avoid drawing hidden models.", true, true, true, "pocketmap_prop_occlusion" )
add( O, "brush_occlusion", "Occlude hidden moving brushes", "Map-dependent savings", "No intended difference", "Avoids drawing moving brush objects proven hidden by solid world geometry.", true, true, true, "pocketmap_mapio_occlusion" )
add( O, "door_occlusion", "Occlude hidden model doors", "Map-dependent savings", "No intended difference", "Avoids drawing model doors proven hidden by solid world geometry.", true, true, true, "pocketmap_door_occlusion" )
add( O, "reflection_pvs", "Water reflection visibility filtering", "Potentially high savings", "No intended difference", "Uses the union of water-surface visibility clusters for reflections, retaining all uncertain geometry.", true, true, true, "pocketmap_water_reflection_pvs" )
add( O, "water_scene_cull", "Cull outside water cameras", "Medium to high savings", "No intended difference", "Rejects world geometry outside reflection and refraction camera views.", true, true, true, "pocketmap_water_scene_cull" )
add( O, "water_clip_bounds", "Cache water-plane clipping", "Low to medium savings", "No intended difference", "Rejects batches entirely on the wrong side of a water plane before drawing them.", true, true, true, "pocketmap_water_clip_bounds" )
add( O, "world_depth_material", "Simpler opaque depth shader (experimental)", "Small / map-dependent savings", "Possible material edge cases", "Uses a simpler shader for eligible opaque depth-only surfaces. Kept off in presets because gains and compatibility vary.", false, false, false, "pocketmap_world_depth_material", false )
add( C, "prop_collision", "Static prop collision", "Low CPU; some loading cost", "Changes movement", "Builds and queries solid prop collision. Off lets the player pass through static props; it does not hide them.", true, true, true )
add( C, "displacement_collision", "Displacement collision", "Low CPU; some loading cost", "Changes movement", "Builds and queries terrain collision. Off can let the player fall through displacement terrain. Ordinary BSP collision remains.", true, true, true )
add( C, "dynamic_collision", "Moving brush collision", "Low CPU", "Changes movement", "Tests moving doors, lifts and other map brushes during movement. Off allows walking through them; map logic still runs.", true, true, true )

function Settings.Enabled( mini, key )
	local values = mini and mini.settings
	if values and values[key] ~= nil then return values[key] end
	local option = Settings.ByKey[key]
	return option and option.cv:GetBool() or false
end

-- Only renderers use this override. Loading and collision always read the
-- selected snapshot, so entering never requires building missing features.
-- Use the rendered camera, including noclip/camera views, rather than the
-- real player position or another block's walking session.
function Settings.MinimalPreview( mini )
	return mini ~= nil and Settings.Enabled( mini, "minimal_preview" )
		and mini.EyeInside ~= nil and not mini:EyeInside()
end

-- Legacy console controls remain live on miniatures created before settings
-- snapshots, and in standalone callers that do not have a settings table.
function Settings.Compat( mini, key, cv )
	if mini and mini.settings and mini.settings[key] ~= nil then return mini.settings[key] end
	return cv:GetBool()
end

function Settings.Copy( values )
	local result = {}
	for _, option in ipairs( Settings.Options ) do
		local value = values and values[option.key]
		result[option.key] = value == nil and option.cv:GetBool() or value == true
	end
	return result
end

function Settings.Read( ent )
	local mini = ent and ent.Miniature
	if ent and ent.PocketMapSettings then return Settings.Copy( ent.PocketMapSettings ) end
	if mini and mini.settings then return Settings.Copy( mini.settings ) end
	local values = Settings.Copy()
	local water = GetConVar( "pocketmap_water" )
	if water then
		values.water_every_frame = water:GetInt() == 2
		if water:GetInt() == 0 then values.water_reflections, values.water_refractions = false, false end
	end
	return values
end

function Settings.Preset( key )
	local result = {}
	for _, option in ipairs( Settings.Options ) do result[option.key] = option[key] == true end
	return result
end

function Settings.Apply( ent, values )
	if not IsValid( ent ) or ent:GetClass() ~= "ent_pocketmap" then return false end
	local snapshot = Settings.Copy( values )
	ent.PocketMapSettings = snapshot
	for _, option in ipairs( Settings.Options ) do option.cv:SetBool( snapshot[option.key] ) end
	local water = GetConVar( "pocketmap_water" )
	if water then water:SetInt( ( snapshot.water_reflections or snapshot.water_refractions )
		and ( snapshot.water_every_frame and 2 or 1 ) or 0 ) end
	return true
end

function Settings.WaterMode( mini, fallback )
	if not mini or not mini.settings then return fallback:GetInt() end
	if not Settings.Enabled( mini, "water_surface" )
		or not ( Settings.Enabled( mini, "water_reflections" ) or Settings.Enabled( mini, "water_refractions" ) ) then return 0 end
	return Settings.Enabled( mini, "water_every_frame" ) and 2 or 1
end

-- Preserve existing blocks when loading the settings module into a live game.
local function fillMissing( values )
	local profile
	if previousOptions then
		for _, preset in ipairs( Settings.Presets ) do
			local matches = true
			for _, option in ipairs( previousOptions ) do
				if values[option.key] ~= option[preset.key] then matches = false break end
			end
			if matches then profile = preset.key break end
		end
	end
	for _, option in ipairs( Settings.Options ) do
		if values[option.key] == nil then
			if profile then values[option.key] = option[profile] else values[option.key] = option.cv:GetBool() end
		end
	end
end
for mini in pairs( PocketMap.Active or {} ) do
	if not mini.settings then mini.settings = Settings.Read( mini.ent ) else fillMissing( mini.settings ) end
	if mini.ent and mini.ent.PocketMapSettings then fillMissing( mini.ent.PocketMapSettings ) end
end
