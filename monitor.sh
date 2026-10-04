#!/usr/bin/env bash
# monitor.sh — 대상 프로세스 1개의 CPU·메모리·스레드·상태·앱 로그 정지 시간을 주기적으로 기록한다.
#
# 사용법:
#   monitor.sh [-p PATTERN] [-i INTERVAL_SEC] [-o LOG_FILE] [-l APP_LOG] [-n COUNT] [--once]
#     -p PATTERN   pgrep -f 로 찾을 명령줄 패턴 (기본 agent-leak-app)
#     -i SEC       샘플 간격 초 (기본 5)
#     -o LOG_FILE  기록 파일, >> 로 누적 (기본 $AGENT_LOG_DIR/monitor.log)
#     -l APP_LOG   앱 로그 파일. 마지막 수정 후 경과 초를 LOG_AGE 로 기록 (없으면 -)
#     -n COUNT     COUNT 번 기록하고 끝낸다 (기본: 무한 반복)
#     --once       1번만 기록하고 끝낸다 (-n 1 과 같다)
#
# 출력 한 줄:
#   [YYYY-MM-DD HH:MM:SS] PID:<pid> CPU:<x.x>% MEM:<x.x>% RSS:<x.x>MB THREADS:<n> STATE:<R|S|D|Z|T> LOG_AGE:<n>s
#   대상이 없으면: [YYYY-MM-DD HH:MM:SS] PID:- STATUS:NOT_RUNNING
#
# 값의 출처와 기준:
#   PID     pgrep -f 결과 중 monitor 자신·하위 셸과 "자식도 패턴과 맞는 부모(런처)"를 뺀 가장 오래된 프로세스
#   CPU     /proc/PID/stat 의 utime+stime(14·15번째 필드) 차분 ÷ CLK_TCK ÷ 경과초 × 100.
#           ps 의 %cpu 는 프로세스 생애 평균이라 급상승을 놓치므로 쓰지 않는다.
#           구간 값이므로 스레드 여러 개가 동시에 돌면 100%를 넘을 수 있다(코어 1개 = 100%).
#   RSS     /proc/PID/status 의 VmRSS (MB = kB / 1024)
#   MEM%    RSS ÷ 메모리 한도 × 100. 한도는 /sys/fs/cgroup/memory.max 가 숫자이면 그 값
#           (컨테이너의 cgroup 한도), 아니면 /proc/meminfo 의 MemTotal 이다.
#           컨테이너 안의 MemTotal 은 호스트 전체 메모리라서 그대로 쓰면 증가가 0.x%로 묻힌다.
#   THREADS /proc/PID/status 의 Threads
#   STATE   /proc/PID/stat 의 3번째 필드 (R 실행, S 대기, D 디스크 대기, Z 좀비, T 정지)
#   LOG_AGE 현재 시각 - APP_LOG 의 마지막 수정 시각(stat -c %Y)
set -u
export LC_ALL=C

PATTERN=agent-leak-app
INTERVAL=5
LOG_FILE="${AGENT_LOG_DIR:-/var/log/agent-app}/monitor.log"
APP_LOG=""
COUNT=0

usage() { sed -n '4,11p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        -p) PATTERN="$2"; shift 2 ;;
        -i) INTERVAL="$2"; shift 2 ;;
        -o) LOG_FILE="$2"; shift 2 ;;
        -l) APP_LOG="$2"; shift 2 ;;
        -n) COUNT="$2"; shift 2 ;;
        --once) COUNT=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "monitor.sh: 알 수 없는 옵션: $1" >&2; usage >&2; exit 2 ;;
    esac
done

CLK_TCK=$(getconf CLK_TCK)

# 메모리 한도(바이트): cgroup memory.max 가 숫자이면 그 값, 아니면 MemTotal
mem_limit_bytes() {
    local v
    v=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || true)
    if [[ $v =~ ^[0-9]+$ ]]; then
        MEM_LIMIT=$v
    else
        MEM_LIMIT=$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) * 1024 ))
    fi
}
mem_limit_bytes

# /proc/PID/stat 을 읽어 STAT_STATE, STAT_PPID, STAT_TICKS(utime+stime), STAT_START 를 채운다.
# comm(2번째 필드)에 공백·괄호가 들어갈 수 있으므로 마지막 ')' 뒤부터 나눈다.
read_stat() {
    local raw rest
    { read -r raw < "/proc/$1/stat"; } 2>/dev/null || return 1
    [ -n "$raw" ] || return 1
    rest=${raw##*) }
    # rest[0]=3번 state, rest[1]=4번 ppid, rest[11]=14번 utime, rest[12]=15번 stime, rest[19]=22번 starttime
    read -r -a F <<<"$rest"
    STAT_STATE=${F[0]}
    STAT_PPID=${F[1]}
    STAT_TICKS=$(( F[11] + F[12] ))
    STAT_START=${F[19]}
}

# 패턴과 맞는 프로세스 중 "실제 일을 하는" 가장 오래된 것을 TARGET 에 넣는다. 없으면 빈 값.
#  - monitor 자신($$)과 명령 치환으로 생긴 하위 셸(부모가 $$)은 명령줄에 패턴이 들어 있을 수 있어 뺀다.
#  - 후보의 부모도 후보이면 부모를 뺀다. agent-leak-app 은 같은 명령줄의 런처(부모)와
#    워커(자식) 2개로 뜨고, 메모리·CPU·스레드는 워커에만 나타난다(탐색 실행에서 ps로 확인).
find_target() {
    local p best="" best_start=""
    local -a cand=() start=() parents=()
    TARGET=""
    for p in $(pgrep -f -- "$PATTERN"); do
        [ "$p" = "$$" ] && continue
        read_stat "$p" || continue
        [ "$STAT_PPID" = "$$" ] && continue
        cand+=("$p"); start+=("$STAT_START"); parents+=("$STAT_PPID")
    done
    local i j is_parent
    for i in "${!cand[@]}"; do
        is_parent=0
        for j in "${!cand[@]}"; do
            [ "${parents[$j]}" = "${cand[$i]}" ] && { is_parent=1; break; }
        done
        [ "$is_parent" = 1 ] && continue
        if [ -z "$best" ] || [ "${start[$i]}" -lt "$best_start" ]; then
            best=${cand[$i]}; best_start=${start[$i]}
        fi
    done
    TARGET=$best
}

now_ts() { printf '%(%Y-%m-%d %H:%M:%S)T' -1; }

PREV_PID=""
PREV_TICKS=0
PREV_TIME=""

sample() {
    local ts rss_kb threads age cpu_line t_now
    find_target
    if [ -z "$TARGET" ]; then
        PREV_PID=""
        printf '[%s] PID:- STATUS:NOT_RUNNING\n' "$(now_ts)" >> "$LOG_FILE"
        return 0
    fi

    # 첫 샘플(또는 대상 PID가 바뀐 경우)은 0.5초 간격으로 두 번 읽어 구간 CPU를 만든다.
    if [ "$TARGET" != "$PREV_PID" ]; then
        read_stat "$TARGET" || { PREV_PID=""; printf '[%s] PID:- STATUS:NOT_RUNNING\n' "$(now_ts)" >> "$LOG_FILE"; return 0; }
        PREV_TICKS=$STAT_TICKS; PREV_TIME=$EPOCHREALTIME
        sleep 0.5
    fi
    if ! read_stat "$TARGET"; then
        PREV_PID=""
        printf '[%s] PID:- STATUS:NOT_RUNNING\n' "$(now_ts)" >> "$LOG_FILE"
        return 0
    fi
    t_now=$EPOCHREALTIME
    ts=$(now_ts)

    rss_kb=$(awk '/^VmRSS:/ {print $2}' "/proc/$TARGET/status" 2>/dev/null)
    threads=$(awk '/^Threads:/ {print $2}' "/proc/$TARGET/status" 2>/dev/null)
    rss_kb=${rss_kb:-0}; threads=${threads:-0}

    age="-"
    if [ -n "$APP_LOG" ] && [ -e "$APP_LOG" ]; then
        age="$(( $(printf '%(%s)T' -1) - $(stat -c %Y "$APP_LOG") ))s"
    fi

    cpu_line=$(awk -v d="$(( STAT_TICKS - PREV_TICKS ))" -v hz="$CLK_TCK" \
                   -v t0="$PREV_TIME" -v t1="$t_now" -v rss="$rss_kb" -v lim="$MEM_LIMIT" 'BEGIN {
        el = t1 - t0; if (el <= 0) el = 0.001
        cpu = d / hz / el * 100; if (cpu < 0) cpu = 0
        printf "CPU:%.1f%% MEM:%.1f%% RSS:%.1fMB", cpu, rss * 1024 / lim * 100, rss / 1024
    }')

    printf '[%s] PID:%s %s THREADS:%s STATE:%s LOG_AGE:%s\n' \
        "$ts" "$TARGET" "$cpu_line" "$threads" "$STAT_STATE" "$age" >> "$LOG_FILE"

    PREV_PID=$TARGET; PREV_TICKS=$STAT_TICKS; PREV_TIME=$t_now
}

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
n=0
while :; do
    sample
    n=$((n + 1))
    if [ "$COUNT" -gt 0 ] && [ "$n" -ge "$COUNT" ]; then
        break
    fi
    sleep "$INTERVAL"
done
exit 0
