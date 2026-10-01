## ZoneService
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
  ZoneService:track(player)
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
Returns a table of zones that intersect the given point. Unlike `:getZones`, this method queries the BVH.
```lua
local zones = ZoneService:getZonesAtPoint(Vector3.new(1, 2, 3))
```

### ``.ballSize(radius: number): Vector3``
Helper for getting a Vector3 size for a ball shape.
```lua
local ballSize = ZoneService.ballSize(5)
```

### ``.cylinderSize(radius: number, height: number): Vector3``
Helper for getting a Vector3 size for a cylinder shape. The size returned follows default cylinder orientation, i.e. height on the X axis.
```lua
local cylinderSize = ZoneService.cylinderSize(5, 10)
```

### ``:startsPoll()``
Starts scanning subjects and zones (on by default).
```lua
ZoneService:startPoll()
```

### ``:stopPoll()``
Stops scanning subjects and zones.
```lua
ZoneService:stopPoll()
```

### ``:rebuildStaticBVH()``
Schedules a static BVH rebuild on the next rebuild cycle. Static BVH rebuild request is checked every heartbeat, and when detected, gets deferred to the following heartbeat.
```lua
ZoneService:rebuildStaticBVH()
```

### ``:rebuildDynamicBVH()``
Schedules a dynamic BVH rebuild on the next rebuild cycle. Dymamic BVH rebuild request is checked every heartbeat, and when detected, rebuilds the tree immediately.
```lua
ZoneService:rebuildDynamicBVH()
```

### ``:updateDynamicBounds()``
Recalculates the bounds that encompass all dynamic zones. This method should be called after a dynamic zone that's very far away from every other zone is removed or moved close to the others for the near future.
```lua
ZoneService:updateStaticBounds()
```

### ``:destroy()``
Stops all ZoneService work and cleans up any allocations. Afterwards, ZoneService can be reused again as though it were required for the first time.
```lua
ZoneService:destroy()
```
