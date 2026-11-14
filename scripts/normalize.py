#!/usr/bin/env python3
"""把上游 KeyTao 的 rime 目录归一成「独立方案」产物。

决策依据（见 plan 文档 Q8 修订）：
  * 产物只交付 **一个** 方案：cloudkeytao。
  * 上游 schema 在构建期内联展开，产物里不出现 keytao.schema.yaml。
  * 词库内容仍来自上游 pin，但产物里的表名/文件名统一改成 cloudkeytao.*。

为什么不用 `__include` 而是内联：
  产物若保留 keytao.schema.yaml 作为 include 源，rime 会把它当成第二个方案扫进菜单，
  且产物里到处是 keytao 字样。内联后 dist/ 是自洽的、只有一个方案的用户目录。

为什么用文本级改写而不是 pyyaml round-trip：
  Rime 的 .dict.yaml / .schema.yaml 是人工排版的（大量注释、对齐、分节），
  pyyaml 一过就全毁，产物 diff 再也看不出改了什么。这里只做定点替换，
  每条替换规则都限定在**键位上下文**里，绝不裸匹配 `keytao` 这个字符串
  （否则 keytao.link 里那一堆 https://keytao.vercel.app 会被误伤）。
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# 上游里与「多方案」相关的文件，产物中一律不保留。
#   keytao-bj          : 并击方案
#   keytao-cx          : 供 bj 用的辅助表
#   keytao-dz          : 纯单字方案（用户明确不用）
#   keytao.css-single  : 可选外挂表，extended 里是注释状态，不启用
#   keytao.schema.yaml : 由 cloudkeytao.schema.yaml 取代（内联）
DROP_FILES = [
    "keytao.schema.yaml",  # 由 cloudkeytao.schema.yaml 取代（内联）
    "keytao-dz.schema.yaml",
    "keytao-dz.extended.dict.yaml",
    "keytao-bj.schema.yaml",
    "keytao-cx.schema.yaml",
    "keytao-cx.dict.yaml",
    "keytao.css-single.dict.yaml",
]


class BuildError(Exception):
    """归一化失败。由 main() 统一转成非零退出码。"""


def log(msg: str) -> None:
    print(f"[normalize] {msg}")


# ── 1. 内联 schema ──────────────────────────────────────────────────────────
def schema_block_bounds(lines: list[str], origin: Path) -> tuple[int, int]:
    """返回顶层 `schema:` 块的 [start, end) 行号。

    块从 `schema:` 行本身开始，到下一个顶层键（非空、非注释、不缩进）为止。
    """
    hits = [i for i, line in enumerate(lines) if line.rstrip() == "schema:"]
    if not hits:
        raise BuildError(f"{origin} 里找不到顶层 `schema:` 块（上游结构变了）")
    first = hits[0]
    rest = [
        i
        for i in range(first + 1, len(lines))
        if lines[i].strip() and not lines[i].startswith((" ", "\t", "#"))
    ]
    last = rest[0] if rest else len(lines)
    if last <= first + 1:
        raise BuildError("schema: 块为空")
    return first, last


def build_schema(out: Path, upstream_schema: Path, meta: Path) -> None:
    """把上游 keytao.schema.yaml 复制成 cloudkeytao.schema.yaml，只换 schema: 块。

    meta 文件只放键值对（注释不会进产物），这里统一缩进 2 空格写入 schema: 块；
    其余上游内容逐字保留。
    """
    src = upstream_schema.read_text(encoding="utf-8").splitlines(keepends=True)

    meta_lines = [
        "  " + line.rstrip()
        for line in meta.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    if not meta_lines:
        raise BuildError(f"{meta} 里没有可用的 schema 元信息（全是注释？）")

    first, last = schema_block_bounds(src, upstream_schema)
    head = "".join(src[:first]) + "schema:\n" + "\n".join(meta_lines) + "\n\n"
    (out / "cloudkeytao.schema.yaml").write_text(head + "".join(src[last:]), encoding="utf-8")
    log(f"内联 schema: {upstream_schema.name} → cloudkeytao.schema.yaml")


# ── 2. 词库改名归一 ─────────────────────────────────────────────────────────
NAME_RE = re.compile(r"^name:[ \t]*(\S+)[ \t]*$")


def collect_renames(out: Path) -> dict[str, tuple[str, str]]:
    """扫出所有待改名的词库表：old_name → (new_name, new_filename)。"""
    mapping: dict[str, tuple[str, str]] = {}
    for path in sorted(out.glob("*.dict.yaml")):
        for line in path.read_text(encoding="utf-8").splitlines():
            m = NAME_RE.match(line)
            if not m:
                continue
            old = m.group(1)
            if not old.startswith("keytao"):
                break
            new = "cloudkeytao" + old[len("keytao") :]
            new_file = "cloudkeytao" + path.name[len("keytao") :]
            mapping[old] = (new, new_file)
            break
    return mapping


def rename_files(out: Path, mapping: dict[str, tuple[str, str]]) -> None:
    for old_name, (_new_name, new_file) in sorted(mapping.items()):
        candidates = sorted(out.glob(f"{old_name}.dict.yaml"))
        if not candidates:
            raise BuildError(f"表 {old_name} 找不到对应的 .dict.yaml 文件")
        if len(candidates) > 1:
            raise BuildError(f"表 {old_name} 对应多个文件: {[c.name for c in candidates]}")
        src = candidates[0]
        dst = out / new_file
        if dst.exists():
            raise BuildError(f"改名目标已存在: {dst.name}")
        src.rename(dst)
        log(f"改名: {old_name} → {_new_name}（{src.name} → {new_file}）")


def make_repl(mapping: dict[str, tuple[str, str]], kind: str):
    def repl(m: re.Match[str]) -> str:
        token = m.group(1) if kind == "name" else m.group(2)
        if token in mapping:
            new = mapping[token][0]
            return f"name: {new}" if kind == "name" else f"{m.group(1)}{new}"
        return m.group(0)

    return repl


# 引用改写严格限定在键位上下文，绝不裸匹配 keytao 字样。
# 注意：schema 里的这些键都是缩进的（在 translator / reverse_lookup_filter 下），
# 所以必须允许行首空白。
REF_PATTERNS = [
    # name:  ...
    (re.compile(r"^name:[ \t]*(\S+)[ \t]*$", re.M), "name"),
    # import_tables 里的列表项：  - keytao.xxx
    (re.compile(r"^([ \t]*-[ \t]+)(\S+)[ \t]*$", re.M), "list"),
    # dictionary: / prism: 引用（允许缩进）
    (re.compile(r"^([ \t]*(?:dictionary|prism):[ \t]*)(\S+)[ \t]*$", re.M), "ref"),
]


def rewrite_refs(out: Path, mapping: dict[str, tuple[str, str]]) -> None:
    touched = 0
    for path in sorted(out.glob("*.yaml")):
        text = path.read_text(encoding="utf-8")
        original = text
        for pattern, kind in REF_PATTERNS:
            text = pattern.sub(make_repl(mapping, kind), text)
        if text != original:
            path.write_text(text, encoding="utf-8")
            touched += 1
    log(f"引用改写涉及 {touched} 个 yaml 文件")


def assert_no_leftovers(out: Path) -> None:
    """产物里不该再有裸的 keytao 表名引用。"""
    leftovers = []
    bare_ref = re.compile(r"^(?:name|dictionary|prism):[ \t]*keytao")
    list_ref = re.compile(r"^[ \t]*-[ \t]+keytao(?:\.|$)")
    for path in sorted(out.glob("*.yaml")):
        for i, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if bare_ref.match(line) or (list_ref.match(line) and "#" not in line):
                leftovers.append(f"{path.name}:{i}: {line.strip()}")
    if leftovers:
        raise BuildError("仍有未改名的 keytao 表引用:\n  " + "\n  ".join(leftovers))


def drop_unused(out: Path) -> None:
    for name in DROP_FILES:
        p = out / name
        if p.exists():
            p.unlink()
            log(f"移除多方案产物: {name}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--meta", type=Path, required=True)
    args = ap.parse_args()

    try:
        out: Path = args.out
        if not out.is_dir():
            raise BuildError(f"输出目录不存在: {out}")

        mapping = collect_renames(out)
        if not mapping:
            raise BuildError("没有找到任何 keytao.* 词库，改名步骤无从下手（上游结构变了？）")

        # 顺序很重要：先改名（此时 keytao.schema.yaml 还在，引用改写会覆盖它），
        # 再内联 schema，最后删掉多方案文件。
        rename_files(out, mapping)
        rewrite_refs(out, mapping)

        # 注意：内联的源必须是**产物副本**（已完成改名），
        # 若直接读上游原文件，会把上面的改名结果全盖掉。
        staged = out / "keytao.schema.yaml"
        if not staged.is_file():
            raise BuildError(
                "产物里没有 keytao.schema.yaml —— 请确认 KEYTAO_SRC/schema/desktop/ 已拷入，"
                "且 DROP_FILES 中 schema 的删除发生在本步之后"
            )
        build_schema(out, staged, args.meta)
        drop_unused(out)
        assert_no_leftovers(out)
    except BuildError as exc:
        print(f"[normalize] ERROR: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
