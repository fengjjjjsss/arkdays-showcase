# 节选自私有仓库 scene/chapter5/doctor_tactics.gd
# --- 第 1-91 行 ---
## ===== 博士战术评估：只读快照 -> 候选战术评分 -> 配兵（模板+贪心补短板），不碰节点与血量 =====
## 中央保卫最优先；其余候选为经济、推进、救门、夺门、护旗、火力、斩首、包围、红门奇袭、反击/总攻、重整与保存资源。
## 传入战略态势时另生成态势菜单内的扩展战术（据点加固、拦截、收缩防线、侧翼、猎杀小队、伏击、远程压制、截击援军、死守核心），
## 并按菜单权重给全部候选加权；不传时保持原候选与分数（账本与情境测试直接调用）。
## 硬过滤（费用/额度/冷却/合法目标）在配兵时完成；软评分扣受挫惩罚；接近时用独立种子随机选择。
## 快照带道路图（snapshot["map"]，DoctorMap）时，拦截、伏击、收缩防线与侧翼按道路距离和来向取点；不带时用直线几何。
## 配兵可传构筑画像，按编制角色与人数加减分（不改硬过滤）。计划只挑角色；落点与命令由编制站位决定（DoctorController）。
extends RefCounted
class_name DoctorTactics

const TIE_MARGIN: float = 0.05 ## 分差小于此值视为接近，随机择一。
const SWITCH_MARGIN: float = 0.15 ## 切换主计划需超过当前计划这么多。
const SAVE_SCORE: float = 0.22 ## 低于“保存资源”分的计划不执行，不硬填额度。
const PENALTY_WEIGHT: float = 0.18 ## 受挫惩罚折算到分数的系数。
const URGENT: Array[String] = ["central", "save_gate", "economy", "guard_income"] ## 不因为Boss攒费而推迟的计划。

var last_scores: Array[Dictionary] = [] ## 最近一轮候选与分数（开发调试视图读取）。

## 门的失守威胁（0..1）：占领进度、附近我方人数，减去附近敌方守军。
static func gate_threat(gate: Dictionary) -> float:
	return clampf(float(gate["progress"]) * 1.4 + float(gate["friendly_near"]) / 10.0 - float(gate.get("hostile_near", 0)) / 12.0, 0.0, 1.0)

## 一轮评估：返回按分数降序的候选计划（含“保存资源”）；strategy 为空时不生成扩展战术、不加权。
func evaluate(snapshot: Dictionary, ledger: DoctorLedger, region_of: Callable = Callable(), strategy: DoctorStrategy = null) -> Array[Dictionary]:
	var plans: Array[Dictionary] = []
	var gates: Array = snapshot.get("gates", []) as Array
	var front: Vector2 = snapshot.get("front", Vector2(INF, INF)) as Vector2
	var friendly_center: Vector2 = snapshot.get("friendly_center", Vector2(INF, INF)) as Vector2
	var cost_ratio: float = clampf(ledger.available_cost() / ledger.cost_cap(), 0.0, 1.0)
	var pressure: float = 0.0
	for raw: Variant in gates:
		var gate: Dictionary = raw as Dictionary
		if bool(gate["captured"]):
			if int(gate["friendly_near"]) <= 2:
				plans.append(_plan("recapture", 0.42 + (0.25 if bool(gate["central"]) else 0.0) + cost_ratio * 0.1, gate["point"] as Vector2, ["melee", "cheap", "fast"], 1, "recapture", str(gate["id"])))
			continue
		var threat: float = gate_threat(gate)
		pressure = maxf(pressure, threat)
		if bool(gate["central"]) and threat > 0.2:
			var central: Dictionary = _plan("central", 0.85 + threat * 0.5, gate["point"] as Vector2, ["line", "melee", "boss", "artillery"], 2, "defend", str(gate["id"]))
			central["emergency"] = true
			plans.append(central)
		elif threat > 0.3:
			var save: Dictionary = _plan("save_gate", 0.5 + threat * 0.4, gate["point"] as Vector2, ["melee", "line", "fast"], 1, "defend", str(gate["id"]))
			save["emergency"] = threat > 0.75
			save["hopeless"] = float(gate["progress"]) > 0.85 and int(gate["doctor_near"]) == 0 and not bool(gate["central"])
			plans.append(save)
	var flags_live: int = int(snapshot.get("flags_live", 0))
	var economy_point: Vector2 = snapshot.get("rear", Vector2(INF, INF)) as Vector2
	if flags_live < 2 and economy_point.is_finite():
		plans.append(_plan("economy", 0.52 - 0.18 * float(flags_live) - pressure * 0.3 + (0.12 if float(snapshot.get("time", 0.0)) < 40.0 else 0.0), economy_point, ["income"], 1, "hold", ""))
	for raw: Variant in snapshot.get("flags_threatened", []) as Array:
		plans.append(_plan("guard_income", 0.58, raw as Vector2, ["melee", "fast", "cheap"], 1, "hold", ""))
	if front.is_finite():
		plans.append(_plan("push", 0.3 + cost_ratio * 0.3, front, ["melee", "ranged", "line"], 1, "attack", ""))
	for raw: Variant in snapshot.get("engaged_front", []) as Array:
		if int(snapshot.get("rear_live", 0)) == 0:
			plans.append(_plan("fire_support", 0.48, raw as Vector2, ["artillery"], 1, "hold", ""))
			break
	for raw: Variant in snapshot.get("isolated_players", []) as Array:
		plans.append(_plan("decapitate", 0.42 + cost_ratio * 0.08, raw as Vector2, ["fast", "assault"], 1, "attack", "")) ## 机会战术：低于经济与救门，冷却由指挥节点控制。
	if int(snapshot.get("friendly_count", 0)) >= 8 and friendly_center.is_finite() and friendly_center.x > float(snapshot.get("deep_x", 520.0)):
		var encircle: Dictionary = _plan("encircle", 0.6 + pressure * 0.2 + minf(0.1, float(int(snapshot.get("friendly_count", 0)) - 8) * 0.02), friendly_center, ["melee", "fast", "line"], 2, "attack", "")
		encircle["directions"] = 2
		plans.append(encircle)
	for raw: Variant in snapshot.get("open_reds", []) as Array:
		plans.append(_plan("red_raid", 0.34 + cost_ratio * 0.08, raw as Vector2, ["fast", "cheap"], 1, "attack", ""))
	if bool(snapshot.get("boss_ready", false)) and front.is_finite():
		var counter: Dictionary = _plan("counter" if pressure > 0.35 else "all_out", 0.42 + pressure * 0.3 + cost_ratio * 0.25, front, ["boss"], 1, "attack", "")
		counter["save_for"] = "boss"
		plans.append(counter)
	if int(snapshot.get("recent_losses", 0)) >= 2:
		plans.append(_plan("regroup", 0.4, economy_point if economy_point.is_finite() else front, ["line", "ranged"], 1, "hold", ""))
	if strategy != null:
		_extend(plans, snapshot, ledger, strategy)
	plans.append(_plan("save", SAVE_SCORE, Vector2(INF, INF), [], 0, "", ""))
	for plan: Dictionary in plans:
		if str(plan["type"]) in ["save", "central"]:
			if strategy != null and str(plan["type"]) == "central":
				plan["score"] = float(plan["score"]) * strategy.weight("central")
			continue
		var target: Vector2 = plan["target"] as Vector2
		plan["region"] = str(region_of.call(target)) if region_of.is_valid() and target.is_finite() else ""
		plan["score"] = float(plan["score"]) - ledger.loss_penalty(str(plan["region"]), str(plan["type"])) * PENALTY_WEIGHT
		if bool(plan.get("hopeless", false)):
			plan["score"] = float(plan["score"]) * 0.3 ## 无法挽救的侧门放弃，不持续向死地添兵。
		if strategy != null:
			plan["score"] = float(plan["score"]) * strategy.weight(str(plan["type"]))
	plans.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["score"]) > float(b["score"]))
	last_scores = plans.duplicate(true)
	return plans
