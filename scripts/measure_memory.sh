#!/usr/bin/env bash
# 内存度量 —— 反查词库（M3）的常驻开销到底有多少。
#
# 为什么需要这个脚本（§7 的 M3 验证点）：
#   反查引入三张额外的词表（拼音 6.5 万 / 二分 9.4 万 / GBK 2.4 万）。
#   §7 原文担心「显著增加部署时间与内存」，并预留了退路：GBK 词库只在
#   `o` 键补丁下按需加载。要不要走退路，必须先有数字。
#
# 关键前提（实测，决定了本脚本怎么测）：
#   **反查词表不是懒加载**。它们挂在 engine/translators 里，
#   TableTranslator 在 Initialize() 时就 Load()，所以哪怕用户从不打
#   `` ` ``，三张表也已经驻留内存。实测启动日志：
#       loading table file: cloudkeytao.extended.table.bin
#       loading table file: cloudkeytao.lookup.pinyin.table.bin
#       loading table file: cloudkeytao.lookup.liangfen.table.bin
#       loading table file: cloudkeytao.lookup.gbk.table.bin
#   因此「只在用反查时才付出代价」这个假设不成立，退路若要成立，
#   得改成按需挂 translator，而不是单靠用户不打就不加载。
#
# 测什么：
#   用一个最小 librime 客户端（下称 probe）加载方案，稳定后读 RSS。
#   对比两组：
#     base   —— 把 schema/dependencies 与三个反查 translator 摘掉
#     lookup —— 完整产物
#   差值就是反查的常驻开销。
#
# 为什么要自建 probe 而不是 ps 抓 fcitx5：
#   fcitx5 的 RSS 混了 UI、其他 addon、字体缓存等噪声，且方案切换时机
#   不可控，重复跑波动很大。probe 只做「initialize → select_schema →
#   读 RSS」，噪声小、可重复。
#
# 用法：
#   ./scripts/measure_memory.sh              # 构建 → 部署 → 两组对比
#   ./scripts/measure_memory.sh --runs 5     # 每组采样 5 次取中位数
#   ./scripts/measure_memory.sh --keep       # 保留临时目录（排查用）
#
# 输出：Markdown 表格 + 机器可读的 key=value，方便贴进设计文档 / CI。
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DIST=${OUT:-$REPO_ROOT/dist/rime}
RUNS=3
KEEP=0

while [ $# -gt 0 ]; do
    case "$1" in
        --runs) RUNS=$2; shift 2 ;;
        --runs=*) RUNS=${1#*=}; shift ;;
        --keep) KEEP=1; shift ;;
        -h|--help) sed -n '2,44p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf '未知参数: %s\n' "$1" >&2; exit 2 ;;
    esac
done

log() { printf '[mem] %s\n' "$*"; }
die() { printf '[mem] ERROR: %s\n' "$*" >&2; exit 1; }

case "$RUNS" in
    ''|*[!0-9]*) die "--runs 需要正整数，收到 '$RUNS'" ;;
esac
[ "$RUNS" -ge 1 ] || die "--runs 需要 >= 1"

command -v rime_deployer >/dev/null || die "找不到 rime_deployer（nix develop 会提供）"
command -v c++ >/dev/null || die "找不到 c++（编译 probe 用）"

[ -d "$DIST" ] || die "产物目录不存在: $DIST（先跑 scripts/build.sh）"

# 共享数据目录：与 validate.sh 同一套推导
SHARED=${RIME_SHARED:-}
if [ -z "$SHARED" ]; then
    SHARED=$(ls -d /nix/store/*/share/rime-data 2>/dev/null | grep -E 'fcitx5-rime' | sort -V | tail -1 || true)
fi
[ -n "$SHARED" ] && [ -d "$SHARED" ] || die "找不到 rime 共享数据目录（设置 RIME_SHARED）"

# librime 的头文件与库：从 rime_deployer 的真实依赖推，避免与 devShell 版本错配
#
# ldd 给的可能是软链目标（.../lib/librime.so.1.17.0），所以要往上找到
# 同时包含 include/ 与 lib/ 的那个前缀 —— 不能写死只退一层。
RIME_LIB=$(ldd "$(command -v rime_deployer)" | awk '/librime\.so/ {print $3; exit}')
[ -n "$RIME_LIB" ] && [ -e "$RIME_LIB" ] || die "推导不出 librime 路径"
RIME_DIR=$(dirname "$RIME_LIB")          # .../lib
RIME_DIR=$(dirname "$RIME_DIR")          # 包根
# 兼容「库在包根/lib 下」与「库在包根本身」两种布局
if [ ! -f "$RIME_DIR/include/rime_api.h" ]; then
    cand=$(dirname "$RIME_LIB")
    if [ -f "$cand/include/rime_api.h" ]; then RIME_DIR=$cand; fi
fi
[ -f "$RIME_DIR/include/rime_api.h" ] || die "找不到 rime_api.h（推导的前缀: $RIME_DIR）"
log "librime = $RIME_LIB"

WORK=$(mktemp -d)
cleanup() { [ "$KEEP" -eq 1 ] && log "临时目录保留: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

# ── probe：加载方案，等稳定，读 RSS（单位 KiB） ────────────────────────────
# 为什么 sleep 再读：词典是 mmap 的，Load() 返回时页还没全触碰，
# RSS 会虚低。给 300ms 让它把热路径走一遍，多次采样取中位数再消除抖动。
cat > "$WORK/probe.cc" <<'EOF'
#include <rime_api.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>

// 读本进程 RSS（KiB）。读 /proc/self/statm 比 getrusage 更贴近
// 「用户看到的常驻内存」——后者给的是峰值，对稳态判断没用。
static long rss_kib() {
  FILE* f = fopen("/proc/self/statm", "r");
  if (!f) return -1;
  long size = 0, resident = 0;
  if (fscanf(f, "%ld %ld", &size, &resident) != 2) { fclose(f); return -1; }
  fclose(f);
  return resident * (sysconf(_SC_PAGESIZE) / 1024);
}

int main(int argc, char** argv) {
  if (argc < 5) {
    fprintf(stderr, "usage: probe <user_dir> <shared_dir> <schema_id> <warm_keys>\n");
    return 2;
  }
  RimeApi* api = rime_get_api();
  if (!api) { fprintf(stderr, "rime_get_api failed\n"); return 3; }

  RIME_STRUCT(RimeTraits, traits);
  traits.user_data_dir = argv[1];
  traits.shared_data_dir = argv[2];
  traits.app_name = "memprobe";
  traits.distribution_name = "memprobe";
  traits.distribution_code_name = "memprobe";
  traits.distribution_version = "0";
  api->initialize(&traits);
  api->start_maintenance(True);
  api->join_maintenance_thread();

  RimeSessionId session = api->create_session();
  if (!session) { fprintf(stderr, "create_session failed\n"); return 4; }
  api->select_schema(session, argv[3]);

  // 灌几个词，逼 word graph / 候选生成走一遍，
  // 否则只测到「词典刚 Load 完」而不是「用起来之后」。
  //
  // argv[4] 用 ';' 分隔多个输入串，每串完整灌完后清空。
  // 不能逐字符 clear —— 那样每个键都是新 composition，
  // 前缀永远不完整，反查表一次都不会被真正查到（实测教训）。
  if (argv[4] && strcmp(argv[4], "-") != 0) {
    const char* p = argv[4];
    while (*p) {
      api->clear_composition(session);
      while (*p && *p != ';') {
        api->process_key(session, *p, 0);
        ++p;
      }
      if (*p == ';') ++p;
      usleep(20 * 1000);  // 给候选生成一点时间
    }
  }
  usleep(300 * 1000);  // 等内存稳定

  long kib = rss_kib();
  api->destroy_session(session);
  api->finalize();

  if (kib < 0) { fprintf(stderr, "rss read failed\n"); return 5; }
  printf("%ld\n", kib);
  return 0;
}
EOF

log "编译 probe…"
c++ -std=c++17 -O1 -I"$RIME_DIR/include" "$WORK/probe.cc" \
    -L"$(dirname "$RIME_LIB")" -lrime -Wl,-rpath,"$(dirname "$RIME_LIB")" \
    -o "$WORK/probe" || die "probe 编译失败"

# ── 部署一个目录（就地编译到 <root>/build）──────────────────────────────
deploy_tree() {  # $1 = 已由调用方 copy 好的部署根
    local root=$1
    rime_deployer --build "$root" "$SHARED" "$root/build" > "$root/deploy.log" 2>&1 || true
    local errs
    errs=$(grep -cE '^E[0-9]' "$root/deploy.log" || true)
    [ "$errs" -eq 0 ] || die "部署 $root 产生 $errs 条错误（见 $root/deploy.log）"
}

log "部署完整产物（lookup）…"
FULL=$WORK/full
mkdir -p "$FULL"
cp -r "$DIST/." "$FULL/"
chmod -R u+w "$FULL"
deploy_tree "$FULL"

log "构造对照组（base：摘掉反查）…"
BASE=$WORK/base
mkdir -p "$BASE"
cp -r "$DIST/." "$BASE/"
chmod -R u+w "$BASE"

# 摘掉三样东西，得到一个「没有反查」的等价方案：
#   1. schema/dependencies 里三个 lookup 声明
#   2. cloudkeytao.custom.yaml 里三个 reverse_lookup_translator
#   3. lookup 词库与其编译载体（省得部署时报找不到）
#
# 用 python 而不是 sed：yaml 结构要按语义改，文本替换容易改出坏 yaml。
python3 - "$BASE" <<'PY' || die "构造 base 分组失败"
import re, sys
from pathlib import Path
root = Path(sys.argv[1])

# 1. 三个 translator 行 + dependencies 块
for name in ("cloudkeytao.custom.yaml",):
    p = root / name
    if not p.exists():
        continue
    lines = p.read_text(encoding="utf-8").splitlines(keepends=True)
    out, skip_dep_block = [], False
    for line in lines:
        if re.match(r'\s*-\s*reverse_lookup_translator@lookup_', line):
            continue
        if re.match(r'\s*schema/dependencies:\s*$', line):
            skip_dep_block = True
            continue
        if skip_dep_block:
            if re.match(r'\s*-\s*cloudkeytao\.lookup\.', line):
                continue
            skip_dep_block = False
        out.append(line)
    p.write_text("".join(out), encoding="utf-8")

# 2. lookup 词库与 schema 载体
for p in list(root.glob("cloudkeytao.lookup.*")):
    p.unlink()
PY

deploy_tree "$BASE"

# ── 采样 ──────────────────────────────────────────────────────────────────
# warm_keys 同时覆盖普通输入与反查：`dao 会真的查一次反查表，
# 确保测的是「用过之后」的稳态，而不是「加载完还没查过」。
# warm_keys：用 ';' 分隔多组。同时覆盖普通输入与三个反查词库，
# 让每张 lookup 表都真的被查一次（否则 mmap 页没被触碰，RSS 会虚低）。
#   普通词：dz / el / xxua
#   拼音反查：`dao / `hao
#   二分反查：`hr / `hryk
#   GBK：`wwx / `wxk
# shellcheck disable=SC2016  # 单引号是故意的：` 必须是字面反引号
WARM_KEYS='dz;el;xxua;`dao;`hao;`hr;`hryk;`wwx;`wxk'
sample() {  # $1 = 部署根；输出一次 RSS（KiB）
    # probe 会把 librime 的 INFO 日志打到 stderr（加载哪些 .bin、尺寸多少）。
    # 这些对排查有用但会淹没结果表，所以默认丢弃 —— 用 MEM_VERBOSE=1 取回。
    if [ "${MEM_VERBOSE:-0}" = "1" ]; then
        "$WORK/probe" "$1" "$SHARED" cloudkeytao "$WARM_KEYS"
    else
        "$WORK/probe" "$1" "$SHARED" cloudkeytao "$WARM_KEYS" 2>/dev/null
    fi
}

median() {  # stdin 每行一个整数
    sort -n | awk '{ a[NR] = $1 } END {
        if (NR == 0) { print 0; exit }
        if (NR % 2) { print a[(NR + 1) / 2] }
        else { printf "%.0f\n", (a[NR / 2] + a[NR / 2 + 1]) / 2 }
    }'
}

log "采样 base（$RUNS 次）…"
base_samples=$(for _ in $(seq "$RUNS"); do sample "$BASE"; done)
base_rss=$(printf '%s\n' "$base_samples" | median)

log "采样 lookup（$RUNS 次）…"
lookup_samples=$(for _ in $(seq "$RUNS"); do sample "$FULL"; done)
lookup_rss=$(printf '%s\n' "$lookup_samples" | median)

[ "$base_rss" -gt 0 ] && [ "$lookup_rss" -gt 0 ] || die "采样失败（base=$base_rss lookup=$lookup_rss KiB）"

delta=$((lookup_rss - base_rss))
pct=$(awk -v d="$delta" -v b="$base_rss" 'BEGIN { printf "%.1f", (b > 0 ? d * 100 / b : 0) }')

# .bin 体积作为旁证：mmap 的表文件越大，RSS 增量一般也越大
base_bin=$(du -cb "$BASE"/build/cloudkeytao.extended.table.bin 2>/dev/null | tail -1 | awk '{print $1}')
full_bin=$(du -cb "$FULL"/build/cloudkeytao.*.table.bin 2>/dev/null | tail -1 | awk '{print $1}')
base_bin=${base_bin:-0}
full_bin=${full_bin:-0}

kb_to_mib() { awk -v k="$1" 'BEGIN { printf "%.1f", k / 1024 }'; }

cat <<EOF

── 反查内存开销（RSS，$RUNS 次采样取中位数）──

| 分组 | RSS | .table.bin 合计 |
|---|---|---|
| base（无反查） | $(kb_to_mib "$base_rss") MiB | $(kb_to_mib "$((base_bin / 1024))") MiB |
| lookup（完整） | $(kb_to_mib "$lookup_rss") MiB | $(kb_to_mib "$((full_bin / 1024))") MiB |
| **增量** | **$(kb_to_mib "$delta") MiB（+$pct%）** | $(kb_to_mib "$(((full_bin - base_bin) / 1024))") MiB |

机器可读：
  base_rss_kib=$base_rss
  lookup_rss_kib=$lookup_rss
  delta_rss_kib=$delta
  delta_pct=$pct
  runs=$RUNS
  warm_keys=$WARM_KEYS

判断依据（§7 预留的退路阈值）：
  安卓侧若认为 $(kb_to_mib "$delta") MiB 不可接受，退路是把 GBK 词库
  改成按需挂载。注意：当前三张表都是 schema 加载即全量驻留（实测
  见脚本头部说明），所以退路不能靠「用户不打就不加载」，必须改成
  运行时按开关挂 translator。

EOF
