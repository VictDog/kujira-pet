#!/usr/bin/env python3
"""按动画文件名重建角色包的 catalog.json。

包里的动作是「按名字约定分类」的，加一段剪辑不用手改 JSON：

    待机*       → idle（待机循环）
    点击*       → clicks（点它的反应），同时进「反应」分类
    睡*         → sleep 三段
    转身*/东张西望 → turn（转身）
    拖*         → drag（被拎起来）
    走*/螃蟹*   → moves（走位）
    其它        → 「随机」分类

已有的 weights / physics / 碎碎念文本会被保留（只更新动作列表），
所以调过的手感不会被脚本冲掉。

用法: rebuild-catalog.py <包目录>
"""
import json
import os
import sys
from pathlib import Path

pack = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
anim = pack / "animations"
if not anim.is_dir():
    print(f"! 没有动画目录: {anim}")
    sys.exit(1)

names = sorted(p.stem for p in anim.iterdir() if p.suffix.lower() == ".mov")
if not names:
    print("! 包里没有任何 .mov")
    sys.exit(1)


def classify(n):
    if n.startswith("待机"):
        return "idle"
    if n.startswith("点击"):
        return "click"
    if n.startswith("睡"):
        return "sleep"
    if n.startswith("转身") or n.startswith("东张西望"):
        return "turn"
    if n.startswith("拖"):
        return "drag"
    if n.startswith("走") or n.startswith("螃蟹"):
        return "move"
    return "other"


buckets = {}
for n in names:
    buckets.setdefault(classify(n), []).append(n)

# 睡觉三段按关键词分开：入睡过渡 / 睡姿循环 / 醒来过渡。
# 全塞同一段也能跑，但会变成「躺下→躺下→躺下」，像卡住了。
sleep_all = buckets.get("sleep", [])
def pick_sleep(keys):
    return [n for n in sleep_all if any(k in n for k in keys)]
sleep_start = pick_sleep(["躺下", "入睡", "开始"])
sleep_loop = pick_sleep(["趴卧", "循环", "睡姿"])
sleep_end = pick_sleep(["起身", "醒"])
if sleep_all and not (sleep_start or sleep_loop or sleep_end):
    sleep_start, sleep_loop, sleep_end = sleep_all[:1], sleep_all, sleep_all[:1]

# 没有待机片段就把第一段当待机，否则宠物会一启动就空着
idle = buckets.get("idle") or names[:1]

base = {
    "idle": idle,
    "turn": buckets.get("turn", []),
    "drag": buckets.get("drag", []) or idle,
    "clicks": buckets.get("click", []),
    "moves": {"default": {"minDist": 60, "maxDist": 240, "leadSec": 2, "tailSec": 2},
              "actions": [{"name": n} for n in buckets.get("move", [])]},
    "categories": [],
    "sleep": {"start": sleep_start or idle,
              "loop": sleep_loop or idle,
              "end": sleep_end or idle},
    "whisper": [],
    "weights": {"idle": 60, "turn": 5 if buckets.get("turn") else 0,
                "move": 5 if buckets.get("move") else 0},
    # 与上游 dsh-pet 的物理参数一致，抛掷/落地手感和原版对齐
    "physics": {"gravity": 1400, "restitution": 0.78, "groundFriction": 2.5, "throwPower": 1.0},
    "refWidth": 462,
    "sleepStartTexts": ["困了……", "先眯一下。"],
    "sleepEndTexts": ["醒了！", "睡饱了。"],
    "sleepRefuseTexts": ["睡着了，别戳我。", "呼……呼……"],
}

if buckets.get("click"):
    base["categories"].append({"id": "反应", "weight": 30, "actions": buckets["click"]})
if buckets.get("other"):
    base["categories"].append({"id": "随机", "weight": 20, "actions": buckets["other"]})

old_path = pack / "catalog.json"
if old_path.exists():
    try:
        old = json.loads(old_path.read_text())
        for k in ("weights", "physics", "refWidth",
                  "sleepStartTexts", "sleepEndTexts", "sleepRefuseTexts", "whisper"):
            if k in old:
                base[k] = old[k]
        # 保留用户手工调过的走位参数
        if isinstance(old.get("moves"), dict) and isinstance(old["moves"].get("default"), dict):
            base["moves"]["default"].update(old["moves"]["default"])
    except Exception as e:
        print(f"  已有 catalog 读不动（{e}），用默认值重建")

old_path.write_text(json.dumps(base, ensure_ascii=False, indent=1) + "\n")
print(f"==> {pack.name}: 共 {len(names)} 段  "
      f"待机{len(base['idle'])} 点击{len(base['clicks'])} 睡{len(buckets.get('sleep', []))} "
      f"走位{len(base['moves']['actions'])}")
