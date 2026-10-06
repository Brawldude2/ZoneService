--!optimize 2
--!native
--!strict

--[[
u5eful's ZoneService
Refactor and pascal case port by 23sinek345

Features:
	- Uses linear bvh tree for O(logN) zone query
	- Can distribute work across multiple frames to increase performance
	- Built in entity-centric and zone-centric signals
	- Supports multiple different shapes and rotated zones
	- Supports dynamic zones (cframe and size)
	- Supports zone groups for independent zone signals
	- Priority system to resolve overlapping zones within the same group
	- Register entities and zones with simple API

For best performance:
	- Do not have many overlapping zones
	- Track fewer entities
	- Use a minimal # of dynamic zones (recommended < 1000)
	- Use a minimal # of zone groups (recommended < 10)
	- Avoid adding same zone to multiple groups
	- Use block zones with (0, 0, 0) orientation whenever possible
	- Use a lower polling rate
]]

local ZoneService = {}

local RunService = game:GetService("RunService")

local Types = require(script.Types)
local Enums = require(script.Enums)
local BVH = require(script.BVH)
local Config = require(script.Config)
local Signal = require(script.UsefulSignal)

type Tree = Types.Tree
type FrameBucket = Types.FrameBucket
type ZoneInfo = Types.ZoneInfo
type EntityInfo = Types.EntityInfo
type Signal<T...> = Types.Signal<T...>

export type Zone = Types.Zone
export type Shape = Types.Shape
export type Group = Types.Group
export type Params = Types.Params
export type Entity = Types.Entity
export type Tracked = Types.Tracked

const VERSION = "v0.4.0"
const SOURCE = "[ZoneService]"
const DEFAULT_PRIORITY = Config.DefaultPriority
const POLLING_RATE = Config.PollingRate
const FRAME_BUCKET_COUNT = 10

const ENUM_BALL = Enums.Ball
const ENUM_BLOCK = Enums.Block
const ENUM_WEDGE = Enums.Wedge
const ENUM_CYLINDER = Enums.Cylinder
const ENUM_CORNERWEDGE = Enums.CornerWedge

const ENUM_MODEL = Enums.Model
const ENUM_OTHER = Enums.Other
const ENUM_PLAYER = Enums.Player

const IdentityRotation = CFrame.identity.Rotation

local function GenerateFrameBuckets(bucketCount: number): {FrameBucket}
	local buckets = table.create(bucketCount)	
	for i = 1, bucketCount do
		buckets[i] = {}
	end
	return buckets :: {FrameBucket}
end

local StaticZoneCount: number = 0
local DynamicZoneCount: number = 0
local StaticZones: {[ZoneInfo]: boolean} = {}
local DynamicZones: {[ZoneInfo]: boolean} = {}

local FrameBuckets: {FrameBucket} = GenerateFrameBuckets(FRAME_BUCKET_COUNT)
local Entities: {[Entity]: EntityInfo} = {}
local EntityBucketIndexLookup: {[Entity]: number} = {}
local BucketSizes: {number} = table.create(FRAME_BUCKET_COUNT, 0)

local StaticRebuildScheduled: boolean = false
local DynamicRebuildScheduled: boolean = false
local StaticTree: Tree = BVH.new()
local DynamicTree: Tree = BVH.new()

-- Adaptive polling config
const HZ_THRESHOLD: number = 4
const HISTORY_LEN: number = 40
local Interval: number = 5
local HistoryDeltaTime: number = 0
local HistoryFrames: number = 0
local Cursor: number = 1
local Accumulator: number = 0

local PollConnection: RBXScriptConnection? = nil
local PollDeferred: boolean = false

local function FireSignal<T>(signal: Signal.Signal<T>?, arg1: T)
	if signal then
		signal:Fire(arg1)
	end
end

local function RandomFloat(min: number, max: number): number
	return min + math.random() * (max - min)
end

local function GetBallRadius(size: Vector3): number
	return math.min(size.X, size.Y, size.Z) * .5
end

local function GetBallAABB(cframe: CFrame, size: Vector3): (Vector3, Vector3)
	local radius = GetBallRadius(size)
	local position = cframe.Position
	local halfSize = Vector3.new(radius, radius, radius)
	local min = position - halfSize
	local max = position + halfSize
	return min, max
end

local function GetRotatedBlockAABB(cframe: CFrame, size: Vector3): (Vector3, Vector3)
	local half = size * 0.5
	local halfX, halfY, halfZ = half.X, half.Y, half.Z
	local right = cframe.RightVector
	local up = cframe.UpVector
	local look = cframe.LookVector
	local position = cframe.Position

	local extent = Vector3.new(
		math.abs(right.X) * halfX + math.abs(up.X) * halfY + math.abs(look.X) * halfZ,
		math.abs(right.Y) * halfX + math.abs(up.Y) * halfY + math.abs(look.Y) * halfZ,
		math.abs(right.Z) * halfX + math.abs(up.Z) * halfY + math.abs(look.Z) * halfZ
	)
	return position - extent, position + extent
end

local function GenericBoundsCheck(position: Vector3, lowerPosition: Vector3, upperPosition: Vector3): boolean
	local x, y, z = position.X, position.Y, position.Z
	if x < lowerPosition.X or x > upperPosition.X then
		return false
	end

	if y < lowerPosition.Y or y > upperPosition.Y then
		return false
	end

	if z < lowerPosition.Z or z > upperPosition.Z then
		return false
	end

	return true
end

local function BallBoundsCheck(position: Vector3, zonePosition: Vector3, radiusSquared: number)
	local diff = zonePosition - position
	return diff.X ^ 2 + diff.Y ^ 2 + diff.Z ^ 2 <= radiusSquared
end

local function CylinderBoundsCheck(position: Vector3, inverseCFrame: CFrame, radiusSquared: number, halfHeight: number): boolean
	local objectPosition = inverseCFrame:PointToWorldSpace(position)
	local planeDistanceSquared = objectPosition.Y^2 + objectPosition.Z^2
	if planeDistanceSquared > radiusSquared then
		return false
	end	
	return math.abs(objectPosition.X) <= halfHeight
end

local function WedgeBoundsCheck(point: Vector3, inverseCFrame: CFrame, slope: number, halfSize: Vector3): boolean
	local localPoint = inverseCFrame:PointToWorldSpace(point)
	local x, y, z = localPoint.X, localPoint.Y, localPoint.Z
	local halfX, halfY, halfZ = halfSize.X, halfSize.Y, halfSize.Z

	if x < -halfX or x > halfX then
		return false
	end

	if z < -halfZ or z > halfZ then
		return false
	end

	if y < -halfY then
		return false
	end	

	local yMax = -halfY + (z + halfZ) * slope
	return y <= yMax
end

local function CornerWedgeBoundsCheck(position: Vector3, inverseCFrame: CFrame, slopeX: number, slopeZ: number, halfSize: Vector3): boolean
	local localPoint = inverseCFrame:PointToWorldSpace(position)
	local x, y, z = localPoint.X, localPoint.Y, localPoint.Z
	local halfX, halfY, halfZ = halfSize.X, halfSize.Y, halfSize.Z

	if x < -halfX or x > halfX then
		return false
	end

	if y < -halfY or y > halfY then
		return false
	end

	if z < -halfZ or z > halfZ then
		return false		
	end

	local yMaxX = -halfY + (x + halfX) * slopeX
	local yMaxZ = -halfY + (halfZ - z) * slopeZ
	return y <= yMaxX and y <= yMaxZ
end

local function IsInZone(position: Vector3, zoneInfo: ZoneInfo): boolean
	local zoneType = zoneInfo.Type
	if zoneType == ENUM_BLOCK and zoneInfo.AxisAligned then
		return GenericBoundsCheck(position, zoneInfo.LowerPosition, zoneInfo.UpperPosition)
	elseif zoneType == ENUM_BLOCK then
		return GenericBoundsCheck(
			(zoneInfo.InverseCFrame :: CFrame):PointToWorldSpace(position),
			-zoneInfo.HalfSize :: Vector3, 
			zoneInfo.HalfSize :: Vector3
		)
	elseif zoneType == ENUM_BALL then
		return BallBoundsCheck(position, zoneInfo.Position, zoneInfo.Radius2 :: number)
	elseif zoneType == ENUM_CYLINDER then
		return CylinderBoundsCheck(position, zoneInfo.InverseCFrame :: CFrame, zoneInfo.Radius2 :: number, 
			zoneInfo.HalfHeight :: number)
	elseif zoneType == ENUM_WEDGE then
		return WedgeBoundsCheck(position, zoneInfo.InverseCFrame :: CFrame, zoneInfo.Slope :: number, 
			zoneInfo.HalfSize :: Vector3)
	elseif zoneType == ENUM_CORNERWEDGE then
		return CornerWedgeBoundsCheck(position, zoneInfo.InverseCFrame :: CFrame, zoneInfo.SlopeX :: number, 
			zoneInfo.SlopeZ :: number, zoneInfo.HalfSize :: Vector3)
	else
		return false
	end
end

local function GetSmallestBucketIndex(): number
	local minSize = math.huge
	local minIndex = 1

	for i, size in BucketSizes do
		if size <= minSize then
			minSize = size
			minIndex = i
		end
	end
	return minIndex
end

local function GetCylinderDimensions(size: Vector3): (number, number)
	local height = size.X
	local radius = math.min(size.Y, size.Z) * .5
	return radius, height
end

local function UpdateBlock(cframe: CFrame, size: Vector3, info: ZoneInfo)
	local axisAligned = cframe.Rotation == IdentityRotation
	local halfSize = size / 2
	info.HalfSize = halfSize
	info.AxisAligned = axisAligned
	
	local upperPosition: Vector3
	local lowerPosition: Vector3
	local position = cframe.Position

	if axisAligned then
		upperPosition = position + halfSize
		lowerPosition = position - halfSize
	else
		lowerPosition, upperPosition = GetRotatedBlockAABB(cframe, size)
	end

	info.LowerPosition = lowerPosition
	info.UpperPosition = upperPosition	
	info.CFrame = cframe
	info.Position = position

	if not axisAligned then
		info.InverseCFrame = cframe:Inverse()
	end
end

local function UpdateBall(cframe: CFrame, size: Vector3, info: ZoneInfo)
	local radius = GetBallRadius(size)
	info.LowerPosition, info.UpperPosition = GetBallAABB(cframe, size)
	info.Radius = radius
	info.Radius2 = radius^2	
	info.CFrame = cframe
	info.Position = cframe.Position
end

local function UpdateCylinder(cframe: CFrame, size: Vector3, info: ZoneInfo)
	local radius, height = GetCylinderDimensions(size)
	info.LowerPosition, info.UpperPosition = GetRotatedBlockAABB(cframe, size)
	info.Radius = radius
	info.Radius2 = radius^2
	info.Height = height
	info.HalfHeight = height/2	
	info.CFrame = cframe
	info.Position = cframe.Position
	info.InverseCFrame = cframe:Inverse()
end

local function UpdateWedge(cframe: CFrame, size: Vector3, info: ZoneInfo)
	info.LowerPosition, info.UpperPosition = GetRotatedBlockAABB(cframe, size)
	info.HalfSize = size / 2
	info.Slope = size.Y / size.Z
	info.CFrame = cframe
	info.Position = cframe.Position
	info.InverseCFrame = cframe:Inverse()
end

local function UpdateCornerWedge(cframe: CFrame, size: Vector3, info: ZoneInfo)
	info.LowerPosition, info.UpperPosition = GetRotatedBlockAABB(cframe, size)
	info.HalfSize = size / 2
	info.SlopeX = size.Y / size.X
	info.SlopeZ = size.Y / size.Z
	info.CFrame = cframe
	info.Position = cframe.Position
	info.InverseCFrame = cframe:Inverse()
end

local function UpdateTreeBounds(tree: Tree, zones: {[ZoneInfo]: boolean})
	local min = vector.create(math.huge, math.huge, math.huge)
	local max = vector.create(-math.huge, -math.huge, -math.huge)

	for zone, _ in zones do
		min = vector.min(zone.LowerPosition :: any, min)
		max = vector.max(zone.UpperPosition :: any, max)
	end
	tree:SetBounds(min, max)
end


local Zone = {}
Zone.__index = Zone

local Group = {}
Group.__index = Group

local Tracked = {}
Tracked.__index = Tracked

function Group.new(): Group
	return setmetatable({
		Zones = {},
		Entities = {},
	}, Group) :: any
end

const DefaultGroup: Group = Group.new()

function Group.Add(self: Group, zone: Zone)
	local groupZones = self.Zones
	if groupZones[zone] then return end
	
	local index = 1
	local groups = ((zone :: any) :: ZoneInfo).Groups
	if groups[1] == DefaultGroup then
		DefaultGroup.Zones[zone] = nil
		groups[1] = self
	else
		local groupCount = #groups + 1
		groups[groupCount] = self
		index = groupCount
	end
	groupZones[zone] = index
end

function Group.Remove(self: Group, zone: Zone)
	local groupIndex = self.Zones[zone]
	if not groupIndex then return end
	
	self.Zones[zone] = nil
	local groups = ((zone :: any) :: ZoneInfo).Groups
	local groupCount = #groups
	if groupCount == 1 then
		groups[1] = DefaultGroup
		DefaultGroup.Zones[zone] = 1
		return
	end
	
	local lastGroup = groups[groupCount]
	groups[groupCount] = nil
	groups[groupIndex] = lastGroup
	lastGroup.Zones[zone] = groupIndex
end

function Group.Destroy(self: Group)
	local entities = self.Entities
	for entity, info in entities do
		local changedSignals = info.ChangedSignals
		local signal = changedSignals[self]
		if signal then 
			signal:DisconnectAll() 
			changedSignals[self] = nil
		end	
		entities[entity] = nil
	end

	for zone, _ in self.Zones do
		self:Remove(zone)
	end
	setmetatable(self, nil)
end

local function CreateZone(cframe: CFrame, size: Vector3, shape: Shape, params: Params?): Zone
	local zoneInfo = {} :: ZoneInfo
	
	if shape == "Block" then
		zoneInfo.Type = ENUM_BLOCK
		UpdateBlock(cframe, size, zoneInfo)
	elseif shape == "Ball" then
		zoneInfo.Type = ENUM_BALL
		UpdateBall(cframe, size, zoneInfo)
	elseif shape == "Cylinder" then
		zoneInfo.Type = ENUM_CYLINDER
		UpdateCylinder(cframe, size, zoneInfo)
	elseif shape == "Wedge" then
		zoneInfo.Type = ENUM_WEDGE
		UpdateWedge(cframe, size, zoneInfo)
	elseif shape == "CornerWedge" then
		zoneInfo.Type = ENUM_CORNERWEDGE
		UpdateCornerWedge(cframe, size, zoneInfo)
	else
		error(`{SOURCE} Unsupported shape: {shape}`)
	end
	
	local isDynamic = false
	local priority = DEFAULT_PRIORITY

	if params then
		if params.IsDynamic ~= nil then
			isDynamic = params.IsDynamic
		end
		if params.Priority then
			priority = params.Priority
		end
		zoneInfo.UserData = params.UserData
	end
	
	zoneInfo.Size = size

	DefaultGroup.Zones[(zoneInfo :: any) :: Zone] = 1
	zoneInfo.Groups = {DefaultGroup}
	zoneInfo.Priority = priority
	zoneInfo.Dynamic = isDynamic
	zoneInfo.Destroyed = false

	if isDynamic then
		DynamicTree:UpdateBounds(zoneInfo.LowerPosition, zoneInfo.UpperPosition)
		DynamicZones[zoneInfo] = true
		DynamicZoneCount += 1
		DynamicRebuildScheduled = true
	else
		StaticZones[zoneInfo] = true
		StaticZoneCount += 1
		StaticRebuildScheduled = true
	end

	return setmetatable(zoneInfo, Zone) :: any
end

function ZoneService.fromPart(part: Part, params: Params?): Zone
	return CreateZone(part.CFrame, part.Size, part.Shape.Name :: Shape, params)
end

function ZoneService:IsTracked(entity: Entity): boolean
	return Entities[entity] ~= nil
end

function ZoneService:Track(entity: Entity): Tracked
	local info = Entities[entity]
	if info ~= nil then
		error(`{SOURCE} Entity {entity} is already tracked`)
	end

	local entityType
	if type(entity) == "table" then
		if not entity.Position then
			error(`{SOURCE} Failed to Track table entity: missing Position field`)
		end
		entityType = ENUM_OTHER

	else
		local name = (entity :: Instance).ClassName
		if name == "Player" then
			entityType = ENUM_PLAYER

		elseif name == "Model" then
			entityType = ENUM_MODEL

		else
			entityType = ENUM_OTHER
		end
	end

	info = {} :: EntityInfo
	info.Type = entityType
	info.CandidateZones = {}
	info.CurrentZones = {}
	info.PreviousZones = {}
	info.ChangedSignals = {}
	info.Active = true

	local bucketIndex = GetSmallestBucketIndex()
	FrameBuckets[bucketIndex][entity] = info
	EntityBucketIndexLookup[entity] = bucketIndex
	BucketSizes[bucketIndex] += 1
	Entities[entity] = info

	return setmetatable({Entity = entity}, Tracked) :: any
end

function ZoneService:Untrack(entity: Entity)
	local bucketIndex = EntityBucketIndexLookup[entity]
	if not bucketIndex then return end 
	
	local info = Entities[entity]
	if not info then return end 

	info.Active = false
	Entities[entity] = nil	
	local bucketInfo = FrameBuckets[bucketIndex]
	if bucketInfo then
		bucketInfo[entity] = nil
	end
	EntityBucketIndexLookup[entity] = nil
	BucketSizes[bucketIndex] -= 1

	for group, signal in info.ChangedSignals do
		signal:DisconnectAll()
		group.Entities[entity] = nil
	end
end


function ZoneService:GetZonesAtPoint(point: Vector3): {Zone}
	local candidateZones = {}
	StaticTree:Query(point, candidateZones)
	DynamicTree:Query(point, candidateZones)
	
	local confirmedZones: {Zone} = {}
	for _, zoneInfo in candidateZones do
		if IsInZone(point, zoneInfo) and not zoneInfo.Destroyed then
			table.insert(confirmedZones, (zoneInfo :: any) :: Zone)
		end
	end
	return confirmedZones
end

function Zone.IsPointInside(self: Zone, point: Vector3): boolean
	return IsInZone(point, (self :: any) :: ZoneInfo)
end

function Zone.GetRandomPointInside(self: Zone): Vector3
	local zoneInfo = (self :: any) :: ZoneInfo
	local shape = zoneInfo.Type
	if shape == ENUM_BLOCK then
		local half = zoneInfo.HalfSize :: Vector3
		local cframe = zoneInfo.CFrame	
		return cframe:PointToWorldSpace(Vector3.new(
			RandomFloat(-half.X, half.X),
			RandomFloat(-half.Y, half.Y),
			RandomFloat(-half.Z, half.Z)
		))
	elseif shape == ENUM_BALL then
		local radius = zoneInfo.Radius :: number
		local cframe = zoneInfo.CFrame
		local z = RandomFloat(-1, 1)
		local theta = RandomFloat(0, math.pi * 2)
		local radial = math.sqrt(1 - z * z)
		local distance = radius * math.random() ^ (1 / 3)
		local point = Vector3.new(radial * math.cos(theta), z, radial * math.sin(theta)) * distance
		return cframe:PointToWorldSpace(point)
	elseif shape == ENUM_CYLINDER then
		local radius = zoneInfo.Radius :: number
		local halfHeight = zoneInfo.HalfHeight :: number
		local cframe = zoneInfo.CFrame

		local theta = RandomFloat(0, math.pi * 2)
		local distance = radius * math.sqrt(math.random())

		local point = Vector3.new(
			RandomFloat(-halfHeight, halfHeight),
			math.cos(theta) * distance,
			math.sin(theta) * distance
		)
		return cframe:PointToWorldSpace(point)
	elseif shape == ENUM_WEDGE then
		local halfSize = zoneInfo.HalfSize :: Vector3
		local halfX, halfY, halfZ = halfSize.X, halfSize.Y, halfSize.Z
		local r1 = math.random()
		local r2 = math.random()
		if r1 + r2 > 1 then
			r1 = 1 - r1
			r2 = 1 - r2
		end

		local x = (math.random() * 2 - 1) * halfX
		local y = -halfY + r2 * (2 * halfY)
		local z = -halfZ + (r1 + r2) * (2 * halfZ)
		return zoneInfo.CFrame:PointToWorldSpace(Vector3.new(x, y, z))
	elseif shape == ENUM_CORNERWEDGE then
		local halfSize = zoneInfo.HalfSize :: Vector3
		local halfX, halfY, halfZ = halfSize.X, halfSize.Y, halfSize.Z	
		local a = math.random()
		local b = math.random()
		local c = math.random()

		if a > b then
			a, b = b, a
		end
		if b > c then
			b, c = c, b
		end
		if a > b then
			a, b = b, a
		end

		local u, v
		if math.random() < 0.5 then
			u, v = b, c
		else
			u, v = c, b
		end

		local x = u * 2 * halfX - halfX
		local y = a * 2 * halfY - halfY
		local z = halfZ - v * 2 * halfZ
		return zoneInfo.CFrame:PointToWorldSpace(Vector3.new(x, y, z))
	else
		return Vector3.zero
	end
end

function Zone.Destroy(self: Zone)
	if self.Destroyed then return end 
	self.Destroyed = true
	
	local zoneInfo = (self :: any) :: ZoneInfo
	local static, dynamic = StaticZones[zoneInfo], DynamicZones[zoneInfo]
	if not static and not dynamic then return end
	
	StaticZones[zoneInfo] = nil
	DynamicZones[zoneInfo] = nil

	local enteredSignal = zoneInfo.Entered
	if enteredSignal then
		enteredSignal:DisconnectAll()
	end

	local groups = zoneInfo.Groups	
	local exitSignal = zoneInfo.Exited
	for entity, entityInfo in Entities do
		local prevZones = entityInfo.PreviousZones
		for _, group in groups do
			if prevZones[group] ~= zoneInfo then continue end 
			FireSignal(exitSignal, entity)
			prevZones[group] = nil
		end
	end
	if exitSignal then
		exitSignal:DisconnectAll()
	end

	while groups[1] ~= DefaultGroup do
		local group = groups[#groups]
		group:Remove((zoneInfo :: any) :: Zone)
	end
	groups[1] = nil
	DefaultGroup.Zones[self] = nil

	if static then
		StaticRebuildScheduled = true
		StaticZoneCount -= 1
	else
		DynamicRebuildScheduled = true
		DynamicZoneCount -= 1
	end
	
	setmetatable(self, nil)
end

function Zone.Update(self: Zone, cframe: CFrame?, size: Vector3?)
	local zoneInfo = (self :: any) :: ZoneInfo
	local dynamic = DynamicZones[zoneInfo]
	local static = StaticZones[zoneInfo]

	cframe = cframe or zoneInfo.CFrame
	size = size or zoneInfo.Size
	local shape = zoneInfo.Type

	if shape == ENUM_BLOCK then
		UpdateBlock(cframe :: CFrame, size :: Vector3, zoneInfo)	
	elseif shape == ENUM_BALL then
		UpdateBall(cframe :: CFrame, size :: Vector3, zoneInfo)
	elseif shape == ENUM_CYLINDER then
		UpdateCylinder(cframe :: CFrame, size :: Vector3, zoneInfo)
	elseif shape == ENUM_WEDGE then
		UpdateWedge(cframe :: CFrame, size :: Vector3, zoneInfo)
	elseif shape == ENUM_CORNERWEDGE then
		UpdateCornerWedge(cframe :: CFrame, size :: Vector3, zoneInfo)
	end

	if static then
		StaticRebuildScheduled = true
	else
		DynamicTree:UpdateBounds(zoneInfo.LowerPosition, zoneInfo.UpperPosition)
		DynamicRebuildScheduled = true
	end
end

local function GetSignal(key: any, info: {[any]: any} | ZoneInfo): Signal<any>
	local signal = info[key]
	if not signal then
		signal = Signal.new()
		info[key] = signal
	end
	return signal
end

function Zone.OnEnter(self: Zone, callback: (entity: Entity) -> ()): Signal.Connection<Entity>
	local signal = GetSignal("Entered", (self :: any) :: ZoneInfo)
	return signal:Connect(callback)
end

function Zone.OnExit(self: Zone, callback: (entity: Entity) -> ()): Signal.Connection<Entity>
	local signal = GetSignal("Exited", (self :: any) :: ZoneInfo)
	return signal:Connect(callback)
end

function Tracked.OnZoneChange(self: Tracked, group: Group, callback: (zone: Zone?) -> (), prefire: boolean?): Signal.Connection<Zone?>
	local entity = self.Entity
	local entityInfo = Entities[entity]
	local signal = GetSignal(group, entityInfo.ChangedSignals)	
	if prefire ~= false then		
		callback((entityInfo.PreviousZones[group] :: any) :: Zone)
	end	
	group.Entities[entity] = entityInfo
	return signal:Connect(callback)
end

function Tracked.GetZones(self: Tracked): {Zone}
	local entityInfo = Entities[self.Entity]
	local zones = {}
	for _, zone in entityInfo.PreviousZones do
		table.insert(zones, (zone :: any) :: Zone)
	end
	return zones
end

function ZoneService.BallSize(radius: number): Vector3
	return Vector3.new(radius, radius, radius)
end

function ZoneService.CylinderSize(radius: number, height: number): Vector3
	return Vector3.new(height, radius, radius)
end

local function ResolvePriority(zone: ZoneInfo, currentZones: {[Group]: ZoneInfo})
	local priority = zone.Priority
	for _, group in zone.Groups do
		local currentZone = currentZones[group]
		local current = if currentZone then currentZone.Priority else -math.huge

		if priority > current then
			currentZones[group] = zone
		end
	end
end

local function Poll(dt: number)
	if StaticRebuildScheduled then
		if not PollDeferred then
			PollDeferred = true
			return
		end
		UpdateTreeBounds(StaticTree, StaticZones)
		StaticTree:Build(StaticZones, StaticZoneCount)
		StaticRebuildScheduled = false
		PollDeferred = false
		return
	end

	if DynamicRebuildScheduled then
		DynamicTree:Build(DynamicZones, DynamicZoneCount)
		DynamicRebuildScheduled = false
	end

	if HistoryFrames >= HISTORY_LEN then
		local fps = HistoryFrames / HistoryDeltaTime
		local avgHz = fps / Interval	

		if avgHz - POLLING_RATE > HZ_THRESHOLD then
			Interval = math.min(Interval + 1, FRAME_BUCKET_COUNT)

		elseif POLLING_RATE - avgHz > HZ_THRESHOLD then
			Interval = math.max(Interval - 1, 1)
		end
		HistoryFrames = 0
		HistoryDeltaTime = 0
	end

	HistoryFrames += 1
	HistoryDeltaTime += dt
	Accumulator += FRAME_BUCKET_COUNT / Interval

	while Accumulator >= 1 do
		Accumulator -= 1		
		for entity: Entity, entityInfo: EntityInfo in FrameBuckets[Cursor] do
			if not entityInfo.Active or not entity then
				continue
			end
			
			local entityType = entityInfo.Type
			local entityCandidateZones = entityInfo.CandidateZones
			local currentEntityZones = entityInfo.CurrentZones
			local previousEntityZones = entityInfo.PreviousZones
			local entityChangedSignals = entityInfo.ChangedSignals
			local position

			if entityType == ENUM_PLAYER then
				local character = (entity :: Player).Character
				if not character then
					entityInfo.RootPart = nil
					continue
				end
				
				if character ~= entityInfo.Character then
					local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart
					if rootPart and rootPart:IsA("BasePart") then
						entityInfo.Character = character
						entityInfo.RootPart = rootPart
					end
				end

				local rootPart = entityInfo.RootPart
				if not rootPart then
					continue
				end
				
				position = rootPart.Position
			elseif entityType == ENUM_MODEL then
				position = (entity :: Model):GetPivot().Position
			else
				position = (entity :: any).Position
			end

			table.clear(currentEntityZones)
			table.clear(entityCandidateZones)
			StaticTree:Query(position, entityCandidateZones)
			DynamicTree:Query(position, entityCandidateZones)

			for _, zone in entityCandidateZones do			
				if not IsInZone(position, zone) then
					continue
				end

				ResolvePriority(zone, currentEntityZones)
			end

			for group, previousZone: ZoneInfo in previousEntityZones do
				local currentZone = currentEntityZones[group]
				if previousZone == currentZone then continue end		
				
				FireSignal(previousZone.Exited, entity)
				
				-- Carry the previous zone information over to the entry checker loop
				if not currentZone then
					FireSignal(entityChangedSignals[group], nil)
					previousEntityZones[group] = nil
				end
			end

			for group, currentZone: ZoneInfo in currentEntityZones do
				local previousZone = previousEntityZones[group]
				if currentZone == previousZone then continue end
				
				FireSignal(currentZone.Entered, entity)
				if not previousZone or previousZone.UnionId ~= currentZone.UnionId then
					FireSignal(entityChangedSignals[group], (currentZone :: any) :: Zone)
				end
				
				previousEntityZones[group] = currentZone
			end			
		end

		Cursor += 1
		if Cursor > FRAME_BUCKET_COUNT then
			Cursor = 1
		end
	end
end

function ZoneService:StopPolling()
	if PollConnection then
		PollConnection:Disconnect()
		PollConnection = nil
	end
end

function ZoneService:StartPolling()
	if PollConnection then return end
	PollConnection = RunService.Heartbeat:Connect(Poll)
end

function ZoneService:RebuildStaticBVH()
	StaticRebuildScheduled = true
end

function ZoneService:RebuildDynamicBVH()
	DynamicRebuildScheduled = true
end

function ZoneService:UpdateDynamicBounds()
	UpdateTreeBounds(DynamicTree, DynamicZones)
end

PollConnection = RunService.Heartbeat:Connect(Poll)

ZoneService.new = CreateZone
ZoneService.Group = Group

print(`{SOURCE} ZoneService {VERSION} started!`)

return ZoneService