# Usage Example
```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ZoneService = require(ReplicatedStorage.ZoneService)
local Group = ZoneService.Group
local zones = Group.new()

for i, part in workspace.Zones:GetChildren() do
  local zone = ZoneService.fromPart(part, {priority = 10, dynamic = false, metadata = "zone"..i})
  zones:Add(zone)

  zone:OnEnter(function(player)
    print(player.Name.." entered zone!")
    part.Color = Color3.new(0, 1, 0)
  end

  zone:OnExit(function(player)
    print(player.Name.." exited zone!")
    part.Color = Color3.new(0, 0, 0)
  end  
end

Players.PlayerAdded:Connect(function(player)
  local tracked = ZoneService:Track(player)	
  tracked:OnZoneChange(zones, function(zone)
    print(player.Name.." is in "..tostring(zone and zone.metadata))
  end)
end)

Players.PlayerRemoving:Connect(function(player)
  ZoneService:Untrack(player)
end)
```

# ZoneService
`Params`: {priority: number?, dynamic: number?, metadata: any}

`Entity`: Player? | Instance | {Position: Vector3}

`Shape`: "Block" | "Ball" | "Cylinder" | "Wedge" | "CornerWedge"

### `.new(cframe: CFrame, size: Vector3, shape: Shape, params: Params?): Zone`
Add an abstract zone described by CFrame and size. If the zone moves or resizes frequently dynamic should be set to true for best performance. On the other hand, if the zone never or only rarely changes, set dynamic to false.
```lua
local zone = ZoneService.new(CFrame.new(1, 2, 3), Vector3.new(10, 10, 10), "Block", {priority = 20, dynamic = false, metadata = "SafeZone"})
```

### `.fromPart(part: Part, params: Params?): Zone`
Add a zone from a Part.
```lua
local zone = ZoneService.fromPart(workspace.ZonePart, {priority = 20, dynamic = false, metadata = "SafeZone"})
```

### ``:Track(entity: Entity): Tracked``
Registers the given entity for tracking and returns a `Tracked` handle.
```lua
Players.PlayerAdded:Connect(function(player)
  local tracked = ZoneService:Track(player)
end)
```

### ``:Untrack(entity: Entity)``
Stops tracking the given entity and cleans up its data.
```lua
Players.PlayerRemoving:Connect(function(player)
  ZoneService:Untrack(player)
end)
```

### ``:GetZonesAtPoint(point: Vector3): {Zone}``
Returns a table of zones that intersect the given point. This method makes 2 BVH queries.

### ``.BallSize(radius: number): Vector3``
Helper for getting a Vector3 size for a ball shape.

### ``.CylinderSize(radius: number, height: number): Vector3``
Helper for getting a Vector3 size for a cylinder shape. The size returned follows default cylinder orientation, i.e. height on the X axis.

### ``:StartsPoll()``
Starts scanning entities and zones (on by default).

### ``:StopPoll()``
Stops scanning entities and zones.

### ``:RebuildStaticBVH()``
Schedules a static BVH rebuild on the next rebuild cycle. Static BVH rebuild request is checked every heartbeat, and when detected, gets deferred to the following heartbeat.

### ``:RebuildDynamicBVH()``
Schedules a dynamic BVH rebuild on the next rebuild cycle. Dymamic BVH rebuild request is checked every heartbeat, and when detected, rebuilds the tree immediately.

### ``:UpdateDynamicBounds()``
Recalculates the bounds that encompass all dynamic zones. This method should be called after a dynamic zone that's very far away from every other zone is removed or moved close to the others for the near future.

### ``:Destroy()``
Stops all ZoneService work and cleans up any allocations. Afterwards, ZoneService can be reused again as though it were required for the first time.

# Zone
### `:OnEnter(callback: (entity: Entity) -> ()): Signal.Connection<Entity>`
Connects a signal that fires any time a tracked entity enters the zone.

### `:OnExit(callback: (entity: Entity) -> ()): Signal.Connection<Entity>`
Connects a signal that fires any time a tracked entity exits the zone.

### `:Update(cframe: CFrame?, size: Vector3?)`
Updates the CFrame and/or size of the zone.

### `:IsPointInside(point: Vector3): boolean`
Checks if a point is inside the zone.

### `:GetRandomPointInside(): Vector3`
Returns a uniform random point inside the zone.

### `:Destroy()`
Cleans up the zone object and renders it unusable.

### `.Destroyed`
A read only true/false flag that indicates if the zone object has been destroyed.

### `.UserData`
A read and write field that can be used to attach arbitrary data to the zone.

# Group
### `.new(): Group`
Creates a new Group object. Having too many groups can degrade the performance. It's recommended to use less than 10 groups.

### `:Add(zone: Zone)`
Adds the zone to the group. It's highly recommended the user does not add the same zone to multiple groups unless absolutely necessary.

### `:Remove(zone: Zone)`
Removes the zone from the group.

### `:Destroy()`
Removes all zones from the group, disconnects all `:onZoneChange` signals that observe the group, and renders the object unusable.

### `.Zones`
A read only table that contains zone object keys and undefined values.

### `.Entities`
A read only table that contains entity keys and undefined values.

# Tracked
### `:OnZoneChange(group: Group, callback: (zone: Zone?) -> (), prefire: boolean?): Signal.Connection<Zone?>`
Observe when the entity changes zones in the given group. Calling this method after the entity has been untracked will cause an error.
```lua
local zones = ZoneService.Group.new()
Players.PlayerAdded:Connect(function(player)
  local tracked = ZoneService:Track(player)
  local conn = tracked:OnZoneChange(zones, function(zone)
    print(player.Name.." is in "..tostring(zone and zone.metadata))
  end)
end)
```
### `:GetZones(): {Zone}`
Returns a table containing the zone objects the entity is currently in. 

### `.Entity`
A read only field that stores the entity associated with the `Tracked` object.
