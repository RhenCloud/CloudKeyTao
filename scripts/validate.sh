#!/usr/bin/env bash
# 部署验证 —— 用 rime_deployer 真编译一遍产物。
#
# 这是 M1 最关键的验收：build.sh 只保证「文件长得对」，
# 只有 rime_deployer 能证明「rime 真的能读」。
#
# 判定标准（对齐上游 scripts/validate.sh）：
#   * 出现 ^E<数字> 行 = 失败
#   * 必须产出预期的 .bin
#
# 用法：
#   ./scripts/validate.sh              # 先 build 再验证
#   ./scripts/validate.sh --no-build   # 只验证现有 dist/rime
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DIST=${OUT:-$REPO_ROOT/dist/rime}
DO_BUILD=1

for arg in "$@"; do
    case "$arg" in
        --no-build) DO_BUILD=0 ;;
        -h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf '未知参数: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

log() { printf '[validate] %s\n' "$*"; }
die() { printf '[validate] ERROR: %s\n' "$*" >&2; exit 1; }

command -v rime_deployer >/dev/null || die "找不到 rime_deployer（nix develop 会提供）"

if [ "$DO_BUILD" -eq 1 ]; then
    log "先构建…"
    "$REPO_ROOT/scripts/build.sh"
fi

[ -d "$DIST" ] || die "产物目录不存在: $DIST（先跑 scripts/build.sh）"

# 共享数据目录：优先 RIME_SHARED，否则从 fcitx5-rime 猜
SHARED=${RIME_SHARED:-}
if [ -z "$SHARED" ]; then
    SHARED=$(ls -d /nix/store/*/share/rime-data 2>/dev/null | grep -E 'fcitx5-rime' | sort -V | tail -1 || true)
fi
[ -n "$SHARED" ] && [ -d "$SHARED" ] || die "找不到 rime 共享数据目录（设置 RIME_SHARED）"
log "RIME_SHARED = $SHARED"

# 在临时目录里部署，绝不碰 dist/ 与运行时目录
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp -r "$DIST/." "$WORK/"

log "rime_deployer --build …"
set +e
rime_deployer --build "$WORK" "$SHARED" "$WORK/build" > "$WORK/deploy.log" 2>&1
deploy_rc=$?
set -e

errors=$(grep -E '^E[0-9]' "$WORK/deploy.log" || true)
if [ -n "$errors" ]; then
    printf '%s\n' "$errors" >&2
    die "部署产生 $(( $(printf '%s\n' "$errors" | wc -l) )) 条错误"
fi
warnings=$(grep -cE '^W[0-9]' "$WORK/deploy.log" || true)
[ "$warnings" -eq 0 ] || log "警告 $warnings 条（不致命）"

# 必须产出预期 bin：唯一方案 cloudkeytao 的词库三件套
for bin in prism reverse table; do
    [ -f "$WORK/build/cloudkeytao.extended.$bin.bin" ] \
        || die "缺少 cloudkeytao.extended.$bin.bin（部署未真正完成，rc=$deploy_rc）"
done

# 产物里不能冒出第二个方案
mapfile -t schemas < <(cd "$WORK/build" && ls *.schema.yaml 2>/dev/null | grep -v '^default\.yaml$')
[ "${#schemas[@]}" -eq 1 ] || die "build/ 应有 1 个 schema，实际: ${schemas[*]:-none}"

log "OK —— 部署验证通过（$(( $(ls "$WORK"/build/*.bin | wc -l) )) 个 bin）"
