#!/usr/bin/env python3
"""生成「编码占用清单」。

解决的问题
==========
键道6 的编码空间不是均匀的。有些码位被高频字钉死（`d` → 的），
有些码位是空的（`a`/`i`/`u`/`v`/`o` 这些韵母键在单字层几乎没人用），
还有些码位被「字根」当垃圾桶（`supplement` 表里 43 条一码字根）。

要改词库/加功能，先得知道哪些编码能碰、哪些碰了会撞车。
这份清单就是把这件事从「靠猜」变成「可查」。

输出两个文件
============
  dicts/cloudkeytao.occupied.dict.yaml   机器可读（Rime 词典格式，可被 bench 消费）
  docs/occupied-codes.md                 人可读（markdown 表格）

为什么不直接写 markdown
=======================
因为 bench / CI 需要机器可读的版本，而且 markdown 手改会漂。
两者都从同一份扫描结果生成，单一真相。

用法
====
  ./scripts/gen-occupied-doc.py            # 写两个文件
  ./scripts/gen-occupied-doc.py --check    # 只检查（CI 用，不写文件）
"""

from __future__ import annotations

import argparse
import sys
from collections import defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DIST = REPO_ROOT / "dist" / "rime"

# 单字的「一码」在这些表里；词组表不参与一码占用统计（它没有一码条目）
SINGLE_TABLES = ["cloudkeytao.single", "cloudkeytao.supplement"]
PHRASE_TABLES = ["cloudkeytao.phrase"]

# 韵母键：取自 schema 的 layout/topup/topup_with = "avuio;"（`;` 不是字母，不计）
# 注意 e 不在此列 —— e 是单码「是」，属高频字，动它会毁肌肉记忆。
VOWEL_KEYS = list("aiuvo")

# 权重刻度：上游 single 是 10–14，supplement 是 100–106，两者不可比较。
# 这里只做「相对排序」，不做跨表比较。
SCALE_NOTE = {
    "cloudkeytao.single": "10–14（高频字，刻度小）",
    "cloudkeytao.supplement": "100–106（字根，刻度大）",
}


def read_dict(path: Path) -> list[tuple[str, str, str]]:
    """读 Rime 词典的正文部分，返回 (text, code, weight)。

    表头是 `---` 包起来的 YAML，正文是 tab 分隔。没有 weight 列时返回空串。
    """
    rows: list[tuple[str, str, str]] = []
    in_body = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("..."):
            in_body = True
            continue
        if not in_body:
            continue
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        text, code = parts[0], parts[1]
        weight = parts[2] if len(parts) > 2 else ""
        rows.append((text, code, weight))
    return rows


def scan() -> tuple[dict[str, list[tuple[str, str, str]]], dict[str, int]]:
    """返回 (一码占用表, 各表条目数)。"""
    occupied: dict[str, list[tuple[str, str, str]]] = defaultdict(list)
    counts: dict[str, int] = {}

    for table in SINGLE_TABLES:
        path = DIST / f"{table}.dict.yaml"
        if not path.exists():
            raise SystemExit(
                f"找不到 {path.relative_to(REPO_ROOT)}；先跑 ./scripts/build.sh"
            )
        rows = read_dict(path)
        counts[f"{table}.dict.yaml"] = len(rows)
        for text, code, weight in rows:
            # 只收单字母码：这就是「一码占用」的定义
            if len(code) == 1:
                occupied[code].append((text, weight, table))

    for table in PHRASE_TABLES:
        path = DIST / f"{table}.dict.yaml"
        if path.exists():
            counts[f"{table}.dict.yaml"] = len(read_dict(path))

    return occupied, counts


def render_markdown(
    occupied: dict[str, list[tuple[str, str, str]]], counts: dict[str, int]
) -> str:
    lines: list[str] = []
    add = lines.append

    add("# 编码占用清单")
    add("")
    add("> 本文件由 `scripts/gen-occupied-doc.py` 生成，**不要手改**。")
    add("> 改词库后跑一次 `./scripts/gen-occupied-doc.py` 即可。")
    add("")
    add("## 为什么需要这份清单")
    add("")
    add("键道6 的编码空间分布很不均匀，直接影响「能不能动某个键」：")
    add("")
    add("- **高频字钉死的码位**：单码 `d` 永远是「的」，动它会毁掉肌肉记忆。")
    add("- **韵母键空档**：`a` `i` `u` `v` `o` 在单字层几乎没有真正的候选，")
    add("  只被字根表当垃圾桶用 —— 这就是预留的扩展空间。")
    add("- **字根回收**：`supplement` 表里的那些一码条目大多是构字部件")
    add("  （`氵` `丿` `丨`），日常根本打不出来，却是占位的主要来源。")
    add("")
    add("## 单字表规模")
    add("")
    add("| 表 | 条目数 | 权重刻度 |")
    add("|---|---:|---|")
    for name, n in sorted(counts.items()):
        stem = name.removesuffix(".dict.yaml")
        scale = SCALE_NOTE.get(stem, "—")
        add(f"| `{name}` | {n:,} | {scale} |")
    add("")
    add("> ⚠️ 两个单字表的权重刻度**不可比**（single 是 10–14，supplement 是 100–106）。")
    add("> 合并时必须归一，否则 supplement 的字根会全面压过高频字。")
    add("")

    used = sorted(occupied)
    add(f"## 一码占用总览（{len(used)} 个码位）")
    add("")
    add("| 码 | 候选数 | 候选（按权重降序） | 性质 |")
    add("|---|---:|---|---|")
    for key in sorted(occupied, key=lambda k: (-len(occupied[k]), k)):
        cands = sorted(occupied[key], key=lambda r: -_weight(r[1]))
        shown = " ".join(f"{text}" for text, _, _ in cands)
        if len(shown) > 40:
            shown = shown[:38] + "…"
        kind = _kind(key, cands)
        add(f"| `{key}` | {len(cands)} | {shown} | {kind} |")
    add("")

    free = [k for k in "abcdefghijklmnopqrstuvwxyz" if k not in occupied]
    add("## 完全空白的码位")
    add("")
    if free:
        add("这些键在单字层没有任何一码候选，是**最干净的扩展空间**：")
        add("")
        add("```")
        add(" ".join(free))
        add("```")
    else:
        add("无 —— 26 个字母全部有单码占用。")
    add("")

    add("## 韵母键空档（`a` `i` `u` `v` `o`）")
    add("")
    add("键道6 把这五个键留给韵母。它们在单字层的占用情况：")
    add("")
    add("| 键 | 单码候选 | 判断 |")
    add("|---|---|---|")
    for key in VOWEL_KEYS:
        cands = occupied.get(key, [])
        real = [t for t, _, _ in cands]
        add(f"| `{key}` | {' '.join(real) if real else '—'} | {_vowel_verdict(cands)} |")
    add("")
    add("**可证事实**：这五个码位在 `cloudkeytao.single`（高频字表）里**一条条目都没有**，")
    add("占用它们全部来自 `cloudkeytao.supplement`（字根表），权重 100–106。")
    add("这些条目大多是构字部件（`氵` `丿` `丨` `朩`），但也混着几个单字")
    add("（`那` `又` `上` `人` `得` `有` `一`）。")
    add("")
    add("**不可证的部分**：光看词表无法断定这些条目在运行时能否被打出来 ——")
    add("那取决于 algebra 推导与顶层绑定（参见 `keytao.schema.yaml` 的")
    add("`layout/algebra`）。要确认请用 `rime_deployer` 部署后实测敲 `a` / `i`。")
    add("")
    add("因此**任何征用决定都必须建立在实测之上**，不能仅凭这张表。")
    add("")
    add("> 本仓库的决策（Q9=C）是：反查用 `` ` `` 引导，**不征用** u/v/o 字根。")
    add("> 上面的空档留作将来扩展，当前不动。")
    add("")

    add("## 被字根占用的码位明细")
    add("")
    add("`cloudkeytao.supplement` 的一码条目全部在此，便于判断哪些可回收：")
    add("")
    add("| 码 | 字根 | 权重 |")
    add("|---|---|---:|")
    for key in sorted(occupied):
        for text, weight, table in occupied[key]:
            if table.endswith("supplement"):
                add(f"| `{key}` | {text} | {weight or '—'} |")
    add("")

    return "\n".join(lines) + "\n"


def _weight(w: str) -> float:
    try:
        return float(w)
    except (TypeError, ValueError):
        return 0.0


def _kind(key: str, cands: list[tuple[str, str, str]]) -> str:
    tables = {t for _, _, t in cands}
    if key in VOWEL_KEYS:
        return "韵母键/空档"
    if tables == {"cloudkeytao.supplement"}:
        return "仅字根"
    if "cloudkeytao.single" in tables:
        return "高频字"
    return "—"


def _vowel_verdict(cands: list[tuple[str, str, str]]) -> str:
    if not cands:
        return "完全空"
    # 判定依据是「来源表」而不是字符数：supplement 里也有单字（那/又/得/打），
    # 但它们是字根表里的低优先级条目，被 high-frequency 的 single 表覆盖时无感。
    # 真正不能动的是 single 表里的高频字。
    if any(t.endswith("cloudkeytao.single") for _, _, t in cands):
        return "含高频字"
    return "无高频字"


def render_dict(occupied: dict[str, list[tuple[str, str, str]]]) -> str:
    """输出 Rime 词典格式，供 bench 消费。

    设计成「一码占位表」：text 是 `$占位`，code 是那个字母。
    这不是给输入法用的，是给脚本读的结构化数据 —— 但借用 Rime 词典格式
    省掉一套自定义解析。
    """
    lines = [
        "# 编码占用清单（由 scripts/gen-occupied-doc.py 生成，勿手改）",
        "#",
        "# 这张表不参与输入，是给 bench / CI 读的结构化数据：",
        "#   text = 该码位上的候选（空格分隔），code = 码位本身。",
        "# 用 Rime 词典格式是为了复用现有解析，不是为了被 rime_deployer 编译。",
        "---",
        "name: cloudkeytao.occupied",
        "version: \"1.0\"",
        "sort: by_weight",
        "columns:",
        "  - text",
        "  - code",
        "  - weight",
        "...",
    ]
    for key in sorted(occupied):
        cands = sorted(occupied[key], key=lambda r: -_weight(r[1]))
        joined = " ".join(text for text, _, _ in cands)
        # 码位本身当 weight 用：一码候选数越多越「拥挤」，bench 用来避让
        lines.append(f"{joined}\t{key}\t{len(cands)}")
    return "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="只检查是否与现有文件一致，不写盘")
    args = ap.parse_args()

    if not DIST.is_dir():
        print(f"错误：{DIST.relative_to(REPO_ROOT)} 不存在，先跑 ./scripts/build.sh", file=sys.stderr)
        return 1

    occupied, counts = scan()
    md = render_markdown(occupied, counts)
    dct = render_dict(occupied)

    md_path = REPO_ROOT / "docs" / "occupied-codes.md"
    dct_path = REPO_ROOT / "dicts" / "cloudkeytao.occupied.dict.yaml"

    if args.check:
        stale = []
        for path, want in ((md_path, md), (dct_path, dct)):
            if not path.exists():
                stale.append(f"{path.relative_to(REPO_ROOT)} 不存在")
            elif path.read_text(encoding="utf-8") != want:
                stale.append(f"{path.relative_to(REPO_ROOT)} 已过期")
        if stale:
            for s in stale:
                print(f"✗ {s}", file=sys.stderr)
            print("跑 ./scripts/gen-occupied-doc.py 重新生成。", file=sys.stderr)
            return 1
        print("✓ 占用清单与词库一致")
        return 0

    md_path.parent.mkdir(parents=True, exist_ok=True)
    dct_path.parent.mkdir(parents=True, exist_ok=True)
    md_path.write_text(md, encoding="utf-8")
    dct_path.write_text(dct, encoding="utf-8")
    print(f"✓ {md_path.relative_to(REPO_ROOT)}  ({len(md.splitlines())} 行)")
    print(f"✓ {dct_path.relative_to(REPO_ROOT)}  ({len(occupied)} 个码位)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
