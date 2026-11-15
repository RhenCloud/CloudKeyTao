#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DIST=${OUT:-$REPO_ROOT/dist/rime}
SHARED=${RIME_SHARED:-}

log() { printf '[runtime-bench] %s\n' "$*"; }
die() { printf '[runtime-bench] ERROR: %s\n' "$*" >&2; exit 1; }

command -v rime_deployer >/dev/null || die "找不到 rime_deployer"
command -v c++ >/dev/null || die "找不到 c++"
[ -d "$DIST" ] || die "产物目录不存在: $DIST（先运行 scripts/build.sh）"

if [ -z "$SHARED" ]; then
    for candidate in /nix/store/*fcitx5-rime*/share/rime-data; do
        [ -d "$candidate" ] || continue
        SHARED=$candidate
    done
fi
[ -d "$SHARED" ] || die "找不到 RIME_SHARED"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp -r "$DIST/." "$WORK/rime"
chmod -R u+w "$WORK/rime"

set +e
rime_deployer --build "$WORK/rime" "$SHARED" "$WORK/build" \
    >"$WORK/deploy.log" 2>&1
deploy_rc=$?
set -e
[ "$deploy_rc" -eq 0 ] || { cat "$WORK/deploy.log" >&2; die "部署失败"; }
! grep -qE '^E[0-9]' "$WORK/deploy.log" || die "部署日志包含错误"

RIME_LIB=$(ldd "$(command -v rime_deployer)" | awk '/librime\.so/ {print $3; exit}')
[ -n "$RIME_LIB" ] && [ -e "$RIME_LIB" ] || die "找不到 librime 动态库"
RIME_DIR=$(dirname "$(dirname "$RIME_LIB")")
[ -f "$RIME_DIR/include/rime_api.h" ] || die "找不到 rime_api.h"

c++ -std=c++17 -O1 -I"$RIME_DIR/include" \
    "$REPO_ROOT/scripts/runtime-bench.cc" \
    -L"$(dirname "$RIME_LIB")" -lrime \
    -Wl,-rpath,"$(dirname "$RIME_LIB")" -o "$WORK/runtime-bench"

printf 'label\tinput\texpected\trank\tcandidates\n'
"$WORK/runtime-bench" "$WORK/rime" "$SHARED"
