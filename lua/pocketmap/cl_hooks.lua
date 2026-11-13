-- Recurring work exists only while a miniature is active. Registrations replace
-- themselves by name, including when an individual module is auto-refreshed.
PocketMap.Hooks = PocketMap.Hooks or {}
local Hooks = PocketMap.Hooks
Hooks.callbacks = Hooks.callbacks or {}
if Hooks.active == nil then Hooks.active = next( PocketMap.Active or {} ) ~= nil end

---@param event string
---@param name string
---@param callback function
function Hooks.Register( event, name, callback )
	local callbacks = Hooks.callbacks[event]
	if not callbacks then
		callbacks = {}
		Hooks.callbacks[event] = callbacks
	end
	callbacks[name] = callback
	if Hooks.active then
		hook.Add( event, name, callback )
	else
		hook.Remove( event, name )
	end
end

---Adds every registered hook, or removes them. Doing either twice is harmless.
---@param wanted boolean
function Hooks.SetActive( wanted )
	if wanted == Hooks.active then return end
	Hooks.active = wanted
	for event, callbacks in pairs( Hooks.callbacks ) do
		for name, callback in pairs( callbacks ) do
			if wanted then
				hook.Add( event, name, callback )
			else
				hook.Remove( event, name )
			end
		end
	end
end
