-- A reload of the files must not leave the hooks of the old ones behind
if PocketMap.Hooks then PocketMap.Hooks.SetActive( false ) end

PocketMap.Hooks = {}
local Hooks = PocketMap.Hooks

local registered = {}
local installed = false

---@param event string
---@param name string
---@param callback function
function Hooks.Register( event, name, callback )
	registered[#registered + 1] = { event = event, name = name, callback = callback }
	if installed then hook.Add( event, name, callback ) end
end

---Adds every registered hook, or removes them. Doing either twice is harmless.
---@param wanted boolean
function Hooks.SetActive( wanted )
	if wanted == installed then return end
	installed = wanted

	for _, entry in ipairs( registered ) do
		if wanted then
			hook.Add( entry.event, entry.name, entry.callback )
		else
			hook.Remove( entry.event, entry.name )
		end
	end
end
