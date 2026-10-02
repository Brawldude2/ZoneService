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

	Groups: {Group},
	Priority: number,
	Dynamic: boolean,
	metadata: any,
	destroyed: boolean,
	
	EnteredSignal: Signal<Entity>?,
	ExitedSignal: Signal<Entity>?,
}

export type Zone = {
	destroyed: boolean,
	metadata: any,
	isPointInside: (self: Zone, point: Vector3) -> boolean,
	getRandomPointInside: (self: Zone) -> Vector3,
	setPriority: (self: Zone, priority: number) -> (),
	update: (self: Zone, cframe: CFrame?, size: Vector3?) -> (),
	onEnter: (self: Zone, callback: (entity: Entity) -> ()) -> Signal.Connection<Entity>,
	onExit: (self: Zone, callback: (entity: Entity) -> ()) -> Signal.Connection<Entity>,
	destroy: (self: Zone) -> (),
}

export type Group = {
	zones: {[Zone]: number},
	entities: {[Entity]: EntityInfo},
	
	add: (self: Group, zone: Zone) -> (),
	remove: (self: Group, zone: Zone) -> (),
	destroy: (self: Group) -> (),
}

export type Entity = Player? | Instance | {Position: Vector3}

export type EntityInfo = {
	Type: number,
	Active: boolean,
	Char: Model?,
	RootPart: BasePart?,
	
	Candidates: {ZoneInfo},
	CurrZones: {[Group]: ZoneInfo},
	PrevZones: {[Group]: ZoneInfo},
	ChangedSignals: {[Group]: Signal<Zone?>},
}

export type Tracked = {
	entity: Entity,
	onZoneChange: (self: Tracked, group: Group, callback: (zone: Zone?) -> (), prefire: boolean?) -> 
	Signal.Connection<Zone?>,
	getZones: (self: Tracked) -> {Zone},
}

export type Shape = "Block" | "Ball" | "Cylinder" | "Wedge" | "CornerWedge"

export type Bucket = {[Entity]: EntityInfo}

return nil
