#!/usr/bin/env bash
# 확정한 실험 매트릭스(PLAN.md 6장)를 순서대로 실행한다.
# - 같은 조건 2회는 서로 다른 컨테이너 2개로 동시에 돌린다(b42-* 최대 2개 규칙).
# - CPU 케이스는 측정 오염을 막기 위해 단독으로, 한 번에 하나씩 돌린다.
# 사용법: env/run-matrix.sh [oom|deadlock|cpu ...]   (인자가 없으면 전부)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
R=env/run-case.sh

pair() { # 같은 조건 2회를 동시에: pair <case> <label-prefix> <run-case 옵션...>
    local c=$1 p=$2; shift 2
    $R "$c" "$p-1" "$@" & local a=$!
    sleep 2
    $R "$c" "$p-2" "$@" & local b=$!
    wait $a $b
}

oom() {
    # 다른 장애가 끼어들지 않게 CPU_MAX_OCCUPY=50(경고 없음), MULTI_THREAD_ENABLE=false 고정
    pair oom before   --timeout 300 --snap-every 10 MEMORY_LIMIT=256 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=false
    pair oom low128   --timeout 300 --snap-every 10 MEMORY_LIMIT=128 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=false
    pair oom after    --timeout 300 --snap-every 60 MEMORY_LIMIT=512 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=false
}

deadlock() {
    # MEMORY_LIMIT=256 이하이면 OOM 시나리오가 먼저 선택되므로 512로 고정
    pair deadlock before --timeout 240 --snap-every 30 MEMORY_LIMIT=512 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=true
    pair deadlock after  --timeout 240 --snap-every 30 MEMORY_LIMIT=512 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=false
}

cpu() {
    # 단독 실행. CPU_MAX_OCCUPY 가 50 을 넘으면 경고 후 Watchdog 시나리오가 선택된다(탐색에서 확인).
    $R cpu before-1 --timeout 300 --snap-every 10 MEMORY_LIMIT=512 CPU_MAX_OCCUPY=80 MULTI_THREAD_ENABLE=false
    $R cpu before-2 --timeout 300 --snap-every 10 MEMORY_LIMIT=512 CPU_MAX_OCCUPY=80 MULTI_THREAD_ENABLE=false
    $R cpu after-1  --timeout 300 --snap-every 30 MEMORY_LIMIT=512 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=false
    $R cpu after-2  --timeout 300 --snap-every 30 MEMORY_LIMIT=512 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=false
}

[ $# -gt 0 ] || set -- oom deadlock cpu
for c in "$@"; do
    case "$c" in oom|deadlock|cpu) echo "===== $c 시작 $(date '+%F %T')"; "$c"; echo "===== $c 끝 $(date '+%F %T')" ;;
        *) echo "알 수 없는 케이스: $c" >&2; exit 2 ;; esac
done
