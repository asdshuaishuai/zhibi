#!/usr/bin/env python3
"""Mock OpenAI 兼容端点，用于执笔的宿主往返自检。

    python3 Scripts/mock_model_server.py <port> <请求转储目录>

它做三件事：
1. 收下 /chat/completions 请求，把请求体原样转储成 reqN.json（自检据此断言
   prompt 里真的带上了创作法典、工具 schema 真的发出去了）；
2. 首轮请求回一个 tool_calls，工具名取请求里第一个 propose_*，参数用下方 CANNED 里
   按 schema 写好的合法样本；
3. 带 tool 结果的第二轮请求回一句收尾文本，结束 agent 循环。

存在的理由：真实模型往返需要密钥、要花钱、还不确定。而「工具 schema 写错 →
ProposalToolBridge 静默降级成空 schema → 模型拿不到字段定义 → 产出必然不合格」
这条链路上没有密钥就永远测不到。mock 端点让它变成一条可重复的确定性回归。
"""
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# 各能力的主工具，排在前面优先命中
PRIMARY_TOOLS = [
    "propose_skeleton", "propose_continuity", "propose_outline_updates", "propose_draft",
    "propose_memory", "propose_validation", "propose_deslop", "propose_memo",
    "propose_canon", "propose_storylines", "propose_outline_events", "propose_clues",
]

CANNED = {
    "propose_skeleton": {
        "note": "按主线与台账搭的三拍，场景层已填。",
        "beats": [
            {"summary": "少年在废窑醒来，发现断刀不见了", "purpose": "推进", "suggested_words": 800,
             "pov": "少年", "location": "废窑", "time_label": "当夜", "cast": ["少年"],
             "turn": "从安全到失物"},
            {"summary": "老周把刀送回来，说刀是从河里捞的", "purpose": "埋伏笔", "suggested_words": 900,
             "clue_ids": ["F01"], "pov": "少年", "location": "河边棚屋", "time_label": "次日清晨",
             "cast": ["少年", "老周"], "turn": "从怀疑到欠人情"},
            {"summary": "宗门来人查河，他躲进船底被看见", "purpose": "爽点", "suggested_words": 1300,
             "pov": "少年", "location": "渡口", "time_label": "次日午后", "cast": ["少年", "宗门使者"],
             "turn": "从躲藏到暴露"},
        ],
        "end_hook": "船板缝里垂下来一只鞋，鞋面上绣着他自己家的纹样。",
        "hook_kind": "悬念",
        "pov": "少年",
        "must_deliver": ["断刀来历推进一层"],
        "must_avoid": ["结尾不要决定+接纳+成长三连", "章末不写主题总结"],
        "clue_touches": [{"clue_id": "F01", "action": "develop",
                          "requirement": "老周说出刀是河里捞的，但不说哪段河"}],
        "payoff_type": "认知优越",
        "new_expectation": "他会查出断刀是从哪段河里捞的",
        "volume_label": "第一卷",
    },
    "propose_continuity": {
        "note": "补两条确定性扫描查不出来的问题。",
        "issues": [
            {"severity": "warning", "category": "动机断裂", "chapter": 3,
             "message": "他明明最怕水，却毫无铺垫地跳进河里捞刀",
             "evidence": "第3章：他纵身跳进河里。／第1章：他连船都不敢上。",
             "suggestion": "在第2章补一处他不得不亲水的理由，或改成让别人去捞"},
            {"severity": "note", "category": "能力资源", "chapter": 4,
             "message": "他身上只剩三文钱，却在第4章付了酒钱",
             "evidence": "第2章：三文钱；第4章：他要了一壶酒，付了账。",
             "suggestion": "要么交代钱的来处，要么把酒改成赊的"},
        ],
    },
    "propose_outline_updates": {
        "note": "两条偏差都该改大纲，不是漏写。",
        "updates": [
            {"kind": "event_moved", "event_id": "E02", "new_chapter": 6,
             "reason": "相遇实际写在第6章，比计划晚了三章，正文里没有补写第3章的痕迹",
             "evidence": "第6章摘要：少年与白零在雾中照面", "confidence": 0.72},
            {"kind": "storyline_status", "storyline_id": "L03", "new_status": "蛰伏",
             "reason": "世界线计划第30章才入场，现在标进行中会让对账条一直飘红",
             "evidence": "L03 入场章 30，当前第10章", "confidence": 0.9},
        ],
    },
    "propose_draft": {
        "note": "按骨架三拍写的整章草稿。",
        "text": "废窑里漏风。\n\n少年醒来时先摸腰侧，刀不在了。\n\n他沿着来路往回走，走到河边，老周蹲在棚屋门口抽烟。\n\n“你的刀。”老周把断刀递过来，“河里捞的。”\n\n少年接过来，刀柄上那个界字被水泡得发白。他想问哪段河，老周已经转过身去了。\n\n午后渡口来了宗门的人，他躲进船底。船板缝里垂下来一只鞋，鞋面上绣着他自己家的纹样。",
    },
    "propose_memory": {
        "note": "只记正文明确写到的。",
        "summary": {"text": "少年发现断刀失踪，老周从河里捞回还他，午后宗门来人查河，他躲进船底，看见一只绣着自家纹样的鞋。",
                    "key_events": ["断刀失而复得", "老周隐瞒捞刀地点", "躲进船底", "看见绣鞋"],
                    "emotional_tone": "紧绷里带着疑惑"},
        "facts": [
            {"subject": "少年", "predicate": "获得", "object": "断刀", "public_to_reader": True},
            {"subject": "老周", "predicate": "知道", "object": "断刀的来历", "public_to_reader": False},
        ],
        "new_clues": [{"title": "绣着自家纹样的鞋", "detail": "船板缝里垂下来的鞋，鞋面纹样与少年家的一致",
                       "scale": "medium", "timing": "mid_arc",
                       "planted_quote": "鞋面上绣着他自己家的纹样"}],
    },
    "propose_clues": {
        "note": "盘点出一条尚未登记的。",
        "clues": [{"title": "绣鞋纹样", "detail": "船底垂下的鞋绣着少年家的纹样", "scale": "medium",
                  "timing": "mid_arc", "importance": "高", "planted_chapter": 3,
                  "planted_quote": "鞋面上绣着他自己家的纹样", "target_payoff_chapter": 12}],
    },
    "propose_validation": {
        "note": "只报客观错误。",
        "issues": [{"severity": "warning", "category": "连续性",
                    "message": "第1章说他不会水，本章却泅过河",
                    "evidence": "本章：他泅过河道。", "suggestion": "改成绕桥，或补一次学水的交代"}],
    },
    "propose_deslop": {
        "note": "只挑三处最有力的动刀。",
        "grade": "中度",
        "suggestions": [
            {"gate": "P3措辞-A", "original": "仿佛整个世界都失去了颜色",
             "replacement": "街上的灯一盏盏灭下去", "reason": "禁用词加抽象概括，换成可拍的画面"},
            {"gate": "P1架构", "original": "他终于明白了这一切",
             "replacement": "他把刀放回桌上，没再说话", "reason": "结局三连的主题总结，改成动作收束"},
        ],
    },
    "propose_memo": {"note": "三条本章最容易踩的雷。",
                     "text": "1. 老周不肯说捞刀的那段河，本章别让他自己说漏。\n2. 上一章收在船底的绣鞋，开头要接住这个画面。\n3. F01 已逾期两章，本章至少推进一次。"},
    "propose_canon": {"docs": [{"title": "力量体系", "content": "# 力量体系\n\n| 境界 | 门槛 | 代价 |\n|---|---|---|\n| 引气 | 开脉 | 寿元 |",
                                "certainty": "tentative"}]},
    "propose_storylines": {"note": "一主两支。",
                           "storylines": [{"name": "复仇", "kind": "main", "is_through_line": True,
                                           "notes": "查清灭门真相"},
                                          {"name": "断刀来历", "kind": "mystery", "notes": "刀上的界字"}]},
    "propose_outline_events": {"note": "八个关键事件。",
                               "events": [{"chapter": 1, "objective_fact": "少年全家被杀，他躲在柴堆里活下来",
                                           "reader_knowledge": "少年全家被杀", "revealed": True,
                                           "storyline_ids": ["L01"]}]},
}


class Handler(BaseHTTPRequestHandler):
    dump_dir = "."
    lock = threading.Lock()
    counter = 0

    def log_message(self, fmt, *args):
        pass

    def _send_sse(self, chunks):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        for c in chunks:
            self.wfile.write(b"data: " + json.dumps(c, ensure_ascii=False).encode("utf-8") + b"\n\n")
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def do_POST(self):
        if not self.path.endswith("/chat/completions"):
            self.send_error(404, "unexpected path " + self.path)
            return
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw.decode("utf-8"))
        except Exception as exc:
            self.send_error(400, "bad json: %s" % exc)
            return

        with Handler.lock:
            Handler.counter += 1
            n = Handler.counter
        os.makedirs(Handler.dump_dir, exist_ok=True)
        with open(os.path.join(Handler.dump_dir, "req%02d.json" % n), "wb") as fh:
            fh.write(raw)

        messages = body.get("messages", [])
        has_tool_result = any(m.get("role") == "tool" for m in messages)

        if has_tool_result:
            self._send_sse([
                {"id": "c%d" % n, "object": "chat.completion.chunk", "model": body.get("model", "mock"),
                 "choices": [{"index": 0, "delta": {"role": "assistant", "content": "已按工具提交，等你裁决。"},
                              "finish_reason": None}]},
                {"id": "c%d" % n, "object": "chat.completion.chunk", "model": body.get("model", "mock"),
                 "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
            ])
            return

        tools = body.get("tools") or []
        names = []
        for t in tools:
            fn = (t.get("function") or {})
            names.append(fn.get("name") or t.get("name") or "")
        # 按能力的主工具优先：tools 数组的顺序来自 NovelTools.all()，
        # 比如骨架能力的集合里 propose_clues 排在 propose_skeleton 前面，取第一个就选错了。
        target = next((nm for nm in PRIMARY_TOOLS if nm in names), None)
        if target is None:
            target = next((nm for nm in names if nm.startswith("propose_")), None)
        if target is None:
            # 没有 propose_* 工具 = 宿主只要正文（分段写作）。回一段可直接拼接的正文，
            # 并故意带上模型爱加的开场白与围栏，好让宿主的剥离逻辑真的被测到。
            seg = body.get("_segment") or ""
            text = ("以下是这一段：\n```markdown\n"
                    "他沿着河堤往回走，脚底下的泥还是软的。\n\n"
                    "棚屋里的灯没灭。老周蹲在门口抽烟，见他过来，把烟头按灭了。\n\n"
                    "“你的刀。”老周把断刀递过来，“河里捞的。”\n```")
            self._send_sse([
                {"id": "c%d" % n, "object": "chat.completion.chunk", "model": body.get("model", "mock"),
                 "choices": [{"index": 0, "delta": {"role": "assistant", "content": text},
                              "finish_reason": None}]},
                {"id": "c%d" % n, "object": "chat.completion.chunk", "model": body.get("model", "mock"),
                 "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
            ])
            return
        args = CANNED.get(target)
        if args is None:
            self.send_error(500, "没有为 %s 准备样本参数" % target)
            return

        call = {"index": 0, "id": "call_%d" % n, "type": "function",
                "function": {"name": target, "arguments": json.dumps(args, ensure_ascii=False)}}
        self._send_sse([
            {"id": "c%d" % n, "object": "chat.completion.chunk", "model": body.get("model", "mock"),
             "choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [call]},
                          "finish_reason": None}]},
            {"id": "c%d" % n, "object": "chat.completion.chunk", "model": body.get("model", "mock"),
             "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]},
        ])

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    port = int(sys.argv[1])
    Handler.dump_dir = sys.argv[2]
    os.makedirs(Handler.dump_dir, exist_ok=True)
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    sys.stderr.write("[mock] listening on 127.0.0.1:%d, dump=%s\n" % (port, Handler.dump_dir))
    sys.stderr.flush()
    srv.serve_forever()


if __name__ == "__main__":
    main()
