# 节选自私有仓库 scene/world/route_network.gd
# --- 第 1-74 行 ---
## ===== 路线网络：路线编队只沿场景 RouteNetwork 折线行军，墙、高台与动态障碍照常阻挡 =====
## 第四、五层战斗房（黑蓑房除外）各自实例化 `<房间>_route_network.tscn`；折线两侧放宽成走廊格，
## 行军锚改走折线路网图（节点为顶点与交叉点），每个源节点的最短路树建一次后缓存，选路只比较起止两段的端点组合，不再逐格跑 A*。
## 百夫长大道导航（centurion_avenue_routes.gd）复用这里的走廊约束，只是可走格改由大道瓦片决定、不建路网图。
extends "res://scene/world/ground_route_grid.gd"

const HALF_WIDTH: int = 1 ## 折线两侧各放宽的格数：走廊三格宽，容纳小队并排与载具车身。
const SAMPLE_STEP: float = 4.0 ## 折线逐段采样间距（像素），小于半格保证斜线不漏格。
const JOIN_DISTANCE: float = 24.0 ## 折线端点离另一条折线不超过此距离即视为接上：容许编辑错位与斜邻格（约1.5格，不会跨过墙接到隔壁路）。
const SAME_POINT: float = 0.5 ## 两个路网点相距不超过此距离视为同一节点。

var _shared: RefCounted = null ## 房间真实静态/动态障碍；不修改公共导航。
var _allowed: Dictionary = {} ## 走廊（或大道）内可走格。
var _source_revision: int = -1 ## 动态障碍变化后刷新专用网格。
var _nodes: Array[Vector2] = [] ## 路网节点：折线顶点、交叉点与接驳投影点。
var _links: Array = [] ## 每个节点的邻接表：[[邻点序号, 长度], ...]。
var _edges: Array = [] ## 路网边：[起点序号, 终点序号]，供投影与同段判断。
var _trees: Dictionary = {} ## 源节点 -> [距离表, 前驱表]，按需建立后复用。

## 房间的路线网络导航：每个房间只建一次并挂在房间元数据上；场景没有 RouteNetwork 时返回空，调用方保持原导航。
static func network_for_room(room: Node2D) -> RefCounted:
	if room == null:
		return null
	if room.has_meta(&"route_network_router"):
		var cached: Variant = room.get_meta(&"route_network_router")
		return cached as RefCounted if cached is RefCounted else null
	var router: RefCounted = (load("res://scene/world/route_network.gd") as Script).new() as RefCounted
	if not bool(router.call("setup_network", room)):
		room.set_meta(&"route_network_router", false)
		return null
	room.set_meta(&"route_network_router", router)
	return router

## 读取房间 RouteNetwork 下全部 Line2D 建立走廊与路网图，并隐藏编辑器里的路线示意。
func setup_network(room: Node2D) -> bool:
	var network: Node2D = room.get_node_or_null("RouteNetwork") as Node2D
	var ground: TileMapLayer = room.get_node_or_null("GroundTileMapLayer") as TileMapLayer
	if network == null or ground == null:
		return false
	network.visible = false
	_shared = load("res://scene/world/ground_route_grid.gd").for_room(room)
	build(ground, room)
	var lines: Array[PackedVector2Array] = []
	for child: Node in network.get_children():
		var line: Line2D = child as Line2D
		if line == null or line.points.size() < 2:
			continue
		var points: PackedVector2Array = PackedVector2Array()
		for point: Vector2 in line.points:
			points.append(line.to_global(point))
		lines.append(points)
	var corridor: Dictionary = {}
	for points: PackedVector2Array in lines:
		for index: int in range(points.size() - 1):
			var steps: int = maxi(1, ceili(points[index].distance_to(points[index + 1]) / SAMPLE_STEP))
			for step: int in range(steps + 1):
				var center: Vector2i = ground.local_to_map(ground.to_local(points[index].lerp(points[index + 1], float(step) / float(steps))))
				for dy: int in range(-HALF_WIDTH, HALF_WIDTH + 1):
					for dx: int in range(-HALF_WIDTH, HALF_WIDTH + 1):
						corridor[center + Vector2i(dx, dy)] = true
	for y: int in range(grid.region.position.y, grid.region.end.y):
		for x: int in range(grid.region.position.x, grid.region.end.x):
			var cell: Vector2i = Vector2i(x, y)
			if corridor.has(cell) and not grid.is_point_solid(cell):
				_allowed[cell] = true
			else:
				grid.set_point_solid(cell, true)
				_static_solid[cell] = true
	_open_cells.clear()
	for raw: Variant in _allowed:
		_open_cells.append(raw as Vector2i)
	_sync_obstacles()
	_build_graph(lines)
	return not _allowed.is_empty()
