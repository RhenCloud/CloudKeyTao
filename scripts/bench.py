#!/usr/bin/env python3
"""输入质量基准（bench）。

要解决的问题
============
「手感变好了」这种话不能作为验收标准。要能对比两个版本，
必须有一组可复现的数字。

用 4 个指标（决策 Q16=B）：

  first_hit    首选命中率 —— 想要的字排在第一位（最好是唯一）的比例
  avg_rank     平均候选位次 —— 1 是最好，越大越难找
  avg_len      平均码长 —— 每个字/词打几个键
  empty_rate   空码率 —— 语料里的字在词库里根本查不到的比例

关键建模：sort: original ≠ 全局按权重排
========================================
`cloudkeytao.extended` 的表头是 `sort: original`，意味着候选顺序由
**import_tables 的导入顺序**决定：先出现的表整体排在前面，表内再按各自
的 `sort:` 排。所以 `single`（单字，第 1 张表）永远压过 `phrase`。

这一点必须建模，否则 bench 会算出一个现实中不存在的顺序。
本脚本用 (表序号, 表内原始行号) 二元组做排序键。

>> 为什么表内权重也不参与排序（实测结论）
>> extended 是 sort: original，这个设置会覆盖所有导入表的 sort: by_weight；
>> 权重在整个产物里**完全不参与候选排序**。用 librime 实测验证：
>> 同一码下把一条词组权重改为 99999、另一条为 1，候选顺序仍然是
>> 文件里先写的在前 —— 权重被无视。
>> 把这个表头改成 sort: by_weight 后，权重立刻接管排序，
>> 「到」(w=10) 被「道：“」(w=100) 压到第 3 位。
>> 两者只能取一：要么权重生效但需全局归一，要么权重无效但顺序稳定。
>> 当前选的是后者（见 cloudkeytao.extended.dict.yaml 的 sort: original）。

编码从哪来
==========
不做反向编码推导（那需要复刻整套 algebra，且容易与运行时不一致）。
直接读词库里的 `code` 列 —— 那就是 rime 编译进 .bin 的编码。

局限（诚实写出来）
==================
* **first_hit_rate 与 avg_rank 在静态模型下会饱和**：词表里几乎每个字都有
  一个唯一的全码，所以只要允许选码，指标就恒为 100% / 1.0。它们只在
  M2 合并词库**引入了同码竞争**以后才有区分力。
  当前真正有区分力的是 `avg_len`（简码利用率）与 `empty_rate`（覆盖度）。
* 不含顶功（topup）推导 —— 那是 `lua_processor@topup_processor` 运行时
  算的，静态读词表看不到。真实码长会**短于**这里的 avg_len。
* 不含用户自定义短语与上屏历史学习。
* 一个词若有多条同码条目，按词库顺序取最佳。
* 语料是占位文本（Q27），绝对值只在本仓库内可比，不具普适意义。

选码模型
========
对每个字，取它**位次最优、其次码长最短**的编码。理由是：
用户碰到 `那` 会敲 `ns`（那里它排第 1），而不是 supplement 里的 `a`
（那里它排第 7，前面压着 6 个字根）。所以模型等价于「一个熟练用户的选码」,
而不是「机器穷举最优」—— 后者会把 avg_len 算得过于乐观。

用法
====
  ./scripts/bench.py                    跑基准并打印
  ./scripts/bench.py --write-baseline   写入 bench/baseline.json
  ./scripts/bench.py --check            与基线对比，变差则退出 1（CI 用）
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DIST = REPO_ROOT / "dist" / "rime"
CORPUS = REPO_ROOT / "bench" / "corpus.txt"
BASELINE = REPO_ROOT / "bench" / "baseline.json"

CJK = re.compile(r"[\u4e00-\u9fff]")

# 参与候选排序的表，顺序必须与 extended 的 import_tables 一致
TABLE_ORDER = [
    "cloudkeytao.single",
    "cloudkeytao.phrase",
    "cloudkeytao.symbol",
    "cloudkeytao.supplement",
    "cloudkeytao.link",
    "cloudkeytao.english",
    "cloudkeytao.css",
    "cloudkeytao.user",
    "cloudkeytao.custom.user",
    # M2 起：xmjd6 长尾词组，在 extended 的 import_tables 里排最后。
    # 顺序必须与 cloudkeytao.extended.dict.yaml 里的一致，
    # 因为 sort: original 下候选顺序完全由这个顺序决定。
    "cloudkeytao.xmjd6",
]


def read_dict(path: Path) -> list[tuple[str, str, str]]:
    rows: list[tuple[str, str, str]] = []
    in_body = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("..."):
            in_body = True
            continue
        if not in_body or not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        weight = parts[2] if len(parts) > 2 else ""
        rows.append((parts[0], parts[1], weight))
    return rows


def load_index() -> dict[str, list[tuple[str, str]]]:
    """code -> [(text, table)]，已按真实候选顺序排好。

    排序键：表在 import_tables 里的位置 → 表内原始顺序。

    不把 weight 放进排序键：extended 的 sort: original 让权重整体失效，
    实测确认（同码下 w=1 与 w=99999 按文件顺序排，与权重无关）。
    按权重排序会算出**现实中不存在**的候选顺序。
    """
    raw: dict[str, list[tuple[int, int, str, str]]] = defaultdict(list)
    for table_pos, table in enumerate(TABLE_ORDER):
        path = DIST / f"{table}.dict.yaml"
        if not path.exists():
            continue
        for line_no, (text, code, _weight) in enumerate(read_dict(path)):
            raw[code].append((table_pos, line_no, text, table))

    index: dict[str, list[tuple[str, str]]] = {}
    for code, entries in raw.items():
        entries.sort(key=lambda e: (e[0], e[1]))
        index[code] = [(e[2], e[3]) for e in entries]
    return index


def build_lookup(index: dict[str, list[tuple[str, str]]]) -> dict[str, str]:
    """text -> 它实际最优的编码。

    同一个字往往有多个编码：单字表里有全码（`neavai`）与简码（`ns`），
    supplement 表里还有一个 1 码（`a`）。

    不能简单取「最短」—— 那样会给「那」选 supplement 的 `a`，
    而 `a` 上它排第 7（前面压着 6 个字根）。用户实际敲的是 `ns`，那里它第 1。

    所以排序键是 (候选位次升序, 码长升序)：先要「一选就有」，再要「省力」。
    """
    best: dict[str, tuple[int, int, str]] = {}
    for code, entries in index.items():
        for rank, (text, _table) in enumerate(entries, 1):
            cur = best.get(text)
            key = (rank, len(code))
            if cur is None or key < (cur[0], cur[1]):
                best[text] = (rank, len(code), code)
    return {text: v[2] for text, v in best.items()}


def upstream_rev() -> str:
    """从 flake.lock 读 KeyTao 的钉定 commit（基线可追溯到具体上游）。"""
    lock = REPO_ROOT / "flake.lock"
    try:
        data = json.loads(lock.read_text(encoding="utf-8"))
        return data["nodes"]["KeyTao"]["locked"]["rev"]
    except (OSError, KeyError, json.JSONDecodeError, TypeError):
        return "unknown"


def run() -> dict:
    if not DIST.is_dir():
        raise SystemExit("dist/rime 不存在，先跑 ./scripts/build.sh")
    if not CORPUS.exists():
        raise SystemExit(f"语料不存在: {CORPUS.relative_to(REPO_ROOT)}")

    index = load_index()
    lookup = build_lookup(index)

    corpus = CORPUS.read_text(encoding="utf-8")
    chars = CJK.findall(corpus)
    if not chars:
        raise SystemExit("语料里没有汉字，检查 bench/corpus.txt 编码")

    # 逐字统计。词组命中需要分词，本版只做单字（占位语料无分词标注）。
    ranks: list[int] = []
    lens: list[int] = []
    first_hit = 0
    empty = 0

    for ch in chars:
        code = lookup.get(ch)
        if code is None:
            empty += 1
            continue
        lens.append(len(code))
        candidates = index.get(code, [])
        # 该字在此码位上的最佳位次（1 起）
        rank = next(
            (i for i, (text, _t) in enumerate(candidates, 1) if text == ch),
            0,
        )
        if rank == 0:
            # lookup 给的是最短码，但该码位上不应缺席；保守计入空码
            empty += 1
            continue
        ranks.append(rank)
        if rank == 1:
            first_hit += 1

    total = len(chars)
    covered = total - empty
    metrics = {
        "corpus_chars": total,
        "covered_chars": covered,
        "empty_rate": round(empty / total, 4) if total else 0.0,
        "first_hit_rate": round(first_hit / covered, 4) if covered else 0.0,
        "avg_rank": round(sum(ranks) / len(ranks), 3) if ranks else 0.0,
        "avg_len": round(sum(lens) / len(lens), 3) if lens else 0.0,
    }
    return {
        "_note": "由 scripts/bench.py 生成。语料为占位文本（Q27），绝对值仅本仓库内可比。",
        "corpus": "bench/corpus.txt",
        "upstream_keytao_rev": upstream_rev(),
        "tables": [t for t in TABLE_ORDER if (DIST / f"{t}.dict.yaml").exists()],
        "metrics": metrics,
    }


def compare(new: dict, old: dict) -> list[str]:
    """返回变差的项目说明。阈值：变化超过 0.5% 才算显著。"""
    problems: list[str] = []
    nm, om = new["metrics"], old["metrics"]
    higher_is_better = {"first_hit_rate": True, "covered_chars": True}
    lower_is_better = {"avg_rank": True, "avg_len": True, "empty_rate": True}

    for key in (*higher_is_better, *lower_is_better):
        if key not in om or key not in nm:
            continue
        n, o = nm[key], om[key]
        if o == 0:
            continue
        delta = (n - o) / abs(o)
        if abs(delta) < 0.005:
            continue
        worse = delta < 0 if key in higher_is_better else delta > 0
        if worse:
            problems.append(f"{key}: {o} → {n} ({delta:+.1%})")
    return problems


def load_baseline() -> dict | None:
    """读基线；文件缺失或损坏都返回 None（不旭）。"""
    if not BASELINE.exists():
        return None
    try:
        return json.loads(BASELINE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"⚠ 基线无法解析（{exc}），当作无基线处理", file=sys.stderr)
        return None


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--write-baseline", action="store_true", help="写入 bench/baseline.json")
    ap.add_argument("--check", action="store_true", help="与基线对比，变差则退出 1")
    args = ap.parse_args()

    result = run()
    m = result["metrics"]

    print(f"语料汉字      {m['corpus_chars']}")
    print(f"可打出        {m['covered_chars']}  ({m['empty_rate']:.2%} 空码)")
    print(f"首选命中率    {m['first_hit_rate']:.2%}")
    print(f"平均候选位次  {m['avg_rank']}")
    print(f"平均码长      {m['avg_len']}")

    if args.write_baseline:
        BASELINE.parent.mkdir(parents=True, exist_ok=True)
        BASELINE.write_text(
            json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        print(f"\n✓ 写入 {BASELINE.relative_to(REPO_ROOT)}")
        return 0

    if args.check:
        old = load_baseline()
        if old is None:
            print(f"\n✗ 基线不可用: {BASELINE.relative_to(REPO_ROOT)}", file=sys.stderr)
            return 1
        problems = compare(result, old)
        if problems:
            print("\n✗ 指标变差：", file=sys.stderr)
            for p in problems:
                print(f"  {p}", file=sys.stderr)
            return 1
        print("\n✓ 无指标变差")
        return 0

    old = load_baseline()
    if old is not None:
        problems = compare(result, old)
        if problems:
            print("\n⚠ 相对基线变差：")
            for p in problems:
                print(f"  {p}")
        else:
            print("\n✓ 相对基线无变差")
    return 0


if __name__ == "__main__":
    sys.exit(main())
