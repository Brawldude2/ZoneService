--!optimize 2
--!native
--!strict

--[[
u5eful's ZoneService

Features:
-Uses linear bvh tree for O(logN) zone query
-Can distribute work across multiple frames to increase performance
-Built in entity-centric and zone-centric signals
-Supports multiple different shapes and rotated zones
-Supports dynamic zones (cframe and size)
-Supports observers for independent zone signals
-Priority system to resolve overlapping zones under the same observer
-Register entities and zones with simple API

For best performance:
-Do not have many overlapping zones
-Track fewer entities
-Use a minimal # of dynamic zones (recommended < 500)
-Use a minimal # of observers (recommended < 10)
-Avoid adding same zone to multiple observers
-Use block zones with (0, 0, 0) orientation whenever possible
-Use a lower polling rate and turn on performance mode
]]

local RunService = game:GetService("RunService")

local Types = require(script.Types)
local Enums = require(script.Enums)
local BVH = require(script.BVH)
local Config = require(script.Config)
local Signal = require(script.UsefulSignal)

const VERSION = "v0.5.0"
const SOURCE = "[ZoneService]"
const DEFAULT_PRIORITY = Config.DefaultPriority
const POLLING_RATE = Config.PollingRate
const PERF_MODE = Config.PerformanceMode
const NUM_BUCKETS = 10
const ENUM_BLOCK = Enums.Block
const ENUM_BALL = Enums.Ball
const ENUM_CYLINDER = Enums.Cylinder
const ENUM_WEDGE = Enums.Wedge
const ENUM_CORNERWEDGE = Enums.CornerWedge
const ENUM_PLAYER = Enums.Player
const ENUM_MODEL = Enums.Model
const ENUM_OTHER = Enums.Other

type Signal<T...> = Types.Signal<T...>
type ZoneInfo = Types.ZoneInfo
type EntityInfo = Types.EntityInfo
type Bucket = Types.Bucket
type Tree = Types.Tree

export type Params = Types.Params
export type Entity = Types.Entity
export type Shape = Types.Shape
export type Zone = Types.Zone
export type Zones = Types.Zones
export type Tracked = Types.Tracked
export type Observer = Types.Observer

local function getFrameBuckets(numBuckets: number): {Bucket}
	local buckets = table.create(numBuckets)	
	for i = 1, numBuckets do
		buckets[i] = {}
	end
	return buckets :: {Bucket}
end

local numStaticZones: number = 0
local numDynamicZones: number = 0
local zones: {[ZoneInfo]: boolean} = {}
local dynamicZones: {[ZoneInfo]: boolean} = {}

local entities: {Bucket} = getFrameBuckets(NUM_BUCKETS)
local entitiesTracker: {[Entity]: EntityInfo} = {}
local entitiesBucketIdx: {[Entity]: number} = {}
local bucketSizes: {number} = table.create(NUM_BUCKETS, 0)

local rebuildStatic: boolean = false
local rebuildDynamic: boolean = false
local staticTree: Tree = BVH.new()
local dynamicTree: Tree = BVH.new()

local function getRadiusBall(size: Vector3): number
	return math.min(size.X, size.Y, size.Z) * .5
end

local function getBallAABB(cframe: CFrame, size: Vector3): (Vector3, Vector3)
	local radius = getRadiusBall(size)
	local pos = cframe.Position
	local halfSize = Vector3.new(radius, radius, radius)
	local min = pos - halfSize
	local max = pos + halfSize
	return min, max
end

local function getRotatedBlockAABB(cframe: CFrame, size: Vector3): (Vector3, Vector3)
	local half = size * 0.5
	local halfX, halfY, halfZ = half.X, half.Y, half.Z
	local right = cframe.RightVector
	local up = cframe.UpVector
	local look = cframe.LookVector
	local pos = cframe.Position

	local extent = Vector3.new(
		math.abs(right.X) * halfX + math.abs(up.X) * halfY + math.abs(look.X) * halfZ,
		math.abs(right.Y) * halfX + math.abs(up.Y) * halfY + math.abs(look.Y) * halfZ,
		math.abs(right.Z) * halfX + math.abs(up.Z) * halfY + math.abs(look.Z) * halfZ
	)
	return pos - extent, pos + extent
end

local function basicBoundsCheck(pos: Vector3, posLower: Vector3, posUpper: Vector3): boolean
	local x, y, z = pos.X, pos.Y, pos.Z
	if x < posLower.X or x > posUpper.X then
		return false
	end

	if y < posLower.Y or y > posUpper.Y then
		return false
	end

	if z < posLower.Z or z > posUpper.Z then
		return false
	end

	return true
end

local function ballBoundsCheck(pos: Vector3, zonePos: Vector3, radius2: number)
	local diff = zonePos - pos
	return diff.X^2 + diff.Y^2 + diff.Z^2 <= radius2
end

local function cylinderBoundsCheck(pos: Vector3, inverseCFrame: CFrame, radius2: number, halfHeight: number): boolean
	local objectPos = inverseCFrame:PointToWorldSpace(pos)
	local planeDist2 = objectPos.Y^2 + objectPos.Z^2
	if planeDist2 > radius2 then
		return false
	end	
	return math.abs(objectPos.X) <= halfHeight
end

local function wedgeBoundsCheck(point: Vector3, inverseCFrame: CFrame, slope: number, halfSize: Vector3): boolean
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

local function cornerWedgeBoundsCheck(pos: Vector3, inverseCFrame: CFrame, slopeX: number, slopeZ: number,
	halfSize: Vector3): boolean
	local localPoint = inverseCFrame:PointToWorldSpace(pos)
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

local function getSmallestBucket(): number
	local smallestSize = math.huge
	local smallestIdx = 1

	for i, size in bucketSizes do
		if size <= smallestSize then
			smallestSize = size
			smallestIdx = i
		end
	end
	return smallestIdx
end

local function getDimensionsCylinder(size: Vector3): (number, number)
	local height = size.X
	local radius = math.min(size.Y, size.Z) * .5
	return radius, height
end

const identityRotation = CFrame.identity.Rotation

local function updateBlock(cframe: CFrame, size: Vector3, info: ZoneInfo)
	local axisAligned = cframe.Rotation == identityRotation
	local halfSize = size / 2
	info.HalfSize = halfSize
	info.AxisAligned = axisAligned
	local posUpper
	local posLower
	local position = cframe.Position

	if axisAligned then
		posUpper = position + halfSize
		posLower = position - halfSize
	else
		posLower, posUpper = getRotatedBlockAABB(cframe, size)
	end
	
	info.PosLower = posLower
	info.PosUpper = posUpper	
	info.CFrame = cframe
	info.Pos = position
	
	if not axisAligned then
		info.InverseCFrame = cframe:Inverse()
	end
end

local function updateBall(cframe: CFrame, size: Vector3, info: ZoneInfo)
	local radius = getRadiusBall(size)
	info.PosLower, info.PosUpper = getBallAABB(cframe, size)
	info.Radius = radius
	info.Radius2 = radius^2	
	info.CFrame = cframe
	info.Pos = cframe.Position
end

local function updateCylinder(cframe: CFrame, size: Vector3, info: ZoneInfo)
	local radius, height = getDimensionsCylinder(size)
	info.PosLower, info.PosUpper = getRotatedBlockAABB(cframe, size)
	info.Radius = radius
	info.Radius2 = radius^2
	info.Height = height
	info.HalfHeight = height/2	
	info.CFrame = cframe
	info.Pos = cframe.Position
	info.InverseCFrame = cframe:Inverse()
end

local function updateWedge(cframe: CFrame, size: Vector3, info: ZoneInfo)
	info.PosLower, info.PosUpper = getRotatedBlockAABB(cframe, size)
	info.HalfSize = size / 2
	info.Slope = size.Y / size.Z
	info.CFrame = cframe
	info.Pos = cframe.Position
	info.InverseCFrame = cframe:Inverse()
end

local function updateCornerWedge(cframe: CFrame, size: Vector3, info: ZoneInfo)
	info.PosLower, info.PosUpper = getRotatedBlockAABB(cframe, size)
	info.HalfSize = size / 2
	info.SlopeX = size.Y / size.X
	info.SlopeZ = size.Y / size.Z
	info.CFrame = cframe
	info.Pos = cframe.Position
	info.InverseCFrame = cframe:Inverse()
end

local function updateTreeBounds(tree: Tree, zones: {[ZoneInfo]: boolean})
	local min = vector.create(math.huge, math.huge, math.huge)
	local max = vector.create(-math.huge, -math.huge, -math.huge)

	for zone, _ in zones do
		min = vector.min(zone.PosLower :: any, min)
		max = vector.max(zone.PosUpper :: any, max)
	end
	tree:setBounds(min, max)
end

local function getSignal(key: any, info: {[any]: any} | ZoneInfo | Observer): Signal<any>
	local signal = info[key]
	if not signal then
		signal = Signal.new()
		info[key] = signal
	end
	return signal
end

--API start
local ZoneService = {}

local Zone = {}
Zone.__index = Zone

local Zones = {}
Zones.__index = Zones

local Observer = {}
Observer.__index = Observer

local Tracked = {}
Tracked.__index = Tracked

local function newObserver(): Observer
	return setmetatable({
		zones = {},
		entities = {},
	}, Observer) :: Observer
end

function Observer.add(self: Observer, zone: Zone)
	local zones = self.zones
	if zones[zone] then return end 
	local observers = (zone :: ZoneInfo).observers
	local idx = #observers + 1
	observers[idx] = self
	zones[zone] = idx
end

function Observer.remove(self: Observer, zone: Zone)
	local zones = self.zones
	local idx = zones[zone]
	if not idx then return end
	zones[zone] = nil
	local observers = (zone :: ZoneInfo).observers
	local numObservers = #observers
	local last = observers[numObservers]
	observers[numObservers] = nil
	if idx ~= numObservers then
		observers[idx] = last
		last.zones[zone] = idx
	end
end

function Observer.onEnter(self: Observer, zone: Zone | Zones, callback: (entity: Entity) -> ()): Signal.Connection<Entity>
	local signal = getSignal("EnteredSignal", zone)
	return signal:Connect(function(entity, observer)
		if observer ~= self then return end 
		callback(entity)
	end)
end

function Observer.onExit(self: Observer, zone: Zone | Zones, callback: (entity: Entity) -> ()): Signal.Connection<Entity>
	local signal = getSignal("ExitedSignal", zone)
	return signal:Connect(function(entity, observer)
		if observer ~= self then return end 
		callback(entity)
	end)
end

function Observer.onZoneChange(self: Observer, tracked: Tracked, callback: (zone: Zone?) -> (), prefire: boolean?)
	: Signal.Connection<Zone?>
	local entity = tracked.entity
	local info = entitiesTracker[entity]
	if not info then
		error(`{SOURCE} Cannot observe onZoneChange on untracked entity`)
	end
	local signal = getSignal(self, info.ChangedSignals)	
	if prefire ~= false then
		callback(info.PrevZones[self] :: Zone?)
	end	
	self.entities[entity] = info
	return signal:Connect(callback)
end

function Observer.destroy(self: Observer)
	local entities = self.entities
	for entity, info in entities do
		local changedSignals = info.ChangedSignals
		local signal = changedSignals[self]
		if signal then 
			signal:DisconnectAll() 
			changedSignals[self] = nil
		end	
		entities[entity] = nil
	end
	
	for zone, _ in self.zones do
		self:remove(zone)
	end
	setmetatable(self, nil)
end

ZoneService.Observer = {new = newObserver}

local function createZone(cframe: CFrame, size: Vector3, shape: Shape, params: 
	{priority: number?, dynamic: boolean?, metadata: any}?)
	: Zone
	local info = {} :: ZoneInfo
	if shape == "Block" then
		info.Type = ENUM_BLOCK
		updateBlock(cframe, size, info)

	elseif shape == "Ball" then
		info.Type = ENUM_BALL
		updateBall(cframe, size, info)

	elseif shape == "Cylinder" then
		info.Type = ENUM_CYLINDER
		updateCylinder(cframe, size, info)

	elseif shape == "Wedge" then
		info.Type = ENUM_WEDGE
		updateWedge(cframe, size, info)

	elseif shape == "CornerWedge" then
		info.Type = ENUM_CORNERWEDGE
		updateCornerWedge(cframe, size, info)

	else
		error(`{SOURCE} Unsupported shape: {shape}`)
	end
	info.Size = size

	local dynamic = false
	local priority = DEFAULT_PRIORITY
	
	if params then
		dynamic = params.dynamic or dynamic
		priority = params.priority or priority
		info.metadata = params.metadata	
	end
	
	info.observers = {}
	info.priority = priority
	info.isDynamic = dynamic
	info.destroyed = false

	if dynamic then
		dynamicTree:updateBounds(info.PosLower, info.PosUpper)
		dynamicZones[info] = true
		numDynamicZones += 1
		rebuildDynamic = true

	else
		zones[info] = true
		numStaticZones += 1
		rebuildStatic = true
	end
	
	return setmetatable(info, Zone) :: Zone
end

ZoneService.new = createZone

function ZoneService.fromPart(part: Part, params: {priority: number?, dynamic: boolean?, metadata: any}?): Zone
	return createZone(part.CFrame, part.Size, part.Shape.Name :: Shape, params)
end

function ZoneService.fromZones(zones: {Zone}): Zones
	local enterSignal, exitSignal = Signal.new(), Signal.new()
	local unionZones = {}
	local union = {
		zones = unionZones,
		EnteredSignal = enterSignal,
		ExitedSignal = exitSignal
	}
	
	for _, zone: any in zones do
		if zone.union then
			warn(`{SOURCE} Zone skipped: already in a collection`)
			continue
		end
		zone.union = union
		zone.cachedEnteredSignal = zone.EnteredSignal
		zone.cachedExitedSignal = zone.ExitedSignal
		zone.EnteredSignal = enterSignal
		zone.ExitedSignal = exitSignal
		unionZones[zone] = true
	end	
	return setmetatable(union, Zones) :: Zones
end

function ZoneService.isTracked(self: ZoneService, entity: Entity): boolean
	return entitiesTracker[entity] ~= nil
end

function ZoneService.track(self: ZoneService, entity: Entity): Tracked
	local info = entitiesTracker[entity]
	if info ~= nil then
		error(`{SOURCE} Entity {entity} is already tracked`)
	end
	
	local entityType
	if type(entity) == "table" then
		if not entity.Position then
			error(`{SOURCE} Failed to track table entity: missing Position field`)
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
	info.Candidates = {}
	info.CurrZones = {}
	info.PrevZones = {}
	info.ChangedSignals = {}
	info.Active = true
	
	local bucketIdx = getSmallestBucket()
	entities[bucketIdx][entity] = info
	entitiesBucketIdx[entity] = bucketIdx
	bucketSizes[bucketIdx] += 1
	entitiesTracker[entity] = info
	
	return setmetatable({entity = entity}, Tracked) :: Tracked
end

function ZoneService.untrack(self: ZoneService, entity: Entity)
	local bucketIdx = entitiesBucketIdx[entity]
	if not bucketIdx then return end 	
	local info = entitiesTracker[entity]
	if not info then return end 
	
	info.Active = false
	entitiesTracker[entity] = nil	
	local bucketInfo = entities[bucketIdx]
	if bucketInfo then
		bucketInfo[entity] = nil
	end
	entitiesBucketIdx[entity] = nil
	bucketSizes[bucketIdx] -= 1
	
	for observer, signal in info.ChangedSignals do
		signal:DisconnectAll()
		observer.entities[entity] = nil
	end
end

local function checkInZone(pos: Vector3, info: ZoneInfo): boolean
	local inBounds = false
	local zoneType = info.Type

	if zoneType == ENUM_BLOCK and info.AxisAligned then
		inBounds = basicBoundsCheck(pos, info.PosLower, info.PosUpper)

	elseif zoneType == ENUM_BLOCK then
		inBounds = basicBoundsCheck(
			(info.InverseCFrame :: CFrame):PointToWorldSpace(pos),
			-info.HalfSize :: Vector3, 
			info.HalfSize :: Vector3
		)

	elseif zoneType == ENUM_BALL then
		inBounds = ballBoundsCheck(pos, info.Pos, info.Radius2 :: number)

	elseif zoneType == ENUM_CYLINDER then
		inBounds = cylinderBoundsCheck(pos, info.InverseCFrame :: CFrame, info.Radius2 :: number, 
			info.HalfHeight :: number)

	elseif zoneType == ENUM_WEDGE then
		inBounds = wedgeBoundsCheck(pos, info.InverseCFrame :: CFrame, info.Slope :: number, 
			info.HalfSize :: Vector3)

	else --cornerwedge
		inBounds = cornerWedgeBoundsCheck(pos, info.InverseCFrame :: CFrame, info.SlopeX :: number, 
			info.SlopeZ :: number, info.HalfSize :: Vector3)
	end
	return inBounds
end

function ZoneService.getZonesAtPoint(self: ZoneService, point: Vector3): {Zone}
	local zones = {}
	staticTree:query(point, zones)
	dynamicTree:query(point, zones)
	local finalZones = {}

	for _, info in zones do
		if not checkInZone(point, info) or info.destroyed then
			continue
		end
		table.insert(finalZones, info :: Zone)
	end
	return finalZones
end

function Zones.add(self: Zones, zone: Zone)
	local zones = self.zones
	if (zone :: any).union ~= nil then
		warn(`{SOURCE} Failed to add zone to collection: already in one`)
		return
	end
	zones[zone] = true
	zone = zone :: any
	zone.union = self
	zone.cachedEnteredSignal = zone.EnteredSignal
	zone.cachedExitedSignal = zone.ExitedSignal
	zone.EnteredSignal = (self :: any).EnteredSignal
	zone.ExitedSignal = (self :: any).ExitedSignal
end

function Zones.remove(self: Zones, zone: Zone)
	local zones = self.zones
	if not zones[zone] then return end 
	zones[zone] = nil
	zone = zone :: any
	zone.union = nil
	zone.EnteredSignal = zone.cachedEnteredSignal
	zone.ExitedSignal = zone.cachedExitedSignal
	zone.cachedEnteredSignal = nil
	zone.cachedExitedSignal = nil
end

function Zones.destroy(self: Zones)
	local exitSignal = (self :: any).ExitedSignal
	local enterSignal = (self :: any).EnteredSignal
	
	for entity, info in entitiesTracker do
		local prevZones = info.PrevZones
		for observer, zone in prevZones do
			if zone.union ~= self then continue end
			if exitSignal then exitSignal:Fire(entity, observer) end
			prevZones[observer] = nil
		end
	end
	
	for zone, _ in self.zones do
		self:remove(zone)		
	end
	if exitSignal then
		exitSignal:DisconnectAll()
	end
	if enterSignal then
		enterSignal:DisconnectAll()
	end
	setmetatable(self, nil)
end

function Zone.isPointInside(self: Zone, point: Vector3): boolean
	return checkInZone(point, self :: ZoneInfo)
end

local function randomFloat(min: number, max: number): number
	return min + math.random() * (max - min)
end

function Zone.getRandomPointInside(self: Zone): Vector3
	local info = self :: ZoneInfo
	local shape = info.Type
	if shape == ENUM_BLOCK then
		local half = info.HalfSize :: Vector3
		local cframe = info.CFrame	
		return cframe:PointToWorldSpace(Vector3.new(
			randomFloat(-half.X, half.X),
			randomFloat(-half.Y, half.Y),
			randomFloat(-half.Z, half.Z)
			))

	elseif shape == ENUM_BALL then
		local radius = info.Radius :: number
		local cframe = info.CFrame
		local z = randomFloat(-1, 1)
		local theta = randomFloat(0, math.pi * 2)
		local radial = math.sqrt(1 - z * z)
		local distance = radius * math.random() ^ (1 / 3)
		local point = Vector3.new(radial * math.cos(theta), z, radial * math.sin(theta)) * distance
		return cframe:PointToWorldSpace(point)

	elseif shape == ENUM_CYLINDER then
		local radius = info.Radius :: number
		local halfHeight = info.HalfHeight :: number
		local cframe = info.CFrame

		local theta = randomFloat(0, math.pi * 2)
		local distance = radius * math.sqrt(math.random())

		local point = Vector3.new(
			randomFloat(-halfHeight, halfHeight),
			math.cos(theta) * distance,
			math.sin(theta) * distance
		)
		return cframe:PointToWorldSpace(point)

	elseif shape == ENUM_WEDGE then
		local halfSize = info.HalfSize :: Vector3
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
		return info.CFrame:PointToWorldSpace(Vector3.new(x, y, z))

	else --cornerwedge
		local halfSize = info.HalfSize :: Vector3
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
		return info.CFrame:PointToWorldSpace(Vector3.new(x, y, z))		
	end
end

function Zone.destroy(self: Zone)
	if self.destroyed then return end 
	self.destroyed = true
	local zone = self :: ZoneInfo
	local static, dynamic = zones[zone], dynamicZones[zone]
	if not static and not dynamic then return end
	zones[zone] = nil
	dynamicZones[zone] = nil
	
	local observers = zone.observers	
	local exitSignal = zone.ExitedSignal
	for entity, entityInfo in entitiesTracker do
		local prevZones = entityInfo.PrevZones
		for _, observer in observers do
			if prevZones[observer] ~= zone then continue end 
			if exitSignal then exitSignal:Fire(entity, observer) end
			prevZones[observer] = nil
		end
	end
	local union = zone.union
	if union then
		union:remove(self)
	end
	if exitSignal then exitSignal:DisconnectAll() end
	local enteredSignal = zone.EnteredSignal
	if enteredSignal then
		enteredSignal:DisconnectAll()
	end
	
	while #observers > 0 do
		local observer = observers[1]
		observer:remove(zone :: Zone)
	end
	
	if static then
		rebuildStatic = true
		numStaticZones -= 1
	else
		rebuildDynamic = true
		numDynamicZones -= 1
	end
	setmetatable(self, nil)
end

function Zone.update(self: Zone, cframe: CFrame?, size: Vector3?)
	local info = self :: ZoneInfo
	local dynamic = dynamicZones[info]
	local static = zones[info]

	cframe = cframe or info.CFrame
	if size then
		info.Size = size
	else
		size = info.Size
	end
	local shape = info.Type

	if shape == ENUM_BLOCK then
		updateBlock(cframe, size :: Vector3, info)	

	elseif shape == ENUM_BALL then
		updateBall(cframe, size :: Vector3, info)

	elseif shape == ENUM_CYLINDER then
		updateCylinder(cframe, size :: Vector3, info)

	elseif shape == ENUM_WEDGE then
		updateWedge(cframe, size :: Vector3, info)

	else
		updateCornerWedge(cframe, size :: Vector3, info)
	end

	if static then
		rebuildStatic = true
		
	elseif dynamic then
		dynamicTree:updateBounds(info.PosLower, info.PosUpper)
		rebuildDynamic = true
	end
end

function Zone.setPriority(self: Zone, priority: number)
	(self :: ZoneInfo).priority = priority
end

function Tracked.getZones(self: Tracked): {Zone}
	local entityInfo = entitiesTracker[self.entity]
	if not entityInfo then
		error(`{SOURCE} Cannot call getZones on untracked entity`)
	end
	local zones = {}
	for _, zone in entityInfo.PrevZones do
		table.insert(zones, zone :: Zone)
	end
	return zones
end

local function resolvePriority(zone: ZoneInfo, currZones: {[Observer]: ZoneInfo})
	local priority = zone.priority
	for _, observer in zone.observers do
		local currZone = currZones[observer]
		local current = if currZone then currZone.priority else -math.huge

		if priority > current then
			currZones[observer] = zone
		end
	end
end

--Adaptive polling config
const MIN_POLL_RATE = POLLING_RATE > 60 and 30 or POLLING_RATE / 2
const HZ_THRESHOLD: number = 4
const HISTORY_LEN: number = 40
local interval: number = 4
local historyDt: number = 0
local historyFrames: number = 0
local historyPollTime: number = 0
local pollRate = POLLING_RATE
local cursor: number = 1
local accumulator: number = 0

--Poll
local pollConnection: RBXScriptConnection? = nil
local deferred: boolean = false

local function poll(dt: number)
	if rebuildStatic then
		if not deferred then
			deferred = true
			return
		end
		updateTreeBounds(staticTree, zones)
		staticTree:build(zones, numStaticZones)
		rebuildStatic = false
		deferred = false
		return
	end
	
	local t0 = os.clock()	
	if rebuildDynamic then
		dynamicTree:build(dynamicZones, numDynamicZones)
		rebuildDynamic = false
	end
	
	if historyFrames >= HISTORY_LEN then
		local avgHz = (historyFrames / historyDt) / interval
		
		if PERF_MODE then
			local pollFps = historyFrames / historyPollTime
			if pollRate < POLLING_RATE and pollFps > 260 then
				pollRate = math.min(pollRate + 2, POLLING_RATE)
			elseif pollFps < 240 then
				pollRate = math.max(pollRate - 2, MIN_POLL_RATE)
			end
		end

		if avgHz - pollRate > HZ_THRESHOLD then
			interval = math.min(interval + 1, NUM_BUCKETS)
			
		elseif pollRate - avgHz > HZ_THRESHOLD then
			interval = math.max(interval - 1, 1)
		end
		historyFrames = 0
		historyDt = 0
		historyPollTime = 0
	end	
	historyFrames += 1
	historyDt += dt
	accumulator += NUM_BUCKETS / interval
	
	while accumulator >= 1 do
		accumulator -= 1
		for entity: Entity, entityInfo: EntityInfo in entities[cursor] do
			if not entityInfo.Active or not entity then
				continue
			end
			local entCandidates = entityInfo.Candidates
			local entCurrZones = entityInfo.CurrZones
			local entPrevZones = entityInfo.PrevZones
			local entChangedSignals = entityInfo.ChangedSignals
			local entType = entityInfo.Type
			local pos

			if entType == ENUM_PLAYER then
				local char = (entity :: Player).Character
				if not char then
					entityInfo.RootPart = nil
					continue
				end
				if char ~= entityInfo.Char then
					local rootPart = char:FindFirstChild("HumanoidRootPart")
					if rootPart then
						entityInfo.Char = char
						entityInfo.RootPart = rootPart :: BasePart
					end
				end

				local rootPart = entityInfo.RootPart
				if not rootPart then
					continue
				end
				pos = rootPart.Position

			elseif entType == ENUM_MODEL then
				pos = (entity :: Model):GetPivot().Position

			else
				pos = (entity :: any).Position
			end

			table.clear(entCurrZones)
			table.clear(entCandidates)
			staticTree:query(pos, entCandidates)
			dynamicTree:query(pos, entCandidates)

			for _, zone in entCandidates do			
				if not checkInZone(pos, zone) then
					continue
				end
				resolvePriority(zone, entCurrZones)
			end
			
			--update entity's zones/fire signals		
			for observer, zone: ZoneInfo in entPrevZones do
				local currZone = entCurrZones[observer]
				if zone == currZone then continue end				
				local exitSignal = zone.ExitedSignal
				if exitSignal then
					local zoneUnion = zone.union
					if zoneUnion == nil or currZone == nil or zoneUnion ~= currZone.union then
						exitSignal:Fire(entity, observer) 
					end
				end
				if not currZone then
					local changedSignal = entChangedSignals[observer]
					if changedSignal then changedSignal:Fire(nil) end
				end
				if not currZone then 
					entPrevZones[observer] = nil
				end
			end

			for observer, zone: ZoneInfo in entCurrZones do
				local prevZone = entPrevZones[observer]
				if zone == prevZone then continue end 
				local enterSignal = zone.EnteredSignal
				if enterSignal then
					local zoneUnion = zone.union
					if zoneUnion == nil or prevZone == nil or zoneUnion ~= prevZone.union then
						enterSignal:Fire(entity, observer) 
					end
				end
				local changedSignal = entChangedSignals[observer]
				if changedSignal then changedSignal:Fire(zone :: Zone) end	
				entPrevZones[observer] = zone
			end			
		end
		
		cursor += 1
		if cursor > NUM_BUCKETS then
			cursor = 1
		end
	end
	historyPollTime += os.clock() - t0
end

function ZoneService.stopPoll(self: ZoneService)
	if pollConnection then
		pollConnection:Disconnect()
		pollConnection = nil
	end
end

function ZoneService.startPoll(self: ZoneService)
	if pollConnection then return end
	pollConnection = RunService.Heartbeat:Connect(poll)
end

function ZoneService.rebuildStaticBVH(self: ZoneService)
	rebuildStatic = true
end

function ZoneService.rebuildDynamicBVH(self: ZoneService)
	rebuildDynamic = true
end

function ZoneService.updateDynamicBounds(self: ZoneService)
	updateTreeBounds(dynamicTree, dynamicZones)
end

function ZoneService.destroy(self: ZoneService)
	self:stopPoll()
	
	for entity, _ in entitiesTracker do
		self:untrack(entity)
	end
	
	for zone, _ in zones do
		(zone :: Zone):destroy()
	end
	
	for zone, _ in dynamicZones do
		(zone :: Zone):destroy()
	end
	
	numStaticZones = 0
	numDynamicZones = 0
	rebuildStatic = false
	rebuildDynamic = false
	staticTree:reset()
	dynamicTree:reset()
	deferred = false
end
--API end

pollConnection = RunService.Heartbeat:Connect(poll)

print(`{SOURCE} ZoneService {VERSION} started!`)

export type ZoneService = typeof(ZoneService)

return ZoneService