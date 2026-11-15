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

# ── 6b. 生成词库（M2 起）────────────────────────────────────────────────
# cloudkeytao.xmjd6：从 xmjd6 加工出来的长尾词组表（§6）。
# 生成逻辑在 scripts/merge-xmjd6.py，这里只负责调用与校验。
#
# 为什么直接写到 $OUT 而不是 dicts/gen/ 再拷：
# 在 nix 下 $REPO_ROOT 是只读的 store 路径，往 dicts/gen/ 写会
# PermissionError。产物目录 $OUT 是唯一可写的地方 —— 这也更正确：
# 生成物本来就是产物的一部分，不是源码。
#
# 为什么要传 --existing：§6.4 要求与 keytao 已有词条重复的保留 keytao 版本。
# 实测 cizu+fjcy 里有 9.3 万条与 keytao 重叠，不排除的话这些词会在
# 候选里出现两次（同一个 (text,code) 在两个表里各一份）。
if [ -n "$XMJD6_SRC" ]; then
    merge_args=()
    shopt -s nullglob
    for f in "$KEYTAO_SRC"/rime/keytao.*.dict.yaml; do
        merge_args+=(--existing "$f")
    done
    shopt -u nullglob
    [ ${#merge_args[@]} -gt 0 ] || die "找不到任何 keytao.*.dict.yaml 作为 --existing 输入"

    log "生成 cloudkeytao.xmjd6（xmjd6-cizu/fjcy >=4 码 + danzi）..."
    "$PYTHON" "$REPO_ROOT/scripts/merge-xmjd6.py" \
        --xmjd6-src "$XMJD6_SRC" \
        --out "$OUT/cloudkeytao.xmjd6.dict.yaml" \
        --report "$OUT/xmjd6-report.md" \
        "${merge_args[@]}"
    chmod u+w "$OUT/cloudkeytao.xmjd6.dict.yaml"
else
    die "XMJD6_SRC 未设置：M2 起构建必须提供 xmjd6 词库来源"
fi

# 注：生成表名已是最终名（cloudkeytao.xmjd6），不需要 normalize 改名，
# 但必须出现在 extended 的 import_tables 里（第 7 步）。
GENERATED_TABLES=()
[[ -f "$OUT/cloudkeytao.xmjd6.dict.yaml" ]] && GENERATED_TABLES=(cloudkeytao.xmjd6)

# ── 6b′. 反查词库（M3，§7）──────────────────────────────────────────────
# 三份词库只服务 `` ` `` 反查，**不能**进 extended 的 import_tables：
# 它们存的是拼音/二分的编码，混进主词库会把「到」这类单字的候选
# 变成拼音字符串。反查靠独立的 table_translator 按需加载。
#
# 表名改名为 cloudkeytao.* 是必要的：normalize.py 的引用改写只认
# keytao 前缀（这里源名是 pinyin_simp/liangfen/xmjd6.gbk），
# 而且是产物自己的命名空间，避免和 rime 预设的 stroke/symbols 撞名。
if [ -n "$XMJD6_SRC" ]; then
    declare -A LOOKUP_SRC=(
        [cloudkeytao.lookup.pinyin]="$XMJD6_SRC/pinyin_simp.dict.yaml"
        [cloudkeytao.lookup.liangfen]="$XMJD6_SRC/liangfen.dict.yaml"
        [cloudkeytao.lookup.gbk]="$XMJD6_SRC/xmjd6.gbk.dict.yaml"
    )
    LOOKUP_TABLES=()
    for name in "${!LOOKUP_SRC[@]}"; do
        src="${LOOKUP_SRC[$name]}"
        [ -f "$src" ] || die "反查词库缺失: $src"
        # 用 awk 重写 name: 行，其余内容（表头/词条）原样保留。
        # 不用 sed -i：在只读 store 上无意义，且需处理管道编码。
        awk -v n="$name" '
            !done && /^name:[[:space:]]*/ { print "name: " n; done=1; next }
            { print }
            END { if (!done) { print "# WARNING: 原表没有 name: 行" > "/dev/stderr" } }
        ' "$src" > "$OUT/$name.dict.yaml" \
            || die "重写反查词库表头失败: $src"
        chmod u+w "$OUT/$name.dict.yaml"
        LOOKUP_TABLES+=("$name")

        # 每个反查词库必须有自己的 schema —— 不是为了给用户选，
        # 而是因为 rime_deployer 只编译 schema_list 里的 schema 及其
        # schema/dependencies 声明的依赖（见 librime
        # lever/deployment_tasks.cc:240 那段 build_schema(dependency_id)）。
        #
        # 没有这个文件，反查词库永远不会生成 .table.bin，
        # translator 加载时只会在日志里留一行 E，运行时默默返回 0 候选。
        # （实测踩过，§7 未预见）
        label=${name##*.}
        case "$label" in
            pinyin)   label_zh="拼音" ;;
            liangfen) label_zh="二分" ;;
            gbk)      label_zh="GBK"  ;;
            *)        label_zh="$label" ;;
        esac
        cat > "$OUT/$name.schema.yaml" <<EOF
# 反查词库的编译载体 —— 由 cloudkeytao.schema.yaml 的
# schema/dependencies 引用，因此不需要进 schema_list，用户菜单里看不到。
# 本文件由 scripts/build.sh 的 6b′ 步生成，勿手改。
schema:
  schema_id: $name
  name: CloudKeyTao 反查·$label_zh
  version: "1.0"

engine:
  translators:
    - table_translator

translator:
  dictionary: $name

speller:
  alphabet: "abcdefghijklmnopqrstuvwxyz"
EOF
        chmod u+w "$OUT/$name.schema.yaml"
    done
    log "反查词库就绪: ${LOOKUP_TABLES[*]}"
else
    die "XMJD6_SRC 未设置：M3 反查词库也来自 xmjd6"
fi

# ── 6c. 手写回流词库与生成物共存 ────────────────────────────────────────────
# dicts/gen/ 只在本地开发时存在（构建时已直接写入 $OUT）。
# 保留这一步是为了让 `python3 scripts/merge-xmjd6.py --out dicts/gen/...`
# 这种手动调试产出的文件也能被正常带进产物。
shopt -s nullglob
gen_dicts=("$REPO_ROOT"/dicts/gen/*.dict.yaml)
shopt -u nullglob
if [ ${#gen_dicts[@]} -gt 0 ]; then
    for f in "${gen_dicts[@]}"; do
        name=$(awk '/^name:[[:space:]]*/{print $2; exit}' "$f")
        [ -f "$OUT/$name.dict.yaml" ] && continue
        cp "$f" "$OUT/"
        GENERATED_TABLES+=("$name")
    done
    [ ${#GENERATED_TABLES[@]} -eq 0 ] || log "已导入本地生成词库: ${GENERATED_TABLES[*]}"
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

# 兜底：产物里只能有一个**方案** schema，且不能有 keytao.* 词库文件
#
# 例外：cloudkeytao.lookup.*.schema.yaml 是反查词库的编译载体，
# 只有 schema_id / dictionary / 空 speller，不进 schema_list，
# 用户菜单里看不到。它们必须存在，否则反查词典不会被编译。
mapfile -t all_schema_files < <(
    cd "$OUT"
    shopt -s nullglob
    schema_files=(./*.schema.yaml)
    shopt -u nullglob
    for schema in "${schema_files[@]}"; do
        printf '%s\n' "${schema#./}"
    done
)
mapfile -t schema_files < <(
    printf '%s\n' "${all_schema_files[@]}" | grep -v '^cloudkeytao\.lookup\.' || true
)
[ "${#schema_files[@]}" -eq 1 ] \
    || die "产物应只有 1 个方案 .schema.yaml，实际: ${schema_files[*]:-none}"
[ "${schema_files[0]}" = "cloudkeytao.schema.yaml" ] \
    || die "产物唯一方案 schema 应为 cloudkeytao.schema.yaml，实际 '${schema_files[0]}'"
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

# ── 13. 断言：词库合并的硬约束（§6.4）────────────────────────────────────────
# 这些不是「跑通就行」的检查，而是方案里写明的接受条件。一旦被后续改动
# 破坏（比如把 MIN_CODE_LEN 改小、或忘了传 --existing），这里必须 fail。
XT="cloudkeytao.xmjd6.dict.yaml"
require_file "$XT"
XTP="$OUT/$XT"

# 13a. 简码（≤3 码）层条目数不增加 —— Q15′ 的硬约束。
# xmjd6 的短码层是键道三简字的地盘，插进来直接恶化首选命中。
short_codes=$(awk -F'\t' 'NF>=3 && length($2)<=3' "$XTP" | wc -l)
[ "$short_codes" -eq 0 ] \
    || die "cloudkeytao.xmjd6 含 $short_codes 条 ≤3 码词条，违反 §6.4「简码层条目数不增加」"

# 13b. 码长上限：键道编码最长 6 码；超长码在别处是数据错误
long_codes=$(awk -F'\t' 'NF>=3 && length($2)>6' "$XTP" | wc -l)
[ "$long_codes" -eq 0 ] \
    || die "cloudkeytao.xmjd6 含 $long_codes 条 >6 码词条"

# 13c. 与 keytao 已有词库不得有 (text,code) 重复（§6.4）
# 用产物里的表对比，而不是重新读上游：断言的是「最终产物」的性质。
#
# 必须固定 LC_ALL=C：comm 要求两个输入用**同一个** collation 排序。
# 默认 locale 是中文时，sort 的排序规则与 comm 期望的不一致，
# 会报「未排序」或给出假阳性。
keytao_keys=$(mktemp)
xmjd6_keys=$(mktemp)
trap 'rm -f "$keytao_keys" "$xmjd6_keys"' EXIT
for f in "$OUT"/cloudkeytao.single.dict.yaml "$OUT"/cloudkeytao.phrase.dict.yaml \
         "$OUT"/cloudkeytao.supplement.dict.yaml "$OUT"/cloudkeytao.symbol.dict.yaml \
         "$OUT"/cloudkeytao.css.dict.yaml "$OUT"/cloudkeytao.link.dict.yaml \
         "$OUT"/cloudkeytao.english.dict.yaml; do
    [ -f "$f" ] || continue
    LC_ALL=C awk -F'\t' 'NF>=2 && $2 ~ /^[a-z;]+$/ {print $1"\t"$2}' "$f"
done | LC_ALL=C sort -u > "$keytao_keys"
LC_ALL=C awk -F'\t' 'NF>=3 {print $1"\t"$2}' "$XTP" | LC_ALL=C sort -u > "$xmjd6_keys"
overlap=$(LC_ALL=C comm -12 "$keytao_keys" "$xmjd6_keys" | wc -l)
[ "$overlap" -eq 0 ] \
    || die "cloudkeytao.xmjd6 与已有词库有 $overlap 条 (text,code) 重复，违反 §6.4（检查是否忘了传 --existing）"

# 13d. 平均候选数与最大候选数（§6.4）
# 把产物里所有**主词库**表合起来算，因为主词库的候选是跨表展示的。
#
# 必须排除反查词库（cloudkeytao.lookup.*）：它们存的是拼音/二分编码，
# 大量同码（如拼音 "yi" 就有上百个字），混进来会让这个断言失去意义。
# 反查候选多不是问题 —— 反查本来就是"列出一堆让你选"。
main_dicts=()
for f in "$OUT"/cloudkeytao.*.dict.yaml; do
    case "$f" in
        */cloudkeytao.lookup.*) continue ;;
    esac
    main_dicts+=("$f")
done
[ ${#main_dicts[@]} -gt 0 ] || die "找不到任何主词库产物"
avg_and_max=$(LC_ALL=C awk -F'\t' '
    FNR==1 { next }
    NF>=2 && $1 !~ /^#/ && $2 ~ /^[a-z;]+$/ && $1 != "text" { c[$2]++ }
    END {
        n = length(c)
        if (n == 0) { print "0 0"; exit }
        total = 0
        for (k in c) total += c[k]
        mx = 0
        for (k in c) if (c[k] > mx) mx = c[k]
        printf "%.3f %d\n", total/n, mx
    }
' "${main_dicts[@]}")
avg=${avg_and_max% *}
mx=${avg_and_max#* }
awk -v a="$avg" 'BEGIN { exit !(a <= 1.2) }' \
    || die "平均候选数 $avg 超过 §6.4 上限 1.2"
[ "$mx" -le 12 ] \
    || die "最大候选数 $mx 超过 §6.4 上限 12"
log "词库合并断言 ✓（简码层 0 新增、无 >6 码、与已有词库 0 重复、平均候选 $avg、最大 $mx）"

log "OK —— 产物就绪: $OUT"
log "     唯一方案: cloudkeytao"
