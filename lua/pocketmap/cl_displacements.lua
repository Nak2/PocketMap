-- Swept player hulls against the same displacement triangles used for drawing.
PocketMap.Displacements = {}
local Disp = PocketMap.Displacements
local EPSILON = 0.03125

local function point(v) return {x = v.x, y = v.y, z = v.z} end
local function bounds(a, b, c)
	return {x = math.min(a.x, b.x, c.x), y = math.min(a.y, b.y, c.y), z = math.min(a.z, b.z, c.z)},
		{x = math.max(a.x, b.x, c.x), y = math.max(a.y, b.y, c.y), z = math.max(a.z, b.z, c.z)}
end

local function triangle(a, b, c, facing, contents)
	a, b, c = point(a), point(b), point(c)
	local ux, uy, uz = b.x - a.x, b.y - a.y, b.z - a.z
	local vx, vy, vz = c.x - a.x, c.y - a.y, c.z - a.z
	local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
	local length = math.sqrt(nx * nx + ny * ny + nz * nz)
	if length < 0.000001 then return end
	if nx * facing.x + ny * facing.y + nz * facing.z < 0 then length = -length end
	local lo, hi = bounds(a, b, c)
	return {a = a, b = b, c = c, normal = {x = nx / length, y = ny / length, z = nz / length}, lo = lo, hi = hi, contents = contents}
end

local function buildTree(items, yield)
	if #items == 0 then return end
	local lo, hi = point(items[1].lo), point(items[1].hi)
	for i = 2, #items do
		local item = items[i]
		lo.x, lo.y, lo.z = math.min(lo.x, item.lo.x), math.min(lo.y, item.lo.y), math.min(lo.z, item.lo.z)
		hi.x, hi.y, hi.z = math.max(hi.x, item.hi.x), math.max(hi.y, item.hi.y), math.max(hi.z, item.hi.z)
	end
	local node = {lo = lo, hi = hi}
	if #items <= 8 then node.items = items return node end
	local axis = hi.x - lo.x > hi.y - lo.y and "x" or "y"
	if hi.z - lo.z > hi[axis] - lo[axis] then axis = "z" end
	table.sort(items, function(a, b) return a.lo[axis] + a.hi[axis] < b.lo[axis] + b.hi[axis] end)
	local left, right, middle = {}, {}, math.floor(#items / 2)
	for i, item in ipairs(items) do
		local half = i <= middle and left or right
		half[#half + 1] = item
	end
	if yield then yield() end
	node.left, node.right = buildTree(left, yield), buildTree(right, yield)
	return node
end

function Disp.Build(mini, job, yield)
	local count, backing = 0, {}
	mini:SetStatus("Building displacement collision", 0.05)
	-- The original flat displacement brush is not a second collision surface.
	for _, brush in pairs(job.bsp:GetBrushes()) do
		for _, side in ipairs(brush.sides) do
			if side.dispinfo and side.dispinfo >= 0 then backing[brush] = true break end
		end
	end
	local patches = {}
	for _, group in pairs(job.groups) do
		for _, face in ipairs(group) do
			if face:IsWorld() and face:IsDisplacement() then
				local info = face:GetDisplacementInfo()
				local contents = info and info.contents or CONTENTS_SOLID
				if bit.band(contents, MASK_PLAYERSOLID) ~= 0 then
					local verts = face:GenerateVertexTriangleData()
					-- Vertex shading normals may follow the stored BSP plane.
					-- Collision must use the outward face side, including reversed
					-- planes on surfaces such as surf_ace's iceberg tops.
					local reference = face.plane and face.plane.normal or (verts[1] and verts[1].normal)
					local sign = face.side == 1 and -1 or 1
					local facing = reference and {x = reference.x * sign, y = reference.y * sign, z = reference.z * sign}
					local patch = {}
					for i = 1, #verts - 2, 3 do
						local t = triangle(verts[i].pos, verts[i + 1].pos, verts[i + 2].pos, facing, contents)
						if t then patch[#patch + 1] = t end
						if yield and i % 192 == 1 then yield() end
					end
					local tree = buildTree(patch, yield)
					if tree then patches[#patches + 1] = tree end
					count = count + #patch
				end
				if yield then yield() end
			end
		end
	end
	-- A tree of patch trees limits both triangle work and query allocation.
	mini.displacementCollision = buildTree(patches, yield)
	mini.displacedBrushes = backing
	mini.displacementTriangles = count
end

local function overlaps(a, b, lo, hi)
	return a.x <= hi.x + EPSILON and b.x >= lo.x - EPSILON and a.y <= hi.y + EPSILON and b.y >= lo.y - EPSILON and a.z <= hi.z + EPSILON and b.z >= lo.z - EPSILON
end

-- Continuous separating-axis test: triangle normal, box axes, and all nine
-- edge/box-axis cross products. All math stays in Lua-number precision.
local function sweep(t, start, finish, mins, maxs, out)
	local n, a, b, c = t.normal, t.a, t.b, t.c
	local dx, dy, dz = finish.x - start.x, finish.y - start.y, finish.z - start.z
	local moving = dx ~= 0 or dy ~= 0 or dz ~= 0
	local velocity = n.x * dx + n.y * dy + n.z * dz
	-- One-sided terrain has no volume underneath. Ignore tangent/outward
	-- movement to avoid snagging on internal edges between adjacent triangles.
	if moving and velocity >= -0.0000001 then return end
	local plane = n.x * a.x + n.y * a.y + n.z * a.z
	local startPlane = n.x * start.x + n.y * start.y + n.z * start.z - plane
	local supportMin = n.x * (n.x < 0 and maxs.x or mins.x) + n.y * (n.y < 0 and maxs.y or mins.y) + n.z * (n.z < 0 and maxs.z or mins.z)
	local supportMax = n.x * (n.x < 0 and mins.x or maxs.x) + n.y * (n.y < 0 and mins.y or maxs.y) + n.z * (n.z < 0 and mins.z or maxs.z)
	if startPlane + supportMax < -EPSILON then return end
	local enter, leave = 0, out.Fraction
	local function axis(x, y, z)
		local length = math.sqrt(x * x + y * y + z * z)
		if length < 0.0000001 then return true end
		local p1, p2, p3 = x * a.x + y * a.y + z * a.z, x * b.x + y * b.y + z * b.z, x * c.x + y * c.y + z * c.z
		local hmin = x * (x < 0 and maxs.x or mins.x) + y * (y < 0 and maxs.y or mins.y) + z * (z < 0 and maxs.z or mins.z)
		local hmax = x * (x < 0 and mins.x or maxs.x) + y * (y < 0 and mins.y or maxs.y) + z * (z < 0 and mins.z or maxs.z)
		local lo, hi = math.min(p1, p2, p3) - hmax - EPSILON * length, math.max(p1, p2, p3) - hmin + EPSILON * length
		local origin, delta = x * start.x + y * start.y + z * start.z, x * dx + y * dy + z * dz
		if math.abs(delta) < 0.0000001 then return origin >= lo and origin <= hi end
		local first, last = (lo - origin) / delta, (hi - origin) / delta
		if first > last then first, last = last, first end
		enter, leave = math.max(enter, first), math.min(leave, last)
		return enter <= leave
	end
	if not axis(n.x, n.y, n.z) or not axis(1, 0, 0) or not axis(0, 1, 0) or not axis(0, 0, 1) then return end
	local edges = {{b.x - a.x, b.y - a.y, b.z - a.z}, {c.x - b.x, c.y - b.y, c.z - b.z}, {a.x - c.x, a.y - c.y, a.z - c.z}}
	for _, edge in ipairs(edges) do
		local x, y, z = edge[1], edge[2], edge[3]
		if not axis(0, z, -y) or not axis(-z, 0, x) or not axis(y, -x, 0) then return end
	end
	if not moving then
		if startPlane + supportMin < -EPSILON and startPlane + supportMax > EPSILON then out.StartSolid = true end
		return
	end
	if enter >= 0 and enter < out.Fraction then
		out.Fraction, out.HitNormal, out.Contents = enter, n, t.contents
		out.Displacement = true
	end
end

function Disp.Trace(root, start, finish, mins, maxs, mask, lo, hi, out)
	if not root or out.AllSolid then return end
	local stack = {root}
	while #stack > 0 do
		local node = stack[#stack]
		stack[#stack] = nil
		if overlaps(node.lo, node.hi, lo, hi) then
			if node.items then
				for _, item in ipairs(node.items) do
					if item.normal then
						if bit.band(item.contents, mask or MASK_PLAYERSOLID) ~= 0 and overlaps(item.lo, item.hi, lo, hi) then sweep(item, start, finish, mins, maxs, out) end
					else stack[#stack + 1] = item end
				end
			else stack[#stack + 1], stack[#stack + 2] = node.left, node.right end
		end
	end
end
