-- bsp:GetEntities() gives a table of key-values per entity. A key that is in the entity twice is stored as a table of values.

PocketMap = PocketMap or {}
PocketMap.Entities = {}
local Entities = PocketMap.Entities

---@return any # the first value of a key that was in the entity more than once
function Entities.First( value )
	if type( value ) == "table" then return value[1] end
	return value
end

---@return string # lower case, "" if the entity has none
function Entities.Class( entity )
	local class = Entities.First( entity.classname )
	return type( class ) == "string" and class:lower() or ""
end

---@return string? # lower case, nil if the entity has none
function Entities.Name( entity )
	local name = Entities.First( entity.targetname )
	return type( name ) == "string" and name:lower() or nil
end
