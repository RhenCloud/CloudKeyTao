#!/usr/bin/env bash
# CloudKeyTao 构建脚本 —— 产物的唯一入口。
#
# 输入：
#   KEYTAO_SRC  上游 KeyTao 仓库根目录（必须含 rime/ 与 schema/desktop/）
#   XMJD6_SRC   上游 xmjd6-rere 仓库根目录（M2 起用于词库加工，M1 可为空）
#   OUT         输出目录，默认 dist/rime
#
# 输出：$OUT —— 一份可直接部署的 rime 用户目录，**只含一个方案 cloudkeytao**。
#
# 设计约束（见 README「与上游的关系」）：
#   * 上游文件一律只读，本脚本只在输出目录上做变换
#   * 任何文本变换必须带断言，锚点缺失就 fail，不静默降级
#   * 产物是独立方案：不出现 keytao.schema.yaml、不出现 keytao.* 表名
set -euo pipefail

# REPO_ROOT：默认从脚本位置推导；被 nix 以单文件形式引入时（${./scripts/build.sh}）
# 推导会出错，因此支持用 CLOUDKEYTAO_ROOT 显式指定。
REPO_ROOT=${CLOUDKEYTAO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
KEYTAO_SRC=${KEYTAO_SRC:-}
XMJD6_SRC=${XMJD6_SRC:-}

# 参数式输出目录（flake 的 packages 用 --out，其余场景用 env OUT）
while [ $# -gt 0 ]; do
    case "$1" in
        --out)   OUT=$2; shift 2 ;;
        --out=*) OUT=${1#--out=}; shift ;;
        -h|--help)
            sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) printf '未知参数: %s\n' "$1" >&2; exit 2 ;;
    esac
done
OUT=${OUT:-$REPO_ROOT/dist/rime}

log()  { printf '[build] %s\n' "$*"; }
die()  { printf '[build] ERROR: %s\n' "$*" >&2; exit 1; }

# ── 0. 前置检查 ──────────────────────────────────────────────────────────────
[ -n "$KEYTAO_SRC" ]                || die "KEYTAO_SRC 未设置（nix develop 会自动导出；手动构建见 README）"
[ -d "$KEYTAO_SRC/rime" ]           || die "KEYTAO_SRC=$KEYTAO_SRC 下找不到 rime/"
[ -d "$KEYTAO_SRC/schema/desktop" ] || die "KEYTAO_SRC=$KEYTAO_SRC 下找不到 schema/desktop/"
[ -f "$REPO_ROOT/overlay/rime.lua" ]              || die "缺少 overlay/rime.lua"
[ -f "$REPO_ROOT/overlay/schema-meta.yaml" ]      || die "缺少 overlay/schema-meta.yaml"
[ -f "$REPO_ROOT/scripts/normalize.py" ]          || die "缺少 scripts/normalize.py"

PYTHON=${PYTHON:-python3}
command -v "$PYTHON" >/dev/null || die "找不到 $PYTHON（nix develop 会提供）"

log "KEYTAO_SRC = $KEYTAO_SRC"
if [ -n "$XMJD6_SRC" ]; then log "XMJD6_SRC  = $XMJD6_SRC"; else log "XMJD6_SRC  = (未设置，M1 不加工词库)"; fi
log "OUT        = $OUT"

# ── 1. 清空输出 ──────────────────────────────────────────────────────────────
# 注意：若 OUT 曾经是 nix build 的目标，里面会是只读 store 文件，
# 必须先加回写权限才能删。
if [ -e "$OUT" ]; then
    chmod -R u+w "$OUT" 2>/dev/null || true
    rm -rf "$OUT"
fi
mkdir -p "$OUT/lua"

# ── 2. 上游核心文件（与上游 default.nix 的产物定义一致）─────────────────────
# 2a. rime/ 全部内容：词库、opencc、symbols、上游 lua、上游 rime.lua
cp -r "$KEYTAO_SRC/rime/." "$OUT"/
# 2b. 桌面平台 schema（keytao.schema.yaml 在这里进入产物，稍后由 normalize.py 内联）
cp "$KEYTAO_SRC"/schema/desktop/*.yaml "$OUT"/

# 2c. 上游文件在 nix store 里是 444（只读），cp -r 会把只读权限带进产物，
#     导致后续覆盖同名文件时 permission denied。统一加回写权限。
#     （后面从 overlay/、dicts/ 拷入的文件也可能只读，所以 normalize 前再 chmod 一次）
chmod -R u+w "$OUT"

# ── 3. rime.lua 分层：上游原样 → lua/_upstream.lua，入口由我们接管 ──────────
# 这样永远不需要编辑上游的 rime.lua（旧方案用 sed -i 改 nix store 里的文件）
cp "$KEYTAO_SRC/rime/rime.lua" "$OUT/lua/_upstream.lua"
cp "$REPO_ROOT/overlay/rime.lua" "$OUT/rime.lua"

# ── 4. Lua 模块：上游在前，我们的覆盖在后 ───────────────────────────────────
cp "$REPO_ROOT"/lua/*.lua "$OUT/lua/"
shopt -s nullglob
overlay_lua=("$REPO_ROOT"/overlay/lua/*.lua)
shopt -u nullglob
if [ ${#overlay_lua[@]} -gt 0 ]; then
    cp "${overlay_lua[@]}" "$OUT/lua/"
    log "已应用 overlay/lua 覆盖: $(cd "$REPO_ROOT/overlay/lua" && printf '%s ' *.lua)"
fi

# ── 5. 配置 patch（cloudkeytao.custom.yaml / default.custom.yaml）─────────────
cp "$REPO_ROOT"/overlay/*.custom.yaml "$OUT"/

# ── 6. 词库生成物与手写词库 ─────────────────────────────────────────────────
# 6a. 手写／回流词库（仓库内权威副本）
cp "$REPO_ROOT"/dicts/*.dict.yaml "$OUT"/

# 6b. 生成词库（M2 起存在）
GENERATED_TABLES=()
shopt -s nullglob
gen_dicts=("$REPO_ROOT"/dicts/gen/*.dict.yaml)
shopt -u nullglob
if [ ${#gen_dicts[@]} -gt 0 ]; then
    cp "${gen_dicts[@]}" "$OUT"/
    for f in "${gen_dicts[@]}"; do
        # 从 name: 行取表名，避免用文件名猜
        GENERATED_TABLES+=("$(awk '/^name:[[:space:]]*/{print $2; exit}' "$f")")
    done
    log "已导入生成词库: ${GENERATED_TABLES[*]}"
fi

# ── 7. keytao.extended.dict.yaml：幂等插入外挂词库 import ───────────────────
# 上游文件只读；这里在输出副本上插入，且锚点必须唯一存在。
# 旧方案是在 nix store 里 sed -i，静默、不可复现、上游一变就坏。
EXT="$OUT/keytao.extended.dict.yaml"
[ -f "$EXT" ] || die "缺少 $EXT"

INSERT_TABLES=(cloudkeytao.custom.user cloudkeytao.local ${GENERATED_TABLES[@]+"${GENERATED_TABLES[@]}"})

anchor_count=$(grep -c '^\.\.\.$' "$EXT" || true)
[ "$anchor_count" -eq 1 ] || die "$EXT 里 '...' 结束符应恰好 1 个，实际 $anchor_count 个（上游结构变了，请检查）"

tmp=$(mktemp)
awk -v tables="${INSERT_TABLES[*]}" '
    /^\.\.\.$/ {
        n = split(tables, t, " ")
        for (i = 1; i <= n; i++) print "  - " t[i]
    }
    { print }
' "$EXT" > "$tmp"
mv "$tmp" "$EXT"

for t in "${INSERT_TABLES[@]}"; do
    grep -qx "  - $t" "$EXT" || die "§7 插入失败: $t 未出现在 $EXT"
    log "extended 已挂载: $t"
done

# ── 8. 归一化：内联 schema + 词库改名 + 删除多方案产物 ──────────────────────
# 这一步之后，产物里不再有 keytao.schema.yaml，所有表名变成 cloudkeytao.*，
# 菜单里只剩 cloudkeytao 一个方案。
#
# normalize 要改写 dicts/ 拷进来的文件，而这些文件在 nix 下也是只读。
chmod -R u+w "$OUT"
"$PYTHON" "$REPO_ROOT/scripts/normalize.py" \
    --out "$OUT" \
    --meta "$REPO_ROOT/overlay/schema-meta.yaml"

# ── 9. 断言：产物结构完整 ────────────────────────────────────────────────────
require_file() { [ -f "$OUT/$1" ] || die "产物缺少 $1"; }
require_abs()  { [ ! -e "$OUT/$1" ] || die "产物不应包含 $1（多方案残留）"; }
require_grep() { grep -q -- "$2" "$OUT/$1" || die "产物 $1 缺少期望内容: $2"; }

require_file cloudkeytao.schema.yaml
require_file cloudkeytao.custom.yaml
require_file default.custom.yaml
require_file rime.lua
require_file lua/_upstream.lua
require_file lua/select_character.lua
require_file cloudkeytao.custom.user.dict.yaml
require_file cloudkeytao.local.dict.yaml
require_file cloudkeytao.extended.dict.yaml
require_grep cloudkeytao.extended.dict.yaml "  - cloudkeytao.local"

require_abs keytao.schema.yaml
require_abs keytao-bj.schema.yaml
require_abs keytao-dz.schema.yaml
require_abs keytao-dz.extended.dict.yaml

# 兜底：产物里只能有一个 schema，且不能有 keytao.* 词库文件
mapfile -t schema_files < <(cd "$OUT" && ls *.schema.yaml 2>/dev/null)
[ "${#schema_files[@]}" -eq 1 ] \
    || die "产物应只有 1 个 .schema.yaml，实际: ${schema_files[*]:-none}"
[ "${schema_files[0]}" = "cloudkeytao.schema.yaml" ] \
    || die "产物唯一 schema 应为 cloudkeytao.schema.yaml，实际 '${schema_files[0]}'"
leftover_dicts=$(cd "$OUT" && ls keytao*.dict.yaml 2>/dev/null || true)
[ -z "$leftover_dicts" ] \
    || die "产物仍有未改名的 keytao 词库: $leftover_dicts"
log "产物只有 cloudkeytao.schema.yaml，无 keytao.* 词库 ✓"

require_grep cloudkeytao.schema.yaml 'schema_id: cloudkeytao'
require_grep cloudkeytao.schema.yaml 'name: CloudKeyTao'
require_grep cloudkeytao.schema.yaml 'dictionary: cloudkeytao.extended'
require_grep cloudkeytao.extended.dict.yaml 'name: cloudkeytao.extended'
require_grep default.custom.yaml 'schema: cloudkeytao'
require_grep rime.lua 'require("_upstream")'

# ── 10. 断言：schema_list 恰好只有 cloudkeytao ──────────────────────────────
mapfile -t schemas < <(awk '
    /^  schema_list:/ { f = 1; next }
    f && /^  [a-zA-Z_]/ { f = 0 }
    f && /- schema:[[:space:]]*/ { sub(/^.*- schema:[[:space:]]*/, ""); print }
' "$OUT/default.custom.yaml")

[ "${#schemas[@]}" -eq 1 ] || die "schema_list 应只有 1 个方案，实际: ${schemas[*]}"
[ "${schemas[0]}" = "cloudkeytao" ] || die "schema_list 唯一方案应为 cloudkeytao，实际 '${schemas[0]}'"
log "schema_list = [cloudkeytao] ✓（单方案产物）"

# ── 11. 断言：switches 索引未错位 ──────────────────────────────────────────
# cloudkeytao.custom.yaml 用 "switches/@3/reset" 打开 emoji_cn。
# 上游一旦新增或重排 switches，索引就会静默错位——所以这里显式验证。
mapfile -t switch_names < <(awk '
    /^switches:/ { insw = 1; next }
    insw && /^[a-zA-Z_]/ { insw = 0 }
    insw && /^  - name:/ { print $3 }
' "$OUT/cloudkeytao.schema.yaml")
[ "${#switch_names[@]}" -gt 3 ] || die "无法从 cloudkeytao.schema.yaml 解析出 switches（结构变了？）"
[ "${switch_names[3]}" = "emoji_cn" ] \
    || die "switches/@3 期望是 emoji_cn，实际是 '${switch_names[3]}'——cloudkeytao.custom.yaml 的索引 patch 已错位"
log "switches/@3 = emoji_cn ✓（索引 patch 有效）"

# ── 12. 断言：key_binder 路径正确 ──────────────────────────────────────────
# 历史坑：旧 NixOS-Config 写成 "key/key_binder/bindings/+",librime 读的是
# key_binder/bindings，多一层 key/ 会变成无人读取的孤立节点，
# 结果 F3 与 , . 翻页从来没生效过。这里显式断言不再出现孤立 key: 节点。
grep -q '^key:' "$OUT/cloudkeytao.schema.yaml" \
    && die "cloudkeytao.schema.yaml 出现孤立的顶层 'key:' 节点——patch 路径写错了（应为 key_binder/bindings/+）"
log "无孤立 'key:' 节点 ✓（key_binder 路径正确）"

log "OK —— 产物就绪: $OUT"
log "     唯一方案: cloudkeytao"
