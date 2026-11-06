# 节选自私有仓库 scene/chapter5/chapter5_route.gd
# --- 第 1-25 行 ---
## ===== 第五层正式路线：十一房（初始房→九间选路房→Boss），每次出口给2—3个候选 =====
## 深度0是初始房、深度10是Boss；中间九房按 chapter5_rooms.json 的 route_rules 保底：
## 至少1商店、1奖励、2事件、1普通、1高难，其余类型随机。候选可以同类型，但战斗与事件房不重复
## （同组候选也不重复），商店与奖励这类安全房可在不同深度再次出现，同组至多两个安全房。
## 路线v2起最后一间选路房（Boss前一房）固定为 final_room_tier（商店），只给这一个出口；房间可配最早深度
## min_depth，introduced_version 高于路线版本的房间不进候选。v3 起总房数由十二减为十一（legacy_room_count 保留旧值），
## 旧v1/v2快照按原规则与原房数重放，候选不变。
## 候选由种子与已走房间决定，重试、读档重放结果不变；只要按候选前进，任何一条路线都满足保底。
## 注册表 requires_collectible 标注的专属事件房（萨卡兹魔剑→百夫长）只在开局时持有该藏品的路线出现，
## 且在同类型中优先抽取；开局持有清单 held_gates 随快照保存，中途得失藏品不改变重放候选。
class_name Chapter5Route
extends Chapter4Route

const REGISTRY: String = "res://resources/config/chapter5_rooms.json"
const ROUTE_VERSION: int = 3 ## 第五层路线快照版本，独立于第四层；v2 起最后一房固定商店、事件房有最早深度；v3 起少一间选路房。
const START_ID: String = "c5_start"
const BOSS_ID: String = "c5_boss"
const LEVEL_BASE: int = 36 ## 全局房间序号：第四层终局（27+8）之后的第五层初始房，选路房按深度递增。
const SAFE_TIERS: Array[String] = ["shop", "reward"]
const ROUTE_TIERS: Array[String] = ["normal", "hard", "extreme", "event", "shop", "reward"]
var rules: Dictionary = {} ## 注册表 route_rules：房数、候选数、保底、上限、权重与最早深度。
var rules_version: int = ROUTE_VERSION ## 本路线遵循的规则版本；旧快照重放时沿用快照版本。
var held_gates: Array[String] = [] ## 开局时持有、能开启专属事件房的藏品ID（已排序）。
var boss_jump_depth: int = -1 ## 米莎被夺走时所在深度：该房出口只通Boss；-1为未发生。

# --- 第 79-92 行 ---
## 本房出口候选：最后一间选路房只通Boss，v2 起它本身固定为商店；其余深度给2—3个满足保底可行性的候选。
func choices() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if depth < 0 or depth >= room_count() - 1:
		return result
	if boss_jump_depth >= 0 and depth >= boss_jump_depth:
		if depth == boss_jump_depth and _rooms.has(BOSS_ID):
			result.append((_rooms[BOSS_ID] as Dictionary).duplicate(true))
		return result
	var slot: int = depth + 1
	if slot == room_count() - 1:
		if _rooms.has(BOSS_ID):
			result.append((_rooms[BOSS_ID] as Dictionary).duplicate(true))
		return result
