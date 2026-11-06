# 节选自私有仓库 scene/chapter5/doctor_strategy.gd
# --- 第 1-39 行 ---
## ===== 博士战略态势：全局快照 -> 五种态势评分 -> 带滞回的随机应变切换；态势给战术菜单加权，战果评估回写士气 =====
## 指挥链：战略态势（本类，全局）-> 战术选择（DoctorTactics，局部）-> 据点与路线分配 -> 编队执行（DoctorController）-> 战果评估（record）。
## 态势不是固定流程：每轮按门压力、深入程度、生命、费用、落单与倒地重新评分，维持期内只有紧急情况或明显更优才切换。
## 构筑画像（DoctorProfile）在评分上加小幅偏置，并在菜单权重上再乘一层画像权重；未设画像时行为不变。
extends RefCounted
class_name DoctorStrategy

const POSTURES: Array[String] = ["economy", "defense", "counter", "hunt", "decisive"] ## 经营 / 防御 / 反攻 / 猎杀 / 决战。
const NAMES: Dictionary = {"economy": "经营", "defense": "防御", "counter": "反攻", "hunt": "猎杀", "decisive": "决战"} ## HUD与调试显示名。
const MIN_DWELL: float = 8.0 ## 态势最短维持秒数（中央告急除外）。
const SWITCH_MARGIN: float = 0.08 ## 维持期满后新态势需高出当前态势这么多才切换。
const URGENT_MARGIN: float = 0.2 ## 维持期内只有领先这么多（局势骤变）才提前切换。
const MORALE_DECAY: float = 0.015 ## 战果士气每秒向0回归。
const MORALE_LIMIT: float = 0.3 ## 战果士气上下限。
const CENTRAL_EMERGENCY: float = 0.55 ## 中央门威胁超过此值时立即转入防御或决战。
const CENTRAL_BREACH: float = 0.6 ## 中央门占领进度达到此比例即将失守：无视评分与维持期强制决战，低于此比例才恢复常规评估。
const OFF_MENU: float = 0.5 ## 不在当前态势菜单内的战术折算权重。
## 每种态势的战术菜单：战术类型 -> 权重（乘在候选分数上）；“保存资源”不加权。
const MENUS: Dictionary = {
	"economy": {"economy": 1.5, "guard_income": 1.3, "fortify": 1.2, "regroup": 1.2, "central": 1.0, "save_gate": 1.0, "screen": 0.9,
		"recapture": 0.8, "fire_support": 0.8, "red_raid": 0.8, "push": 0.7, "encircle": 0.7, "intercept": 0.7, "decapitate": 0.6, "counter": 0.6, "all_out": 0.4},
	"defense": {"save_gate": 1.4, "screen": 1.4, "central": 1.3, "fortify": 1.3, "fallback": 1.3, "fire_support": 1.3, "guard_income": 1.1,
		"encircle": 1.0, "intercept": 1.0, "counter": 1.0, "regroup": 1.0, "recapture": 0.9, "economy": 0.8, "push": 0.6, "decapitate": 0.5, "red_raid": 0.5, "all_out": 0.5},
	"counter": {"recapture": 1.5, "flank": 1.4, "counter": 1.4, "encircle": 1.35, "push": 1.3, "all_out": 1.2, "red_raid": 1.2, "intercept": 1.2,
		"ambush": 1.1, "fire_support": 1.0, "central": 1.0, "save_gate": 1.0, "guard_income": 0.8, "economy": 0.7, "fortify": 0.6},
	"hunt": {"decapitate": 1.8, "hunt_squad": 1.6, "ambush": 1.5, "snipe": 1.4, "flank": 1.1, "central": 1.0, "save_gate": 0.8, "guard_income": 0.8,
		"push": 0.7, "economy": 0.6, "recapture": 0.6, "fortify": 0.5},
	"decisive": {"central": 1.5, "last_stand": 1.5, "all_out": 1.5, "counter": 1.3, "fallback": 1.2, "decapitate": 1.1, "hunt_squad": 1.1, "screen": 1.0,
		"push": 1.0, "save_gate": 0.9, "fortify": 0.6, "regroup": 0.5, "guard_income": 0.3, "economy": 0.15},
}

var posture: String = "economy" ## 当前战略态势。
var since: float = 0.0 ## 进入当前态势的战斗钟。
var scores: Dictionary = {} ## 最近一轮态势评分（调试视图与测试读取）。
var morale: Dictionary = {} ## 态势 -> 战果士气（成功为正、受挫为负，随时间回归）。
var outcomes: Array[Dictionary] = [] ## 战果流水（定长，调试与测试读取）。
var _last_time: float = 0.0 ## 上次评估的战斗钟（士气衰减用）。
var _assessed: bool = false ## 首轮评估直接取最优态势（开局默认值不是一次真实决策，不受维持期约束）。
var profile: DoctorProfile = null ## 玩家构筑画像；为空时不偏置。
