import Foundation

// MARK: - 创作法典（CraftCodex）
//
// 把网文与传统文学两套创作法沉淀成**可被代码消费**的知识，而不是一段塞进 prompt 的鸡汤：
// 1. 流派档案（GenreProfile）：惯例 / 禁区 / 爽点形态 / 开篇律 / 节奏参数 / 体系通胀控制；
// 2. 网文创作法（WebNovelCraft）：黄金三章、期待感管理、断章钩子类型学、爽点类型学、
//    打脸循环、金手指代价律、卷弧结构、主角能动性；
// 3. 传统文学创作法（LiteraryCraft）：草蛇灰线、白描、意象、留白、视角与叙述距离、
//    典型环境中的典型人物、春秋笔法、起承转合、文气、复调。
//
// 纪律：法典只**提示**与**度量**，不替作者做正典决定。所有产出仍走提案通道。
// 确定性部分（钩子分类、具体性判定、节奏度量）零 LLM 成本，可被 AILint / SkeletonGate 直接调用。

// MARK: - 断章钩子类型学

/// 章尾钩子的七种形态。网文断章不是「留个悬念」这么笼统——不同形态对应不同的读者心理机制，
/// 连续多章用同一种形态会形成可预测的套版感（这也是 AI 味的来源之一）。
enum HookKind: String, Codable, CaseIterable {
    case suspense   = "悬念"     // 抛出一个读者必须知道答案的问题
    case peril      = "危机"     // 威胁已经迫近，章末停在最坏的一刻之前
    case reversal   = "反转"     // 颠覆此前建立的认知
    case gap        = "信息差"   // 读者知道角色不知道（或反之），张力来自等待碰撞
    case promise    = "承诺"     // 明示某件事即将兑现，把期待感挂到下一章
    case emotion    = "情绪"     // 关系或内心走到临界点，停在未落下的那一句
    case arrival    = "登场"     // 新人物 / 新事物 / 新消息进门

    /// 判定关键词（确定性分类用；命中多类时取权重最高的）
    fileprivate var cues: [String] {
        switch self {
        case .suspense: return ["为什么", "怎么会", "是谁", "到底是什么", "难道", "究竟是什么", "?", "？"]
        case .peril:    return ["来了", "逼近", "追来", "杀到", "包围", "动手", "落下", "压顶", "冲过来", "扑来", "举起了"]
        case .reversal: return ["却", "竟然是", "原来是", "没想到", "反过来", "正是他", "恰恰", "反而是"]
        case .gap:      return ["并不知道", "还不清楚", "只有他知道", "瞒着", "暗处", "背地里", "没说出口"]
        case .promise:  return ["明日", "三日之后", "等到", "到时候", "下一步", "该轮到", "很快", "约定"]
        case .emotion:  return ["没有说话", "转过身", "闭上眼睛", "手在抖", "喉头", "别过脸", "沉默"]
        case .arrival:  return ["门外", "有人", "脚步声", "推门", "信", "来了一个人", "突然出现", "传来"]
        }
    }

    /// 该形态最容易写砸的方式（给作者的反面提醒）
    var failureMode: String {
        switch self {
        case .suspense: return "问题太大太虚（『命运的齿轮开始转动』）——悬念必须挂在一个具体物件或具体选择上"
        case .peril:    return "危机反复不落地（狼来了三次都没咬人）——迫近三次就必须兑现一次"
        case .reversal: return "反转没有前置伏笔，变成耍赖——反转要能回指到此前埋下的至少一处细节"
        case .gap:      return "信息差拖太久不碰撞，读者失去耐心——差值要有兑现期限"
        case .promise:  return "承诺空泛（『他一定会变强』）——承诺要具体到可验证的事件"
        case .emotion:  return "情绪停在内心独白里，没有动作承载——临界点要有一个可拍成的画面"
        case .arrival:  return "登场即解释来历，把悬念一次发完——新事物进门先给现象，来历往后压"
        }
    }
}

// MARK: - 流派档案

enum CraftGenre: String, Codable, CaseIterable {
    case xuanhuan   = "玄幻"
    case xianxia    = "仙侠"
    case wuxia      = "武侠"
    case urban      = "都市"
    case scifi      = "科幻"
    case mystery    = "悬疑推理"
    case history    = "历史"
    case romance    = "言情"
    case infinite   = "无限流"
    case gameLit    = "游戏竞技"
    case horror     = "灵异惊悚"
    case literary   = "纯文学"
    case general    = "通用"
}

struct GenreProfile {
    var genre: CraftGenre
    /// 用于从作者填的自由文本 genre 里模糊匹配
    var aliases: [String]
    /// 读者带着进来的预期（不满足就是「不对味」）
    var conventions: [String]
    /// 踩了就崩盘的禁区
    var taboos: [String]
    /// 本题材的爽点形态（可兑现的期待类型）
    var payoffForms: [String]
    /// 开篇律
    var openingRule: String
    /// 节奏参数
    var pacingNote: String
    /// 力量 / 资源 / 信息体系的通胀控制
    var inflationNote: String
}

enum GenreProfiles {
    static let all: [GenreProfile] = [
        GenreProfile(
            genre: .xuanhuan, aliases: ["玄幻", "东方玄幻", "异世大陆", "王朝争霸", "高武"],
            conventions: ["境界体系清晰可数，读者随时知道主角差几级", "越级战斗要有代价或凭仗，不能白给",
                          "宗门/家族/势力构成外部压力网", "资源（功法、丹药、法宝）稀缺性驱动冲突"],
            taboos: ["境界体系中途改规则（前期一境难求，后期遍地走）", "主角变强靠别人赠予而非争取",
                     "反派智商随剧情需要波动", "打脸没有铺垫，读者不认识被打的人"],
            payoffForms: ["越级斩敌", "身份揭破（扮猪吃虎）", "秘境夺宝抢先一步", "旧敌俯首", "被轻视后当众证明"],
            openingRule: "前三章必须给出：主角当下的屈辱或匮乏、金手指的初次异动、一个近期可达的具体目标。不要写世界观导览。",
            pacingNote: "每 3-5 章一个小爽点，每 15-25 章一个境界/势力层级的跨越；战斗不超过 2 章，超了就是水。",
            inflationNote: "每提升一个大境界，同时抬高一层的对手与代价；旧资源必须在新层级失效，否则数值崩盘。"),
        GenreProfile(
            genre: .xianxia, aliases: ["仙侠", "修真", "修仙", "古典仙侠", "幻想修仙"],
            conventions: ["修行有代价（寿元、心魔、因果、情劫）", "长生与情感的取舍是母题",
                          "机缘与根骨并存，纯靠努力或纯靠运气都失真", "宗门礼法与江湖规矩构成行为约束"],
            taboos: ["修行无痛感，突破像升级打卡", "因果只挂在嘴上不落实", "仙人行事如市井无赖，失了气象",
                     "情劫用完就丢，不留痕迹"],
            payoffForms: ["道心印证（此前的坚持被证明是对的）", "以弱胜强但付出可见代价", "旧友/宿敌的境界对照",
                          "天机窥破一角", "渡劫成功后的气象变化"],
            openingRule: "开篇给一个「为什么要修行」的具体理由（亲人、仇、命），不要给「因为强者受人尊敬」这种抽象动机。",
            pacingNote: "境界推进可以慢，但每一次停滞都要有戏；闭关不能跳过时间不给交代。",
            inflationNote: "寿元、法力、因果债三条曲线要互相牵制——一条独涨就是失衡。"),
        GenreProfile(
            genre: .wuxia, aliases: ["武侠", "传统武侠", "新武侠", "江湖"],
            conventions: ["恩怨有来由，仇不是凭空的", "武功有师承与路数，招式可辨识",
                          "江湖规矩（信义、名声、门派立场）构成真实约束", "侠之大者的价值张力"],
            taboos: ["主角无敌后故事继续拖", "恩怨用误会撑起全书而不揭破", "武功靠奇遇一步登天且无后患",
                     "女性角色只作为奖赏存在"],
            payoffForms: ["快意恩仇", "以信义服人", "绝学在关键时刻的恰当应用", "身份/师承揭破", "舍身护人后的名动江湖"],
            openingRule: "开篇一场具体的江湖事件（护镖、寻仇、夺谱），在事件里带出人物关系，不要先介绍门派谱系。",
            pacingNote: "武打段落要短促有节奏，一场决斗 800-2000 字为宜；恩怨线每卷至少推进一层。",
            inflationNote: "武力上限早早封顶，之后的张力来自人心、立场与代价，而不是更强的敌人。"),
        GenreProfile(
            genre: .urban, aliases: ["都市", "都市生活", "职场", "商战", "都市异能", "现实题材"],
            conventions: ["社会规则真实可查（职场、法律、医疗、金融）", "人际关系的利益与情感交织",
                          "主角的资源与人脉有明确来源", "冲突来自体制、资本、家庭、身份的挤压"],
            taboos: ["专业知识硬伤（读者里有内行）", "打脸靠莫名其妙的身份碾压", "配角全员势利眼",
                     "钱的数量级前后矛盾"],
            payoffForms: ["专业上折服对手", "被低估后拿到实证", "在规则内反将一军", "护住该护的人", "旧关系的和解或切割"],
            openingRule: "开篇把主角放进一个具体的社会处境（一份工作、一笔债、一场饭局），冲突要在生活逻辑里成立。",
            pacingNote: "情绪张力靠关系推进而非打斗；每章至少一次人际关系的实质变化。",
            inflationNote: "资源增长要有对手盘——赚到的每一笔都要有人亏，否则世界像单机游戏。"),
        GenreProfile(
            genre: .scifi, aliases: ["科幻", "未来", "星际", "赛博朋克", "末世", "废土", "时空"],
            conventions: ["设定自洽且一以贯之（一个核心假设推到底）", "技术有代价与外部性",
                          "世界观通过人物处境呈现，不通过说明书", "科学逻辑可以被质疑但不能被无视"],
            taboos: ["核心设定中途改口", "技术万能（什么都能解决就没有戏）", "为炫设定而停剧情",
                     "末世里社会结构凭空消失"],
            payoffForms: ["设定的一次非显然推论兑现", "技术反噬", "认知尺度的跃迁（个人→文明→宇宙）",
                          "在规则内找到唯一解", "旧设定的重新解读"],
            openingRule: "开篇让人物被设定压着走一次（技术失效、规则伤人），读者自然记住这个世界怎么运转。",
            pacingNote: "信息释放要节流：每章只揭一层设定；大揭示留到卷末。",
            inflationNote: "技术能力每上一档，同时引入一个不可解的新约束，避免全能化。"),
        GenreProfile(
            genre: .mystery, aliases: ["悬疑", "推理", "侦探", "刑侦", "悬疑推理", "本格"],
            conventions: ["线索对读者公平呈现（可回溯）", "诡计有物理/逻辑可行性",
                          "动机成立（人为何要这么做）", "叙述者不可靠时要有可查的破绽"],
            taboos: ["凶手是最后才出场的人", "关键线索隐瞒不给读者", "用超自然解释本格谜题（除非题材如此）",
                     "侦探靠灵感而非证据"],
            payoffForms: ["线索回收的瞬间（读者能拍腿）", "叙述性诡计揭破", "动机的人性厚度",
                          "第二层真相推翻第一层", "看似无关的支线并入主案"],
            openingRule: "开篇给尸体或异常事件，同时至少埋两处后续要回收的细节；不要先写侦探的日常。",
            pacingNote: "每 2-3 章推进一次调查（新线索或旧线索被推翻）；红鲱鱼要有，但每根都要有解释。",
            inflationNote: "真相分层释放，每层都要能解释上一层的疑点，不能只增加疑问。"),
        GenreProfile(
            genre: .history, aliases: ["历史", "架空历史", "穿越历史", "古代言情", "宫斗", "权谋"],
            conventions: ["时代物质生活细节可信（衣食住行、货币、称谓）", "权力运作有其制度逻辑",
                          "人物思想不超越时代太多（穿越者的现代知识要付代价）", "礼法与身份约束行为"],
            taboos: ["史实硬伤（内行读者会逐条挑）", "用现代价值观直接碾压古人且无反噬",
                     "宫廷斗争只靠下毒和偷听", "称谓/官职混乱"],
            payoffForms: ["以制度缝隙破局", "预知大势的一次兑现", "在礼法内反将一军", "身份揭破",
                          "旧布局多年后收线"],
            openingRule: "开篇把主角钉在一个具体的身份处境上（贬官、待嫁、为奴、从军），身份决定他能做什么。",
            pacingNote: "权谋线要慢火，一次布局跨数卷；每章给一处可信的时代细节锚定质感。",
            inflationNote: "权力每升一级，敌人从个人变成制度，代价从性命变成道义。"),
        GenreProfile(
            genre: .romance, aliases: ["言情", "现代言情", "古代言情", "甜宠", "虐恋", "纯爱"],
            conventions: ["情感推进有可见的理由与代价", "两人之间有真实障碍（不是误会堆出来的）",
                          "双向的能动性（不是一方追一方跑到底）", "关系里程碑清晰"],
            taboos: ["障碍全靠不说清楚（一次沟通能解决的问题拖十章）", "配角工具化只为主角感情服务",
                     "情感转折没有铺垫", "伤害被浪漫化而不被追究"],
            payoffForms: ["关系推进（承认、和解、并肩）", "为对方付出可见代价", "旧伤被真正理解",
                          "公开的选择", "势均力敌的一次交锋"],
            openingRule: "开篇让两人因一件具体的事被迫打交道，别用偶遇撞满怀。",
            pacingNote: "每 2-3 章一次关系温度变化（升或降）；长期平稳即注水。",
            inflationNote: "障碍升级要换性质（外部→家庭→自我→价值冲突），不要只是换强度。"),
        GenreProfile(
            genre: .infinite, aliases: ["无限流", "副本", "系统流", "快穿", "主神"],
            conventions: ["规则明确公布且不可赖账", "副本/任务有独立小结构（进入-探索-破局-结算）",
                          "积分与能力的兑换经济清晰", "队友关系与背叛是核心张力"],
            taboos: ["规则临时新增以救场", "结算奖励前后不一致", "副本之间主角成长断层",
                     "队友降智以凸显主角"],
            payoffForms: ["规则漏洞的正确利用", "绝境翻盘", "积分兑换的关键抉择", "身份/来历揭示",
                          "跨副本的旧伏笔回收"],
            openingRule: "开篇第一个副本就要完整走一遍规则（含一次代价），读者才知道这本书怎么玩。",
            pacingNote: "副本内节奏紧（每章一个发现或一次危机），副本间用来消化与布局，不能空转。",
            inflationNote: "积分通胀要与副本难度同步；每轮结算后明确「什么变贵了」。"),
        GenreProfile(
            genre: .gameLit, aliases: ["游戏", "网游", "电竞", "竞技", "体育", "游戏竞技"],
            conventions: ["规则/数值可查且一致", "胜负有战术原因", "团队分工与个人高光并存",
                          "对手值得尊敬（不是纯反派）"],
            taboos: ["数值前后矛盾", "胜利靠对手失误而非己方决策", "战术只在解说里存在",
                     "现实中的人格与游戏内表现割裂且无解释"],
            payoffForms: ["战术执行成功", "逆境翻盘的具体操作", "被低估后的正名", "团队配合的默契瞬间",
                          "对旧对手的复仇或超越"],
            openingRule: "开篇一场对局或一次选拔，在过程中交代规则与主角的短板。",
            pacingNote: "对局节奏按回合/阶段切分，每章收在一个决策点；训练期不能长于两章。",
            inflationNote: "对手强度与主角能力同步提升，同时引入新的战术维度，避免纯数值堆叠。"),
        GenreProfile(
            genre: .horror, aliases: ["灵异", "惊悚", "恐怖", "诡异", "克苏鲁", "悬疑灵异"],
            conventions: ["恐惧来自未知与信息不对称", "规则类恐怖要公布部分规则留部分空白",
                          "日常质感越真实，异常越有效", "代价与逃生条件明确"],
            taboos: ["怪物全知全能导致无解", "恐惧靠音效式描写堆砌（突然、猛地）", "规则随剧情改",
                     "角色作死 without 可信动机"],
            payoffForms: ["规则被正确理解的一刻", "以代价换生路", "真相揭示后的重新解读",
                          "同伴牺牲的重量", "逃出生天但留下了什么"],
            openingRule: "开篇先建立日常的确定性，再用一个不该存在的小细节破坏它；不要开篇就鬼影幢幢。",
            pacingNote: "紧张-松弛交替，连续高压会钝化恐惧；每次松弛都要留一根刺。",
            inflationNote: "威胁升级要靠规则的进一步揭示，而不是怪物变得更大更强。"),
        GenreProfile(
            genre: .literary, aliases: ["纯文学", "严肃文学", "文学", "现实主义", "散文体"],
            conventions: ["人物内在复杂度高于情节强度", "语言本身承担意义（节奏、意象、留白）",
                          "主题不直说，通过结构与细节呈现", "允许不确定与未解决"],
            taboos: ["主题被叙述者解释出来", "人物为观点服务而失去血肉", "情节靠巧合推动",
                     "结尾给出道德总结"],
            payoffForms: ["一个意象的第三次出现改变了含义", "人物做出违背自身利益却合乎其性格的选择",
                          "沉默与未说出的部分被读者补完", "时间跨度带来的对照", "细节的回响"],
            openingRule: "开篇给一个具体的、有点不对劲的日常场景，让人物的处境自己说话。",
            pacingNote: "节奏服务于情绪而非悬念；允许慢，但每一段都要有存在的理由。",
            inflationNote: "不适用数值体系——张力来自人物关系的不可逆变化。"),
        GenreProfile(
            genre: .general, aliases: [],
            conventions: ["冲突要具体（谁要什么、被谁挡住、代价是什么）", "人物有超出剧情需要的内在生活",
                          "信息按读者需要释放，不按作者知道多少释放"],
            taboos: ["把设定当剧情", "用巧合解决自己制造的困境", "结尾总结主题", "人物只为推进情节而存在"],
            payoffForms: ["期待兑现", "认知反转", "关系变化", "能力/资源的实质提升", "真相揭示"],
            openingRule: "开篇三章内让读者知道：主角是谁、缺什么、被什么挡着、这本书会给他什么。",
            pacingNote: "每章至少推进一件事（情节、关系或认知），纯描写章不能连续出现。",
            inflationNote: "任何体系（力量、财富、信息）都要有上限与代价，增长必须伴随对手盘升级。"),
    ]

    /// 从作者填的自由文本里模糊匹配流派档案
    static func match(_ genreText: String) -> GenreProfile {
        let t = genreText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return all.first { $0.genre == .general }! }
        // 先精确，再包含；命中多个别名时取别名更长的那个（「都市异能」优先于「都市」）
        var best: (profile: GenreProfile, score: Int)? = nil
        for p in all {
            for a in p.aliases {
                guard !a.isEmpty else { continue }
                let score: Int
                if t == a || t == p.genre.rawValue { score = 1000 + a.count }
                else if t.contains(a) { score = 100 + a.count }
                else if a.contains(t) { score = 50 + t.count }
                else { continue }
                if best == nil || score > best!.score { best = (p, score) }
            }
            if p.genre.rawValue == t, best == nil { best = (p, 2000) }
        }
        return best?.profile ?? all.first { $0.genre == .general }!
    }
}

// MARK: - 网文创作法

enum WebNovelCraft {
    /// 黄金三章：网文开篇的硬约束。前三章决定读者去留，不是「慢慢铺」。
    static let goldenThreeChapters = """
    黄金三章（开篇三章的硬指标，逐条核对）：
    1. 第一章前 500 字内出现一个具体的异常/冲突/匮乏，不要写天气、不要写世界观。
    2. 第一章内让读者知道主角「缺什么」（钱、命、尊严、亲人、天赋、自由），缺得越具体越好。
    3. 第二章给出改变的契机（金手指异动、机会出现、被迫上路），契机要付出代价或有条件。
    4. 第三章完成第一次小兑现 + 立一个近期目标（3-10 章内可达），让读者有可期待的东西。
    5. 三章内至少埋 2 处后文要回收的细节，且不能明示「这是伏笔」。
    6. 三章内不要出现超过 6 个有名字的人物，不要出现名词堆砌的势力谱系。
    """

    /// 期待感管理：网文的真正引擎不是爽点，是「尚未兑现的期待」。
    static let expectationManagement = """
    期待感管理（网文的引擎是「尚未兑现」，不是「已经爽到」）：
    - 三层期待并行：即时期待（本章内兑现）、近期期待（3-10 章）、长期期待（跨卷/全书）。任一层空了，读者就走。
    - 挂账与销账：每次兑现一个期待，同时挂上一个新的（揭 1 埋 1）。销账快于挂账 → 后劲不足；挂账远快于销账 → 读者觉得被骗。
    - 期待要可验证：「他会在宗门大比上赢」是可验证的期待；「他会变强」不是。
    - 兑现要略超预期：完全按预期兑现＝平淡；完全出乎意料＝耍赖。正确做法是「结果如预期，过程或代价出乎意料」。
    - 拖欠要有利息：一个期待拖得越久，兑现时的规格要越高；拖过期限还不兑现，读者会记账。
    """

    /// 爽点类型学（可兑现的期待形态）
    static let payoffTypes = [
        "打脸（被轻视→当众证明）", "越级（以弱胜强，需凭仗或代价）", "夺先（资源/机缘抢先一步）",
        "揭破（隐藏身份或真相公开）", "护短（为在乎的人出手并成功）", "反将（在对方规则内取胜）",
        "成长兑现（长期积累的一次显性化）", "认知优越（读者比角色先看懂，看角色撞墙）",
        "情义回报（旧恩得到偿还）", "掌控（从被摆布到能选择）",
    ]

    /// 打脸循环：网文最常用也最容易写烂的结构。
    static let faceSlapLoop = """
    打脸循环（四拍，缺一拍就变成主角耍横）：
    1. 轻视建立：对方有可信的理由轻视主角（身份、资历、外表、过往），不是无端恶意。
    2. 代价前置：主角此时不反抗，有他的理由（隐忍、时机未到、有更重要的事）。
    3. 兑现：证明的方式要与「被轻视的那一点」正面对应（被笑剑法差就用剑法赢）。
    4. 余波：赢之后世界怎么变了（名声、关系、新的敌人）——没有余波的打脸是一次性的糖。
    反面：连续打脸同一批人、对手智商归零、赢靠外援，都会让爽感迅速贬值。
    """

    /// 金手指代价律
    static let goldenFingerCost = """
    金手指代价律：外挂必须有限制，限制才是戏剧性的来源。
    - 三种限制至少占一种：使用条件（时间/地点/资源）、使用代价（寿元/记忆/情感/因果）、成长上限（需要升级或解锁）。
    - 限制要在第一次使用时就让读者看见，不能等剧情需要时才补。
    - 每次靠金手指解决问题，同时要制造一个新问题（否则剧情会失去阻力）。
    - 金手指不能解决「人心」问题——那是人物弧光的领地。
    """

    /// 卷弧结构
    static let volumeArc = """
    卷弧结构（每卷是一个完整的中篇，不是章节的堆叠）：
    - 起：新处境（地点/势力/目标切换），把上一卷的余波带进来。
    - 承：能力与关系在新规则下受挫一次，读者重新学习这个场域怎么玩。
    - 转：本卷核心冲突升级，旧伏笔在此卷兑现一部分。
    - 合：卷末大战/大揭，兑现本卷最大期待，同时抛出下一卷的钩子（跨卷悬念）。
    - 体量：一卷 20-40 章；卷末必须有一次规格明显高于卷内的兑现，否则读者感觉不到「一段结束」。
    """

    /// 主角能动性
    static let agencyRule = """
    主角能动性（读者弃书最常见的原因之一是「主角被剧情推着走」）：
    - 每个关键转折，主角必须是**做选择的人**，而不是被通知的人。
    - 允许主角犯错，但错的动机要合乎其性格；不允许主角被动等待救援超过一次。
    - 主角要知道自己想要什么（阶段性目标清晰），并为此付出可见的努力。
    - 配角可以更强，但不能替主角完成他的核心课题。
    """
}

// MARK: - 传统文学创作法

enum LiteraryCraft {
    /// 草蛇灰线，伏脉千里（脂批术语；与伏笔台账互为表里）
    static let hiddenThreads = """
    草蛇灰线，伏脉千里（《红楼》笔法，也是伏笔台账的文学根据）：
    - 埋设要「不着痕迹」：夹在闲笔、器物、称呼、天气、一句玩笑里，读者第一遍不会注意。
    - 一处伏笔至少三次现身：种下（不经意）、发展（再次出现，读者隐约记得）、回收（含义翻转）。
    - 回收时的力量来自「原来那时就写过了」，所以种下处必须真的存在过，不能事后追认。
    - 反面：埋得太显眼等于预告；埋了不收等于欠账；收得太急等于浪费。
    """

    /// 白描
    static let plainDescription = """
    白描（鲁迅推崇的笔法）：少用形容词，用准确的名词与动词。
    - 「他很紧张」→ 写他做了什么：把火柴划断了三次。
    - 一个细节胜过三个形容词；细节要选**只有这个人才会有**的那个。
    - 白描不是不描写，是把描写的负担从作者转到读者身上。
    """

    /// 意象与象征
    static let imagery = """
    意象与象征：
    - 意象要复现（同一物件/景象在不同章节出现），复现才有累积的含义。
    - 不要在文中解释意象的含义——解释一次，意象就死了。
    - 意象与情节要有真实接触点（它得是故事里真实存在的东西，不是作者贴上去的贴纸）。
    - 一本书有两三个核心意象足够，多了互相稀释。
    """

    /// 留白
    static let negativeSpace = """
    留白（不写的部分承担意义）：
    - 关键情绪的最高点可以跳过：写到临界，转场，让读者补完。
    - 对话里最重要的那句可以不说出口，用动作或沉默替代。
    - 时间跳跃处不交代全部经过，只给结果的痕迹（他瘦了，屋里多了一张椅子）。
    - 留白的前提是读者已经拥有足够信息去补——否则只是没写完。
    """

    /// 视角与叙述距离
    static let pointOfView = """
    视角与叙述距离：
    - 一章之内视角不要漂移；换视角要有明确标记（分节或换章）。
    - 叙述距离要可控：贴着人物写（用他的词汇与感知）还是拉远写（叙述者的评价），一次选一种。
    - 不可靠叙述者要留可查的破绽，让重读成立。
    - 全知的自由是负债：知道得越多，越难维持悬念与真实。
    """

    /// 典型环境中的典型人物
    static let typicality = """
    典型环境中的典型人物（恩格斯语，现实主义的核心）：
    - 人物的选择要由他的处境决定：把他放到别的环境里，他就不会这么做。
    - 环境不是布景，是压力的来源（经济、身份、礼法、时代）。
    - 性格要通过重复出现的行为模式建立，而不是通过一次性的大事件宣告。
    """

    /// 春秋笔法
    static let springAndAutumn = """
    春秋笔法（一字寓褒贬）：
    - 用词的选择本身就是评价：「杀」「诛」「弑」「死」各不相同。
    - 作者不站出来判断，让叙述的用词与结构承担判断。
    - 反面是「作者急于表态」：形容词与副词泛滥，读者的判断空间被剥夺。
    """

    /// 起承转合
    static let structure = """
    起承转合（章内与卷内通用的四拍）：
    - 起：接续上文的势能，给出本章的具体处境（不要重新开场）。
    - 承：把处境推进一层，制造阻力或加深关系。
    - 转：出现一个此前没有的变量，改变局面的性质（不是强度）。
    - 合：收在一个具体的画面或决定上，把余势交给下一章——合不是解决，是换挡。
    """

    /// 文气与节奏
    static let rhythm = """
    文气与节奏（韩愈「气盛言宜」）：
    - 句长要参差：长句铺陈，短句收束；连续等长句会失去呼吸。
    - 段落长度也要参差，一段一字与一段三百字都可以存在。
    - 紧张处用短句与动作，松弛处才允许描写与闲笔——顺序反了就泄气。
    - 一章之内至少一次节奏换挡（快→慢或慢→快），全程一个速度等于没有速度。
    """

    /// 复调（巴赫金论陀思妥耶夫斯基）
    static let polyphony = """
    复调（多声部）：
    - 让不同人物持有各自成立的世界观，作者不裁判谁对。
    - 反派的理由要能说服一部分读者，否则冲突只是善恶打卡。
    - 对话要「吵具体的事」，让价值观在行动选择中碰撞，不在台词里辩论。
    """
}

// MARK: - 法典组装与确定性度量

enum CraftCodex {
    /// 空泛结尾词（章末出现即视为钩子失效）——与 AILint.foreshadowTeasers 互补
    static let vagueEndings: [String] = [
        "命运的齿轮", "一切才刚刚开始", "故事才刚刚开始", "他知道，这一切", "他终于明白",
        "她终于明白", "原来如此", "这就是命运", "未来的路还很长", "一切都会好起来",
        "他不知道的是", "她不知道的是", "殊不知", "谁也没有想到", "等待着他的",
        "一场风暴即将来临", "暗流涌动", "风起云涌", "变天了",
    ]

    /// 空泛钩子的判定词（用于确定性判「钩子是否具体」）
    private static let abstractHookWords: [String] = [
        "命运", "未来", "一切", "某种", "说不清", "莫名", "隐约", "似乎有什么", "一种不安",
        "预感", "宿命", "轮回", "真相", "秘密",
    ]

    /// 具体性锚点：钩子里出现这些类别的词，说明它挂在可拍摄的东西上
    private static let concreteAnchors: [String] = [
        "刀", "剑", "枪", "信", "书", "钥匙", "戒指", "玉", "牌", "印", "灯", "门", "窗", "锁",
        "血", "尸", "药", "毒", "酒", "茶", "钱", "账", "契", "图", "镜", "钟", "船", "车", "马",
        "手", "眼", "指", "背", "肩", "喉", "伤口", "疤",
    ]

    /// 确定性判定：一段章尾文本的钩子是否「具体」（挂在物件/动作/人身上，而非抽象概念）
    /// 返回 (是否具体, 命中的锚点, 命中的空泛词)
    static func hookConcreteness(_ text: String) -> (concrete: Bool, anchors: [String], vague: [String]) {
        let tail = String(text.suffix(400))
        let anchors = concreteAnchors.filter { tail.contains($0) }
        let vague = (vagueEndings + abstractHookWords).filter { tail.contains($0) }
        // 有具体锚点且空泛词不多 → 具体；只有空泛词 → 空泛
        let concrete = !anchors.isEmpty && vague.count <= anchors.count
        return (concrete, anchors, vague)
    }

    /// 确定性分类：一段章尾文本最可能属于哪种钩子形态（nil = 判不出）
    static func classifyHook(_ text: String) -> HookKind? {
        let tail = String(text.suffix(400))
        guard !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var best: (kind: HookKind, score: Int)? = nil
        for kind in HookKind.allCases {
            let score = kind.cues.reduce(0) { $0 + (tail.contains($1) ? 1 : 0) }
            if score > 0, best == nil || score > best!.score { best = (kind, score) }
        }
        return best?.kind
    }

    /// 确定性度量：一段文本的「爽点/推进事件」密度指标——动作动词与冲突词的千字密度。
    /// 不是文学评价，只是给作者一个可比对的数字（跨章横向对比能看出哪里在注水）。
    static func tensionDensity(_ text: String) -> Double {
        let chars = max(1, WordStats.chineseCount(text))
        let markers = ["打", "杀", "抢", "夺", "逃", "追", "撞", "砸", "撕", "砍", "刺", "抓", "推", "拉",
                       "喊", "吼", "冷笑", "怒", "怕", "痛", "血", "死", "赢", "输", "赌", "骗", "逼", "让"]
        let hits = markers.reduce(0) { $0 + text.occurrences(of: $1) }
        return Double(hits) / Double(chars) * 1000.0
    }

    /// 组装注入 prompt 的法典片段。按能力裁剪，避免把整部法典塞进每次调用（token 成本）。
    /// - Parameters:
    ///   - capability: 当前 AI 能力（决定要哪一部分法典）
    ///   - genreText: 作者填的自由文本题材
    ///   - progress: (已写章数, 目标章数)，用于判断是否处于开篇期/卷末
    static func codex(for capability: AICapability, genreText: String, progress: (written: Int, target: Int)? = nil) -> String {
        let profile = GenreProfiles.match(genreText)
        var parts: [String] = []

        // 流派档案：所有能力都要知道题材惯例与禁区
        parts.append("""
        【题材：\(profile.genre.rawValue)】
        读者预期（不满足就是不对味）：
        \(profile.conventions.map { "- " + $0 }.joined(separator: "\n"))
        禁区（踩了就崩）：
        \(profile.taboos.map { "- " + $0 }.joined(separator: "\n"))
        可用的爽点形态：\(profile.payoffForms.joined(separator: "、"))
        体系通胀控制：\(profile.inflationNote)
        """)

        switch capability {
        case .framework, .outlineTimeline:
            parts.append(WebNovelCraft.goldenThreeChapters)
            parts.append(WebNovelCraft.expectationManagement)
            parts.append(WebNovelCraft.volumeArc)
            parts.append("开篇律：" + profile.openingRule)
            parts.append("节奏参数：" + profile.pacingNote)
            parts.append(LiteraryCraft.hiddenThreads)
        case .chapterSkeleton:
            parts.append("节奏参数：" + profile.pacingNote)
            parts.append(WebNovelCraft.expectationManagement)
            parts.append(LiteraryCraft.structure)
            parts.append(LiteraryCraft.hiddenThreads)
            parts.append(hookGuidance())
            if let p = progress, p.written <= 3 { parts.append(WebNovelCraft.goldenThreeChapters) }
        case .chapterDraft, .chapterRevise:
            parts.append("节奏参数：" + profile.pacingNote)
            parts.append(LiteraryCraft.plainDescription)
            parts.append(LiteraryCraft.rhythm)
            parts.append(LiteraryCraft.negativeSpace)
            parts.append(LiteraryCraft.polyphony)
            parts.append(WebNovelCraft.agencyRule)
            if profile.genre == .literary {
                parts.append(LiteraryCraft.imagery)
                parts.append(LiteraryCraft.springAndAutumn)
                parts.append(LiteraryCraft.pointOfView)
                parts.append(LiteraryCraft.typicality)
            }
        case .clueLedger, .memoryExtract:
            parts.append(LiteraryCraft.hiddenThreads)
            parts.append(WebNovelCraft.expectationManagement)
        case .validation:
            parts.append("审校只查客观错误。题材禁区可作为「设定违背」的判定参照：")
            parts.append(profile.taboos.map { "- " + $0 }.joined(separator: "\n"))
        case .continuityAudit:
            parts.append("审校只查客观错误，不评文笔。本题材最容易崩的连贯性维度：")
            parts.append(profile.taboos.map { "- " + $0 }.joined(separator: "\n"))
            parts.append("体系通胀控制（判断「能力/资源前后不一致」的参照）：" + profile.inflationNote)
            parts.append(LiteraryCraft.hiddenThreads)
            parts.append(WebNovelCraft.expectationManagement)
        case .outlineSync:
            parts.append("判断偏差该改大纲还是该改后文时，按这套节奏参数与卷弧结构判：")
            parts.append("节奏参数：" + profile.pacingNote)
            parts.append(WebNovelCraft.volumeArc)
            parts.append(WebNovelCraft.expectationManagement)
        case .deslop:
            parts.append(LiteraryCraft.plainDescription)
            parts.append(LiteraryCraft.rhythm)
            parts.append(LiteraryCraft.springAndAutumn)
            parts.append(LiteraryCraft.negativeSpace)
            if profile.genre != .literary {
                parts.append("网文校准：去AI味不等于去掉爽感与节奏——保留钩子强度、保留口语化的对白锋芒，别把网文改成散文。")
            }
        case .recallMemo:
            parts.append(WebNovelCraft.expectationManagement)
            parts.append("节奏参数：" + profile.pacingNote)
        }
        return parts.joined(separator: "\n\n")
    }

    /// 钩子指导（含类型学与反面清单）——骨架与草稿共用
    static func hookGuidance() -> String {
        let kinds = HookKind.allCases.map { "- \($0.rawValue)：\($0.failureMode)" }.joined(separator: "\n")
        return """
        断章钩子类型学（连续多章用同一种形态会形成套版感，要有意识地轮换）：
        \(kinds)
        硬要求：钩子必须挂在**具体的物件、动作或人**上，不能挂在抽象概念（命运/未来/一切/真相）上。
        章末空泛预告一律禁止（"他不知道的是"、"命运的齿轮开始转动"、"一切才刚刚开始"）。
        """
    }

    /// 供 UI「创作法典」面板展示：把当前书的流派档案与两套创作法整理成人读的一页
    static func referencePage(genreText: String) -> String {
        let p = GenreProfiles.match(genreText)
        return """
        # 创作法典 · \(p.genre.rawValue)

        ## 一、本题材的读者契约
        **读者预期**
        \(p.conventions.map { "- " + $0 }.joined(separator: "\n"))

        **禁区**
        \(p.taboos.map { "- " + $0 }.joined(separator: "\n"))

        **可用爽点形态**
        \(p.payoffForms.map { "- " + $0 }.joined(separator: "\n"))

        **开篇律**：\(p.openingRule)

        **节奏参数**：\(p.pacingNote)

        **体系通胀控制**：\(p.inflationNote)

        ## 二、网文创作法
        ### 黄金三章
        \(WebNovelCraft.goldenThreeChapters)

        ### 期待感管理
        \(WebNovelCraft.expectationManagement)

        ### 打脸循环
        \(WebNovelCraft.faceSlapLoop)

        ### 金手指代价律
        \(WebNovelCraft.goldenFingerCost)

        ### 卷弧结构
        \(WebNovelCraft.volumeArc)

        ### 主角能动性
        \(WebNovelCraft.agencyRule)

        ## 三、传统文学创作法
        ### 草蛇灰线，伏脉千里
        \(LiteraryCraft.hiddenThreads)

        ### 白描
        \(LiteraryCraft.plainDescription)

        ### 意象与象征
        \(LiteraryCraft.imagery)

        ### 留白
        \(LiteraryCraft.negativeSpace)

        ### 视角与叙述距离
        \(LiteraryCraft.pointOfView)

        ### 典型环境中的典型人物
        \(LiteraryCraft.typicality)

        ### 春秋笔法
        \(LiteraryCraft.springAndAutumn)

        ### 起承转合
        \(LiteraryCraft.structure)

        ### 文气与节奏
        \(LiteraryCraft.rhythm)

        ### 复调
        \(LiteraryCraft.polyphony)

        ## 四、断章钩子类型学
        \(hookGuidance())
        """
    }
}
