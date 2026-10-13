local Signal = require(script.Parent.UsefulSignal)

export type Signal<T...> = Signal.Signal<T...>

export type Params = {
	priority: number?,
	dynamic: boolean?,
	metadata: any,
}

export type Tree = {
	nodeCount: number,
	nextNode: number,
	nodeMin: buffer,
	nodeMax: buffer,
	nodeSkip: buffer,
	nodeZone: {ZoneInfo},

	orderedZones: {ZoneInfo},
	mortonCodes: {number},

	minBound: vector,
	maxBound: vector,
	prevNodeCount: number,

	build: (self: Tree, zones: {[ZoneInfo]: boolean}, numZones: number) -> (),
	query: (self: Tree, pos: Vector3, results: {ZoneInfo}) -> (),
	updateBounds: (self: Tree, min: Vector3, max: Vector3) -> (),
	setBounds: (self: Tree, min: vector, max: vector) -> (),
	reset: (self: Tree) -> (),
}

export type ZoneInfo = {
	Type: number,
	HalfSize: Vector3?,
	AxisAligned: boolean?,
	PosLower: Vector3,
	PosUpper: Vector3,

	Radius: number?,
	Radius2: number?,
	Height: number?,
	HalfHeight: number?,
	Slope: number?,
	SlopeX: number?,
	SlopeZ: number?,
	
	Size: Vector3,
	CFrame: CFrame,
	InverseCFrame: CFrame?,
	Pos: Vector3,

	observers: {Observer},
	priority: number,
	isDynamic: boolean,
	metadata: any,
	destroyed: boolean,
	union: Zones,
	
	cachedEnteredSignal: any,
	cachedExitedSignal: any,	
	EnteredSignal: any,
	ExitedSignal: any,
}

export type Zone = {
	destroyed: boolean,
	priority: number,
	isDynamic: boolean,
	metadata: any,
	observers: {Observer},
	
	IsPointInside: (self: Zone, point: Vector3) -> boolean,
	GetRandomPointInside: (self: Zone) -> Vector3,
	SetPriority: (self: Zone, priority: number) -> (),
	Update: (self: Zone, cframe: CFrame?, size: Vector3?) -> (),
	Destroy: (self: Zone) -> (),
}

export type Zones = {
	zones: {[Zone]: boolean},
	Add: (self: Zones, zone: Zone) -> (),
	Remove: (self: Zones, zone: Zone) -> (),
	Destroy: (self: Zones) -> (),
}

export type Observer = {
	zones: {[Zone]: number},
	entities: {[Entity]: EntityInfo},
	
	Add: (self: Observer, zone: Zone) -> (),
	Remove: (self: Observer, zone: Zone) -> (),
	OnEnter: (self: Observer, zone: Zone | Zones, callback: (entity: Entity) -> ()) -> Signal.Connection<Entity>,
	OnExit: (self: Observer, zone: Zone | Zones, callback: (entity: Entity) -> ()) -> Signal.Connection<Entity>,
	OnZoneChange: (self: Observer, tracked: Tracked, callback: (zone: Zone?) -> ()) -> Signal.Connection<Zone?>,
	Destroy: (self: Observer) -> (),
}

export type Entity = Player? | Instance | {Position: Vector3}

export type EntityInfo = {
	Type: number,
	Active: boolean,
	Char: Model?,
	RootPart: BasePart?,
	
	Candidates: {ZoneInfo},
	CurrZones: {[Observer]: ZoneInfo},
	PrevZones: {[Observer]: ZoneInfo},
	ChangedSignals: {[Observer]: Signal<Zone?>},
}

export type Tracked = {
	entity: Entity,
	GetZones: (self: Tracked) -> {Zone},
}

export type Shape = "Block" | "Ball" | "Cylinder" | "Wedge" | "CornerWedge"

export type Bucket = {[Entity]: EntityInfo}

return nil
