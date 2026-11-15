#!/usr/bin/env bash
# 全量验收 —— CI 与本地共用同一条链路。
#
# 一次跑完所有检查，任何一步失败即中止。CI 里没有魔法：
# GitHub Actions 做的就是 `nix develop -c ./scripts/check-all.sh`。
#
# 检查项：
#   1. shell 语法        bash -n 所有脚本
#   2. python 语法       py_compile
#   3. lua 语法          luac -p
#   4. 构建 + 断言       scripts/build.sh
#   5. 部署真编译        scripts/validate.sh
#   6. 占用清单未漂移    gen-occupied-doc.py --check
#   7. bench 无退化      bench.py --check
#   8. 产物幂等          连跑两次构建，字节级比对
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

step() { printf '\n\033[1m── %s ──\033[0m\n' "$*"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

step "1/8 shell 语法"
for f in scripts/*.sh; do
    bash -n "$f" || die "$f 语法错误"
    printf '  ✓ %s\n' "$f"
done

step "2/8 python 语法"
PYTHON=${PYTHON:-python3}
for f in scripts/*.py; do
    "$PYTHON" -m py_compile "$f" || die "$f 语法错误"
    printf '  ✓ %s\n' "$f"
done
rm -rf scripts/__pycache__

step "3/10 lua 语法"
if command -v luac >/dev/null; then
    shopt -s nullglob
    for f in lua/*.lua overlay/lua/*.lua; do
        luac -p "$f" || die "$f 语法错误"
        printf '  ✓ %s\n' "$f"
    done
    shopt -u nullglob
else
    printf '  (跳过：没有 luac)\n'
fi

step "4/10 shellcheck"
if command -v shellcheck >/dev/null; then
    shellcheck scripts/*.sh || die "shellcheck 检查失败"
    printf '  ✓ shellcheck\n'
else
    printf '  (跳过：没有 shellcheck)\n'
fi

step "5/10 python lint"
if command -v ruff >/dev/null; then
    ruff check scripts/*.py || die "ruff 检查失败"
    printf '  ✓ ruff\n'
else
    printf '  (跳过：没有 ruff)\n'
fi

step "6/10 构建 + 结构断言"
./scripts/build.sh

step "7/10 部署真编译"
./scripts/validate.sh --no-build

step "8/10 占用清单未漂移"
"$PYTHON" scripts/gen-occupied-doc.py --check

step "9/10 bench 无退化"
"$PYTHON" scripts/bench.py --check

step "10/10 产物幂等"
TMP_A=$(mktemp -d); TMP_B=$(mktemp -d)
trap 'rm -rf "$TMP_A" "$TMP_B"' EXIT
OUT="$TMP_A" ./scripts/build.sh >/dev/null
OUT="$TMP_B" ./scripts/build.sh >/dev/null
diff -r "$TMP_A" "$TMP_B" >/dev/null \
    || die "两次构建产物不一致（非幂等）"
printf '  ✓ 两次构建字节级一致\n'

step "11/11 工作流语法"
if command -v actionlint >/dev/null; then
    actionlint .github/workflows/*.yml || die "actionlint 检查失败"
    printf '  ✓ actionlint\n'
else
    printf '  (跳过：没有 actionlint)\n'
fi

printf '\n\033[32m全部通过\033[0m\n'
