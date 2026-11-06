# 节选自私有仓库 scene/items/effect_pool_engine.gd
# --- 第 1-60 行 ---
## ===== 奖励房效果池生成引擎（纯逻辑） =====
## 规格：docs/effects.md「效果池抽取算法」+ 附录 A（已定口径）。
##
## 输入一份请求（阶段 / 池类型 / 实际尺寸 / 已有效果 / 解锁状态 / 防饿死计数），
## 输出这一池的候选效果 id。调用方负责把返回的
## 新计数写回，这样引擎可以被探针用固定种子反复驱动。
##
## 两条路径只由**实际候选数量**决定（strategy_for_size），不看 special 布尔或 pool_type：
##   * standard（实际3/4候选）：每个位置都按基础稀有度概率 → 角色防饿死(1/1.15/1.3) → 同档等概率；
##     数值与机制共用一份资格（growth 与 build 只是同一规则的别名），整池同系列不重复；
##     忽略 slots / guaranteed_rarity / 高阶槽倍率 / 同角色降权，没有数值配额或机制保底。
##   * special5（实际5候选）：保持 P5 之前的旧算法逐项不变——旧槽位、稀有度保底、
##     高阶槽倍率与同池同角色0.8降权；候选仍按请求的 pool_type（现有调用均为 high_build）。
## 两条路径共用硬资格过滤（章节、解锁、前置、覆盖式等级、Lv4开关与楼层上限）和同一份角色饿死计数。
## 普通路径里前置不合法的候选：W 改投对应低级效果（抽中引信而没有惊喜I时出惊喜I），其余角色直接不进池；
## 五选一的稀有度保底不能被低级效果顶替，不合法候选一律不进池。
extends RefCounted
class_name EffectPoolEngine

const POOL_GROWTH: String = "growth" ## 普通池别名（与 build 资格相同，兼容旧记录）
const POOL_BUILD: String = "build" ## 普通池别名：普通3/4候选统一用它过滤资格
const POOL_HIGH: String = "high_build" ## 旧五选一高阶池：成员逐条保持 P5 之前
const STRATEGY_STANDARD: String = "standard" ## 普通3/4候选的唯一抽样流程
const STRATEGY_SPECIAL5: String = "special5" ## 现有五选一的旧生成流程
const SPECIAL_POOL_SIZE: int = 5 ## 实际候选数达到它才走旧五选一
const PREREQ_SUBSTITUTE_ROLES: Array[String] = ["w"] ## 这些角色的不合法候选改投对应低级效果，占位权重保留在所抽稀有度档。

## 连续两池未出现后轻微补偿，最高1.3倍；不强制指定角色。
const STARVATION_FACTORS: Array[float] = [1.0,1.15,1.3]
## 旧五选一专用：同池已经出现过的角色略降权（普通池不使用）。
const SAME_ROLE_FACTOR: float = 0.8
## 旧五选一专用：高阶槽对稀有度3+的倍率（普通池不使用）。
const HIGH_SLOT_RARITY_BOOST: float = 3.0
static var _floor4_rates: Dictionary = {} ## 第四层独立概率，不改变前三层表。
## 阶段 → 追赶区最高直出等级（§六 B：前期 I、中期 II、后期 III）
const STAGE_DIRECT_CEILING: Dictionary = {
	"chapter1": 1, "chapter2": 1, "trio_joined": 2, "trio_mid": 2, "late": 3, "final": 3,
}


## 唯一路径判定：只看奖励实际尺寸；生成、预览与领取资格检查都走这里。
static func strategy_for_size(size: int) -> String:
	return STRATEGY_SPECIAL5 if size >= SPECIAL_POOL_SIZE else STRATEGY_STANDARD


## 请求的路径；缺 size 时按普通三选一处理。
static func strategy_of(request: Dictionary) -> String:
	return strategy_for_size(maxi(int(request.get("size",3)),1))


## 第四层起所有候选都有Lv4资格；更早楼层只认请求自带的开关，前三层仍由章节过滤排除。
static func lv4_open(request: Dictionary) -> bool:
	return bool(request.get("lv4_enabled",false)) or int(request.get("chapter",0)) >= 4


## 资格过滤使用的池类型：普通路径统一为 build，旧五选一沿用请求的 pool_type。
static func eligibility_pool(request: Dictionary) -> String:
	if strategy_of(request) == STRATEGY_STANDARD:
		return POOL_BUILD
	return str(request.get("pool_type",POOL_HIGH))
