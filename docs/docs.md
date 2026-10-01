# Usage Example
```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ZoneService = require(ReplicatedStorage.ZoneService)
local Group = ZoneService.Group
local zones = Group.new()

for i, part in workspace.Zones:GetChildren() do
  local zone = ZoneService.fromPart(part, {priority = 10, dynamic = false, metadata = "zone"..i})
  zones:add(zone)

  zone:onEnter(function(player)
    print(player.Name.." entered zone!")
    part.Color = Color3.new(0, 1, 0)
  end

  zone:onExit(function(player)
    print(player.Name.." exited zone!")
    part.Color = Color3.new(0, 0, 0)
  end  
end

Players.PlayerAdded:Connect(function(player)
  local tracked = ZoneService:track(player)	
  tracked:onZoneChange(zones, function(zone)
    print(player.Name.." is in "..tostring(zone and zone.metadata))
  end)
end)

Players.PlayerRemoving:Connect(function(player)
  ZoneService:untrack(player)
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

### ``:track(entity: Entity): Tracked``
Registers the given entity for tracking and returns a `Tracked` handle.
```lua
Players.PlayerAdded:Connect(function(player)
  local tracked = ZoneService:track(player)
end)
```

### ``:untrack(entity: Entity)``
Stops tracking the given entity and cleans up its data.
```lua
Players.PlayerRemoving:Connect(function(player)
  ZoneService:untrack(player)
end)
```

### ``:getZonesAtPoint(point: Vector3): {Zone}``
Returns a table of zones that intersect the given point. This method makes 2 BVH queries.

### ``.ballSize(radius: number): Vector3``
Helper for getting a Vector3 size for a ball shape.

### ``.cylinderSize(radius: number, height: number): Vector3``
Helper for getting a Vector3 size for a cylinder shape. The size returned follows default cylinder orientation, i.e. height on the X axis.

### ``:startsPoll()``
Starts scanning entities and zones (on by default).

### ``:stopPoll()``
Stops scanning entities and zones.

### ``:rebuildStaticBVH()``
Schedules a static BVH rebuild on the next rebuild cycle. Static BVH rebuild request is checked every heartbeat, and when detected, gets deferred to the following heartbeat.

### ``:rebuildDynamicBVH()``
Schedules a dynamic BVH rebuild on the next rebuild cycle. Dymamic BVH rebuild request is checked every heartbeat, and when detected, rebuilds the tree immediately.

### ``:updateDynamicBounds()``
Recalculates the bounds that encompass all dynamic zones. This method should be called after a dynamic zone that's very far away from every other zone is removed or moved close to the others for the near future.

### ``:destroy()``
Stops all ZoneService work and cleans up any allocations. Afterwards, ZoneService can be reused again as though it were required for the first time.

# Zone
### `:onEnter(callback: (entity: Entity) -> ()): Signal.Connection<Entity>`
Connects a signal that fires any time a tracked entity enters the zone.

### `:onExit(callback: (entity: Entity) -> ()): Signal.Connection<Entity>`
Connects a signal that fires any time a tracked entity exits the zone.

### `:update(cframe: CFrame?, size: Vector3?)`
Updates the CFrame and/or size of the zone.

### `:isPointInside(point: Vector3): boolean`
Checks if a point is inside the zone.

### `:getRandomPointInside(): Vector3`
Returns a uniform random point inside the zone.

### `:setPriority(priority: number)`
Sets the priority of the zone.

### `:destroy()`
Cleans up the zone object and renders it unusable.

### `.metadata`
A read and write field that can be used to attach arbitrary data to the zone.

# Group
### `.new(): Group`
Creates a new Group object.

### `:add(zone: Zone)`
Attaches the zone to the group.

### `:remove(zone: Zone)`
Removes the zone from the group.

### `:destroy()`
Removes all zones from the group, disconnects all `:onZoneChange` signals that observe the group, and renders the object unusable.

### `.zones`
A read only table that contains zone object keys and undefined values.

### `.entities`
A read only table that contains entity keys and undefined values.

# Tracked
### `:onZoneChange(group: Group, callback: (zone: Zone?) -> ()): Signal.Connection<Zone?>`
Observe when the entity changes zones in the given group. Calling this method after the entity has been untracked will cause an error.
```lua
local zones = ZoneService.Group.new()
Players.PlayerAdded:Connect(function(player)
  local tracked = ZoneService:track(player)
  local conn = tracked:onZoneChange(group, function(zone)
    print(player.Name.." is in "..tostring(zone and zone.metadata))
  end)
end)
```
### `:getZones(): {Zone}`
Returns a table containing the zone objects the entity is currently in. 
