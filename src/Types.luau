local Signal = require(script.Parent.UsefulSignal)

export type Signal<T...> = Signal.Signal<T...>

export type Params = {
	Priority: number?,
	IsDynamic: boolean?,
	UserData: any,
}

export type Tree = {
	NodeCount: number,
	NextNode: number,
	NodeMin: buffer,
	NodeMax: buffer,
	NodeSkip: buffer,
	NodeZone: {ZoneInfo},

	OrderedZones: {ZoneInfo},
	MortonCodes: {number},

	MinBound: vector,
	MaxBound: vector,
	PreviousNodeCount: number,

	Build: (self: Tree, zones: {[ZoneInfo]: boolean}, numZones: number) -> (),
	Query: (self: Tree, pos: Vector3, results: {ZoneInfo}) -> (),
	UpdateBounds: (self: Tree, min: Vector3, max: Vector3) -> (),
	SetBounds: (self: Tree, min: vector, max: vector) -> (),
	Reset: (self: Tree) -> (),
}

export type ZoneInfo = {
	Destroyed: boolean,
	
	Type: number,
	HalfSize: Vector3?,
	AxisAligned: boolean?,
	LowerPosition: Vector3,
	UpperPosition: Vector3,

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
	Position: Vector3,
	
	UnionId: number,
	Groups: {Group},
	Priority: number,
	Dynamic: boolean,
	UserData: any,
	
	Entered: Signal<Entity>?,
	Exited: Signal<Entity>?,
}

export type Zone = {
	Destroyed: boolean,
	
	Priority: number,
	UserData: any,
	IsPointInside: (self: Zone, point: Vector3) -> boolean,
	GetRandomPointInside: (self: Zone) -> Vector3,
	Update: (self: Zone, cframe: CFrame?, size: Vector3?) -> (),
	OnEnter: (self: Zone, callback: (entity: Entity) -> ()) -> Signal.Connection<Entity>,
	OnExit: (self: Zone, callback: (entity: Entity) -> ()) -> Signal.Connection<Entity>,
	Destroy: (self: Zone) -> (),
}

export type Group = {
	Zones: {[Zone]: number},
	Entities: {[Entity]: EntityInfo},
	
	Add: (self: Group, zone: Zone) -> (),
	Remove: (self: Group, zone: Zone) -> (),
	Destroy: (self: Group) -> (),
}

export type Entity = Player? | Instance | {Position: Vector3}

export type EntityInfo = {
	Type: number,
	Active: boolean,
	Character: Model?,
	RootPart: BasePart?,
	
	CandidateZones: {ZoneInfo},
	CurrentZones: {[Group]: ZoneInfo},
	PreviousZones: {[Group]: ZoneInfo},
	ChangedSignals: {[Group]: Signal<Zone?>},
}

export type Tracked = {
	Entity: Entity,
	OnZoneChange: (self: Tracked, group: Group, callback: (zone: Zone?) -> (), prefire: boolean?) -> Signal.Connection<Zone?>,
	GetZones: (self: Tracked) -> {Zone},
}

export type Shape = "Block" | "Ball" | "Cylinder" | "Wedge" | "CornerWedge"

export type FrameBucket = {[Entity]: EntityInfo}

return nil
