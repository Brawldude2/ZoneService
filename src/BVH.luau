--!optimize 2
--!native
--!strict

local BVH = {}

local Types = require(script.Parent.Types)
local Enums = require(script.Parent.Enums)

type ZoneInfo = Types.ZoneInfo
type Tree = Types.Tree

const ENUM_BLOCK = Enums.Block
const ENUM_BALL = Enums.Ball
const ENUM_CYLINDER = Enums.Cylinder
const MORTON_RANGE = 1023

const EMPTY_TABLE = {} :: any
const EMPTY_BUFFER = buffer.create(1)

local function CreateSpreadLookup(): {number}
	local spread = table.create(MORTON_RANGE + 1) :: {number}
	local maxBit = math.log(MORTON_RANGE + 1, 2)
	
	for i = 0, MORTON_RANGE do
		local value = i
		local result = 0

		for bit = 0, maxBit - 1 do
			local digit = value % 2
			value = (value - digit) / 2

			result += digit * 2 ^ (bit * 3)
		end
		spread[i + 1] = result
	end
	return spread
end

local Spread = CreateSpreadLookup()

local function QuickSort(mortonCodes: {number}, orderedZones: {ZoneInfo}, low: number, high: number)
	while low < high do
		local i = low
		local j = high
		local pivot = mortonCodes[(low + high) // 2]

		while i <= j do
			while mortonCodes[i] < pivot do
				i += 1
			end

			while mortonCodes[j] > pivot do
				j -= 1
			end

			if i <= j then				
				mortonCodes[i], mortonCodes[j] = mortonCodes[j], mortonCodes[i]
				orderedZones[i], orderedZones[j] = orderedZones[j], orderedZones[i]
				i += 1
				j -= 1
			end
		end

		if j - low < high - i then
			if low < j then
				QuickSort(mortonCodes, orderedZones, low, j)
			end
			low = i
		else
			if i < high then
				QuickSort(mortonCodes, orderedZones, i, high)
			end
			high = j
		end
	end
end

local function ComputeMorton(self: Tree, zones: {[ZoneInfo]: boolean}, numZones: number): {number}
	local min, max = self.MinBound, self.MaxBound
	local minX, minY, minZ, maxX, maxY, maxZ = min.x, min.y, min.z, max.x, max.y, max.z	
	local xScale = min.x == max.x and 0 or MORTON_RANGE / (max.x - min.x)
	local yScale = min.y == max.y and 0 or MORTON_RANGE / (max.y - min.y)
	local zScale = min.z == max.z and 0 or MORTON_RANGE / (max.z - min.z)
	
	local orderedZones = self.OrderedZones
	local mortonCodes = self.MortonCodes
	local idx = 1
	
	for zone, _ in zones do
		local pos = zone.Position
		local x, y, z = 
			math.clamp(math.floor((pos.X - minX) * xScale), 0, MORTON_RANGE),
			math.clamp(math.floor((pos.Y - minY) * yScale), 0, MORTON_RANGE),
			math.clamp(math.floor((pos.Z - minZ) * zScale), 0, MORTON_RANGE)
		local morton = Spread[x + 1] + Spread[y + 1] * 2 + Spread[z + 1] * 4
		mortonCodes[idx] = morton
		orderedZones[idx] = zone
		idx += 1
	end
	QuickSort(mortonCodes, orderedZones, 1, numZones)
	return mortonCodes
end

local function AllocateCaches(self: Tree, numZones: number)
	self.OrderedZones = table.create(numZones) :: {ZoneInfo}
	self.MortonCodes = table.create(numZones) :: {number}
end

local function AllocateNodes(self: Tree, nodeCount: number)
	self.NodeCount = nodeCount
	self.NextNode = 0
	if nodeCount == self.PreviousNodeCount then
		table.clear(self.NodeZone)
		return
	end
	self.PreviousNodeCount = nodeCount	
	self.NodeMin = buffer.create(nodeCount * 12)
	self.NodeMax = buffer.create(nodeCount * 12)
	self.NodeSkip = buffer.create(nodeCount * 4)
	self.NodeZone = table.create(nodeCount) :: {ZoneInfo}
end

local function FindSplit(morton: {number}, start: number, finish: number): number
	if start + 1 == finish then
		return start
	end
	
	local firstCode = morton[start]
	local lastCode = morton[finish]
	if firstCode == lastCode then
		return math.floor((start + finish) / 2)
	end
	
	local diff = bit32.bxor(firstCode, lastCode)
	local bit = 31 - bit32.countlz(diff)	
	local mask = bit32.lshift(1, bit)
	local low = start
	local high = finish

	while low < high do
		local mid = math.floor((low + high + 1) / 2)
		local code = morton[mid]
		
		if bit32.band(code, mask) == 0 then
			low = mid
		else
			high = mid - 1
		end
	end
	return low
end

local function BuildTree(self: Tree, morton: {number}, start: number, finish: number): (number, number, number, number, number, number, number, number)
	self.NextNode += 1
	local node = self.NextNode
	local nodeMin = self.NodeMin
	local nodeMax = self.NodeMax
	local nodeSkip = self.NodeSkip

	if start == finish then
		local zone = self.OrderedZones[start]
		local ptrPos = (node - 1) * 12
		local ptrSkip = (node - 1) * 4
		local posLower, posUpper = zone.LowerPosition, zone.UpperPosition
		local lx, ly, lz = posLower.X, posLower.Y, posLower.Z
		local ux, uy, uz = posUpper.X, posUpper.Y, posUpper.Z
		
		buffer.writef32(nodeMin, ptrPos, lx)
		buffer.writef32(nodeMin, ptrPos + 4, ly)
		buffer.writef32(nodeMin, ptrPos + 8, lz)

		buffer.writef32(nodeMax, ptrPos, ux)
		buffer.writef32(nodeMax, ptrPos + 4, uy)
		buffer.writef32(nodeMax, ptrPos + 8, uz)

		buffer.writeu32(nodeSkip, ptrSkip, node + 1)
		self.NodeZone[node] = zone
		
		return node, node + 1, lx, ly, lz, ux, uy, uz
	end

	local split = FindSplit(morton, start, finish)
	local left,
		_,
		leftMinX, leftMinY, leftMinZ,
		leftMaxX, leftMaxY, leftMaxZ =
		BuildTree(self, morton, start, split)

	local right,
		endIdx,
		rightMinX, rightMinY, rightMinZ,
		rightMaxX, rightMaxY, rightMaxZ =
		BuildTree(self, morton, split + 1, finish)

	local minX = math.min(leftMinX, rightMinX)
	local minY = math.min(leftMinY, rightMinY)
	local minZ = math.min(leftMinZ, rightMinZ)

	local maxX = math.max(leftMaxX, rightMaxX)
	local maxY = math.max(leftMaxY, rightMaxY)
	local maxZ = math.max(leftMaxZ, rightMaxZ)

	local ptrSkip = (node - 1) * 4
	buffer.writeu32(nodeSkip, ptrSkip, endIdx)
	
	local ptrPos = (node - 1) * 12
	buffer.writef32(nodeMin, ptrPos, minX)
	buffer.writef32(nodeMin, ptrPos + 4, minY)
	buffer.writef32(nodeMin, ptrPos + 8, minZ)

	buffer.writef32(nodeMax, ptrPos, maxX)
	buffer.writef32(nodeMax, ptrPos + 4, maxY)
	buffer.writef32(nodeMax, ptrPos + 8, maxZ)
	
	return node, endIdx, minX, minY, minZ, maxX, maxY, maxZ
end

local function Build(self: Tree, zones: {[ZoneInfo]: boolean}, numZones: number)
	if numZones < 1 then
		self.NodeCount = 0
		return 
	end

	AllocateCaches(self, numZones)
	local morton = ComputeMorton(self, zones, numZones)
	AllocateNodes(self, numZones * 2 - 1)
	BuildTree(self, morton, 1, numZones)
end

local function Query(self: Tree, pos: Vector3, results: {ZoneInfo})
	local node = 1
	local count = self.NodeCount
	if count <= 0 then return end
	
	local nodeMin, nodeMax = self.NodeMin, self.NodeMax
	local nodeSkip = self.NodeSkip
	local nodeZone = self.NodeZone
	local x, y, z = pos.X, pos.Y, pos.Z

	while node <= count do
		local ptr = (node - 1) * 12
		local xLower, yLower, zLower = 
			buffer.readf32(nodeMin, ptr),
			buffer.readf32(nodeMin, ptr + 4),
			buffer.readf32(nodeMin, ptr + 8)

		local xUpper, yUpper, zUpper = 
			buffer.readf32(nodeMax, ptr),
			buffer.readf32(nodeMax, ptr + 4),
			buffer.readf32(nodeMax, ptr + 8)

		if x >= xLower and x <= xUpper and y >= yLower and y <= yUpper and z >= zLower and z <= zUpper then
			local zone = nodeZone[node]
			node += 1

			if zone then
				table.insert(results, zone)
			end

		else
			node = buffer.readu32(nodeSkip, (node - 1) * 4)
		end
	end
end

local function UpdateBounds(self: Tree, min: Vector3, max: Vector3)
	self.MinBound = vector.min(min :: any, self.MinBound)
	self.MaxBound = vector.max(max :: any, self.MaxBound)
end

local function SetBounds(self: Tree, min: vector, max: vector)
	self.MinBound = min
	self.MaxBound = max
end

local function Reset(self: Tree)
	self.MinBound = vector.create(math.huge, math.huge, math.huge)
	self.MaxBound = vector.create(-math.huge, -math.huge, -math.huge)
	self.NodeCount = 0
	self.NextNode = 0
	self.NodeMin = EMPTY_BUFFER
	self.NodeMax = EMPTY_BUFFER
	self.NodeSkip = EMPTY_BUFFER
	self.NodeZone = EMPTY_TABLE
	self.OrderedZones = EMPTY_TABLE
	self.MortonCodes = EMPTY_TABLE
	self.PreviousNodeCount = 0
end

function BVH.new(): Tree
	local tree: Tree = {
		NodeCount = 0,
		NextNode = 0,
		NodeMin = EMPTY_BUFFER,
		NodeMax = EMPTY_BUFFER,
		NodeSkip = EMPTY_BUFFER,
		NodeZone = EMPTY_TABLE,
		
		OrderedZones = EMPTY_TABLE,
		MortonCodes = EMPTY_TABLE,
		
		MinBound = vector.create(math.huge, math.huge, math.huge),
		MaxBound = vector.create(-math.huge, -math.huge, -math.huge),
		PreviousNodeCount = 0,
		
		Build = Build,
		Query = Query,
		UpdateBounds = UpdateBounds,
		SetBounds = SetBounds,
		Reset = Reset,
	}
	return tree
end

return BVH
