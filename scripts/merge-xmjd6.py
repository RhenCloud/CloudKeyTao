#!/usr/bin/env python3
"""把 xmjd6 的长尾词组并入 CloudKeyTao 的独立词库。

对应方案文档 §6（M2 的核心）。输入只读，输出一份可被 build.sh 直接
拷进产物的 .dict.yaml。

设计要点（每条都对应一个实测出来的坑，不是拍脑袋）：

1. 只取码长 ≥ 4 的词组（Q15′=A）
   3 码是键道「三简词」的地盘，用户已有 7431 条。xmjd6 的 3 码层有
   8382 条且含「不饱和/白菜丝/半瓶醋」这类明显低频词，插进来就是
   直接恶化痛点 (a)。≥4 码不占短码，纯扩覆盖。

2. 权重刻度必须显式归一（§6.2）
   实测 librime 语义：Vocabulary::SortHomophones 会对**同一个 code 的
   所有条目按 weight 降序全局排序**，import_tables 的顺序只在 weight
   完全相等时才决定先后。所以不同表的权重是**直接可比**的，
   三套刻度不归一就会出事：
     keytao.single  10–14
     keytao.phrase  100
     xmjd6          无
   真实存在的 bug：`到`(w=10) 与 `道："`(w=100) 同码 dz，
   词组会把单字压到后面。若不归一，并入的 79 万词条每一条都可能
   压在单字上面。

3. 排序写盘必须稳定（§6.3）
   按 (weight desc, code, text) 写盘，让重跑同样输入得到字节级一致的
   文件。否则 git diff 每次都是几十万行，等于没版本控制。

用法：
  merge-xmjd6.py --xmjd6-src DIR --out FILE [--report FILE]
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
import unicodedata
from collections import Counter
from pathlib import Path

# ── 常量：全部来自方案文档，改动需同步文档 ──────────────────────────────────

MIN_CODE_LEN = 4        # §6.1 Q15′=A：词组只取码长 ≥ 4
MAX_CODE_LEN = 6        # 键道编码上限（实测 keytao 各表最大码长均为 6）
DANZI_WEIGHT = 5        # §6.2 Q25=A：并入单字统一 5，低于所有 keytao 单字

# §6.2 目标刻度。xmjd6 词组没有词频，按「长尾」定位给一个低于简码层
# 的固定基线。keytao.phrase 的 100 会被 normalize 重算到 10–99。
PHRASE_WEIGHT_BASE = 6  # 略高于并入单字(5)，远低于 keytao 词组(10–99)

# 编码合法字符：键道小写字母分号
CODE_RE = re.compile(r"^[a-z;]+$")
# 纯汉字（含扩展 A 区，不含兼容区/emoji/拉丁/标点）
HAN_ONLY_RE = re.compile(r"^[\u3400-\u4dbf\u4e00-\u9fff]+$")


def log(msg: str) -> None:
    print(f"[merge] {msg}", file=sys.stderr)


def die(msg: str) -> None:
    print(f"[merge] ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


# ── 解析 ──────────────────────────────────────────────────────────────────────


def iter_entries(path: Path):
    """逐行产出 (text, code, weight|None)，跳过 YAML 头与注释。

    rime 词库是「YAML 头 + ... + TSV 正文」的混合格式。正文里 # 开头的
    行是注释；字段用 Tab 分隔。
    """
    if not path.is_file():
        die(f"找不到词库 {path}")
    in_body = False
    with path.open(encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if not in_body:
                if line == "...":
                    in_body = True
                continue
            if not line or line.startswith("#"):
                continue
            fields = line.split("\t")
            if len(fields) < 2:
                continue
            text, code = fields[0], fields[1]
            weight = None
            if len(fields) >= 3:
                try:
                    weight = float(fields[2])
                except ValueError:
                    weight = None
            yield text, code, weight


def load_entries(path: Path):
    return list(iter_entries(path))


# ── 过滤 ──────────────────────────────────────────────────────────────────────


def is_clean(text: str) -> bool:
    """只收纯汉字词条。

    实测 xmjd6 里有 0.07% 的噪音：emoji、@163.com 这类邮箱、
    「辶乏chú(xfjw)」这类带编码注释的条目、以及整句短语。
    它们数量不多，但一旦进词库就是候选里的垃圾。
    """
    if not text:
        return False
    if not HAN_ONLY_RE.match(text):
        return False
    # 排除 Unicode 兼容/私用区的怪字符（纯汉字正则已挡掉大部分，
    # 这里再挡一次：只允许 Lo（Letter, other）类别
    return all(unicodedata.category(ch) == "Lo" for ch in text)


def is_valid_code(code: str) -> bool:
    return bool(CODE_RE.match(code)) and len(code) <= MAX_CODE_LEN


# ── 主流程 ────────────────────────────────────────────────────────────────────


def main() -> int:
    ap = argparse.ArgumentParser(description="合并 xmjd6 长尾词库")
    ap.add_argument("--xmjd6-src", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--report", type=Path, default=None)
    ap.add_argument(
        "--existing",
        type=Path,
        action="append",
        default=[],
        help="已有的 keytao/cloudkeytao 词库；其中的 (text,code) 一律不重复引入（§6.4）",
    )
    args = ap.parse_args()

    src: Path = args.xmjd6_src
    if not src.is_dir():
        die(f"xmjd6-src 不是目录: {src}")

    # ── 1. 读入已有词库，后面一律不重复引入（§6.4）───────────────────
    # 「同 code 同 text」保留 keytao 版本（含其 weight 与位置）；
    # 「同 code 不同 text」全部保留 —— 那才叫扩覆盖。
    stats: Counter[str] = Counter()
    source_files = {
        name: src / f"xmjd6.{name}.dict.yaml"
        for name in ("cizu", "fjcy", "danzi")
    }
    source_hashes = {name: sha256_file(path) for name, path in source_files.items()}
    existing: set[tuple[str, str]] = set()
    for path in args.existing:
        n = 0
        for text, code, _w in iter_entries(path):
            existing.add((text, code))
            n += 1
        log(f"已有词库 {path.name}: {n} 条")
    stats["existing"] = len(existing)

    # ── 2. 收集词组：cizu + fjcy，只取 ≥ MIN_CODE_LEN ──────────────────────
    seen: set[tuple[str, str]] = set()
    phrases: list[tuple[str, str]] = []

    for name in ("cizu", "fjcy"):
        path = source_files[name]
        n_total = n_taken = 0
        for text, code, _w in iter_entries(path):
            n_total += 1
            if not is_valid_code(code):
                stats["skip_bad_code"] += 1
                continue
            if len(code) < MIN_CODE_LEN:
                stats["skip_short_code"] += 1
                continue
            if not is_clean(text):
                stats["skip_noise"] += 1
                continue
            key = (text, code)
            # 同 text 同 code：保留一次（cizu 与 fjcy 有重叠）
            if key in seen:
                stats["skip_dup_inner"] += 1
                continue
            # §6.4：与已有词库重复的保留 keytao 版本
            if key in existing:
                stats["skip_dup_existing"] += 1
                continue
            seen.add(key)
            phrases.append((text, code))
            n_taken += 1
        stats[f"taken_{name}"] = n_taken
        stats[f"total_{name}"] = n_total
        log(f"xmjd6.{name}: 读入 {n_total}，取用 {n_taken}")

    # ── 3. 收集单字：danzi 全量（Q21=A）───────────────────────────────────
    # 但短码（≤ 3）不取：§6.4 的硬约束是「简码层条目数不增加」。
    # xmjd6.danzi 里有 2184 条 1-3 码单字，它们会直接插到键道三简字前面。
    danzi: list[tuple[str, str]] = []
    danzi_seen: set[tuple[str, str]] = set()
    for text, code, _w in iter_entries(source_files["danzi"]):
        stats["danzi_total"] += 1
        if not is_valid_code(code) or not is_clean(text):
            stats["danzi_skip"] += 1
            continue
        if len(text) != 1:
            stats["danzi_skip_multi"] += 1
            continue
        if len(code) < MIN_CODE_LEN:
            stats["danzi_skip_short"] += 1
            continue
        key = (text, code)
        if key in danzi_seen:
            stats["danzi_skip_dup"] += 1
            continue
        if key in existing:
            stats["danzi_skip_existing"] += 1
            continue
        danzi_seen.add(key)
        danzi.append((text, code))
    stats["danzi_taken"] = len(danzi)
    log(f"xmjd6.danzi: 读入 {stats['danzi_total']}，取用 {len(danzi)}")

    if not phrases:
        die("没有取到任何词组，检查 xmjd6-src 是否指向正确目录")
    if not danzi:
        log("警告：没有取到单字，继续")

    # ── 4. 分配权重（§6.2 归一）─────────────────────────────────────────────
    # 词组用固定基线；不按词长/出现顺序做花样加权，因为 xmjd6 没有词频，
    # 任何「聪明」的加权都是编出来的。固定 = 可解释 = 重跑一致。
    rows: list[tuple[str, str, float]] = []
    for text, code in phrases:
        rows.append((text, code, float(PHRASE_WEIGHT_BASE)))
    for text, code in danzi:
        rows.append((text, code, float(DANZI_WEIGHT)))

    # ── 5. 稳定排序并写盘（§6.3）───────────────────────────────────────────
    # 排序键：weight desc → code → text。让输出对输入顺序不敏感。
    rows.sort(key=lambda r: (-r[2], r[1], r[0]))

    out: Path = args.out
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", encoding="utf-8") as fh:
        fh.write(
            "# Rime dictionary\n"
            "# encoding: utf-8\n"
            "#\n"
            "# 由 scripts/merge-xmjd6.py 生成，请勿手改。\n"
            f"# 来源：xmjd6-rere 的 cizu/fjcy（仅码长 >= {MIN_CODE_LEN}）与 danzi（全量）\n"
            "# 权重刻度见方案文档 §6.2；随机重跑应得到字节级一致的文件。\n"
            "# 输入文件 SHA-256：\n"
            + "".join(f"#   xmjd6.{name}: {digest}\n" for name, digest in source_hashes.items())
            + "---\n"
            "name: cloudkeytao.xmjd6\n"
            'version: "1.0"\n'
            "sort: by_weight\n"
            "columns:\n"
            "  - text\n"
            "  - code\n"
            "  - weight\n"
            "...\n"
        )
        for text, code, weight in rows:
            # 权重用整数写盘（全部是整数值），避免 5.0 这种噪音
            fh.write(f"{text}\t{code}\t{int(weight) if weight == int(weight) else weight}\n")

    log(f"写出 {out}：{len(rows)} 条")

    # ── 6. 报告 ────────────────────────────────────────────────────────────
    if args.report:
        per_code: Counter[str] = Counter(r[1] for r in rows)
        total = len(rows)
        avg = total / len(per_code) if per_code else 0
        mx_code, mx_n = per_code.most_common(1)[0] if per_code else ("-", 0)
        by_len: Counter[int] = Counter(len(r[1]) for r in rows)
        args.report.write_text(
            "# xmjd6 合并统计\n\n"
            "| 项目 | 数值 |\n|---|---|\n"
            f"| 输出条目 | {total} |\n"
            f"| 唯一码数 | {len(per_code)} |\n"
            + "".join(f"| xmjd6.{name} SHA-256 | `{digest}` |\n" for name, digest in source_hashes.items())
            + f"| 平均候选/码 | {avg:.3f} |\n"
            f"| 最大候选 | {mx_n}（码 `{mx_code}`）|\n"
            f"| 码长分布 | "
            + "、".join(f"{k}码 {by_len[k]}" for k in sorted(by_len))
            + " |\n"
            f"| 丢弃（码长<{MIN_CODE_LEN} 或 >{MAX_CODE_LEN}） | {stats['skip_short_code']} |\n"
            f"| 丢弃（噪音） | {stats['skip_noise']} |\n"
            f"| 丢弃（xmjd6 内部重复） | {stats['skip_dup_inner']} |\n"
            f"| 丢弃（与已有词库重复） | {stats['skip_dup_existing']} |\n"
            f"| 单字：丢弃短码(<=3) | {stats['danzi_skip_short']} |\n"
            f"| 单字：丢弃重复 | {stats['danzi_skip_existing']} |\n",
            encoding="utf-8",
        )
        log(f"报告写出 {args.report}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
