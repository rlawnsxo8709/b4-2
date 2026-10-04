#!/usr/bin/env bash
# 장애 재현 실행 1회 = 새 컨테이너 1개. 앱과 monitor.sh 를 함께 돌리고 증거를 회수한다.
#
# 사용법:
#   env/run-case.sh <case> <label> [--timeout SEC] [--snap-every SEC] [KEY=VALUE ...]
#   예) env/run-case.sh oom before-1 --timeout 300 MEMORY_LIMIT=256
#
#   --timeout SEC     이 시간이 지나도 살아 있으면 "생존 중 중단"으로 기록하고 TERM → 5초 뒤 KILL (기본 600)
#   --snap-every SEC  시스템 도구 스냅샷 간격 (기본 30)
#   KEY=VALUE         env/agent.env 의 값을 이 실행에서만 덮어쓴다
#
# 결과: evidence/<case>/<label>/
#   env.txt       이 실행에 실제로 넘긴 환경변수
#   app.log       앱 stdout+stderr (의사 터미널로 받은 출력, \r 제거)
#   monitor.log   monitor.sh -i 5 기록
#   exit.txt      종료 코드와 종료 시각 (launch.sh 가 기록)
#   agent-log/    앱 자체 로그 디렉터리($AGENT_LOG_DIR) 사본
#   snapshots/    HHMMSS-*.txt (ps -ef, ps -L, top -H, top, /proc status, task stat·wchan, docker stats)
#   summary.txt   생존 시간, 종료 원인, PID, 피크 RSS·CPU, 핵심 로그, 앱 로그 마지막 15줄
#
# 호스트 보호: --cpus=2 --memory=2g --pids-limit=512 --network none, b42-* 컨테이너 동시 2개까지.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE=b4-2-lab:latest
BIN="$ROOT/.runtime/agent-leak-app-arm64"
RUN=/home/agent/run

usage() { sed -n '4,10p' "$0" | sed 's/^# \{0,1\}//'; }
[ $# -ge 2 ] || { usage >&2; exit 2; }
CMDLINE="env/run-case.sh $*"
CASE=$1; LABEL=$2; shift 2
TIMEOUT=600; SNAP_EVERY=30; OVERRIDES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --timeout) TIMEOUT=$2; shift 2 ;;
        --snap-every) SNAP_EVERY=$2; shift 2 ;;
        *=*) OVERRIDES+=("$1"); shift ;;
        *) echo "run-case.sh: 알 수 없는 인자: $1" >&2; usage >&2; exit 2 ;;
    esac
done

EV="$ROOT/evidence/$CASE/$LABEL"
NAME="b42-$CASE-$LABEL"
[ -x "$BIN" ] || { echo "바이너리가 없습니다: $BIN (questions/agent-app-leak.zip 을 .runtime/ 에 풀어 주세요)" >&2; exit 1; }
[ -e "$EV" ] && { echo "이미 있는 증거 폴더입니다: $EV (지운 뒤 다시 실행)" >&2; exit 1; }
if [ "$(docker ps -q --filter name=^b42- | wc -l)" -ge 2 ]; then
    echo "b42-* 컨테이너가 이미 2개 실행 중입니다. 끝난 뒤 다시 실행하세요." >&2; exit 1
fi

mkdir -p "$EV/snapshots"
ENVF="$EV/env.txt"
cp "$ROOT/env/agent.env" "$ENVF"
for kv in "${OVERRIDES[@]}"; do
    k=${kv%%=*}
    if grep -q "^$k=" "$ENVF"; then sed -i "s|^$k=.*|$kv|" "$ENVF"; else echo "$kv" >> "$ENVF"; fi
done

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1; }
trap cleanup EXIT
trap 'echo "중단됨"; exit 130' INT TERM

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
dx() { docker exec "$NAME" "$@"; }

# 앱은 같은 이름의 런처(부모)와 워커(자식)로 뜬다. "워커 런처" 를 출력한다(워커가 아직 없으면 런처만).
# pgrep 정규식을 'agent-leak-ap[p]' 로 쓰는 이유: 이 명령줄이 monitor.sh 의 pgrep -f 패턴과 맞지 않게 하려고.
app_pids() {
    # shellcheck disable=SC2016  # 작은따옴표 안의 $(...) 는 컨테이너 안 bash 가 펼친다
    dx bash -c 'L=" $(pgrep -x "agent-leak-ap[p]" | tr "\n" " ")"
        for p in $L; do pp=$(ps -o ppid= -p "$p" | tr -d " ")
            case "$L" in *" $pp "*) echo "$p $pp"; exit 0 ;; esac; done
        set -- $L; [ $# -gt 0 ] && echo "$1 -"; true'
}

snapshot() {
    local w; w=$(app_pids | awk '{print $1}')
    [ -n "$w" ] || return 0
    # agent 로 실행해야 /proc/PID/wchan 이 보인다(root 는 CAP_SYS_PTRACE 가 없어 0 으로 가려짐)
    docker exec -u agent "$NAME" snapshot.sh "$RUN/snapshots" "$w" >/dev/null 2>&1
    { printf '# %s\n$ docker stats --no-stream %s   (호스트에서 본 컨테이너 전체 사용량)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$NAME"
      docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.PIDs}}' "$NAME"
    } > "$EV/snapshots/$(date +%H%M%S)-docker-stats.txt" 2>&1
}

log "컨테이너 $NAME 시작 (overrides: ${OVERRIDES[*]:-없음})"
docker run -d --init --name "$NAME" --hostname "$NAME" \
    --cpus=2 --memory=2g --pids-limit=512 --network none \
    -v "$BIN:/opt/agent/agent-leak-app:ro" "$IMAGE" >/dev/null || exit 1

START_EPOCH=$(date +%s); START_TS=$(date -d "@$START_EPOCH" '+%Y-%m-%d %H:%M:%S')
docker exec -d -u agent --env-file "$ENVF" "$NAME" bash /usr/local/bin/launch.sh
docker exec -d -u agent "$NAME" monitor.sh -i 5 -l "$RUN/app.raw.log" -o "$RUN/monitor.log"

WORKER=""; LAUNCHER=""; END_REASON=""; LAST_SNAP=-1000
while :; do
    sleep 5
    el=$(( $(date +%s) - START_EPOCH ))
    if dx test -f "$RUN/exit.txt"; then END_REASON=exited; break; fi
    if [ -z "$WORKER" ] || [ "$LAUNCHER" = "-" ]; then
        read -r WORKER LAUNCHER <<<"$(app_pids)"
        [ -n "$WORKER" ] && log "앱 PID: worker=$WORKER launcher=$LAUNCHER"
    fi
    if [ $(( el - LAST_SNAP )) -ge "$SNAP_EVERY" ]; then snapshot; LAST_SNAP=$el; fi
    if [ "$el" -ge "$TIMEOUT" ]; then
        log "시간 초과(${TIMEOUT}s): 생존 중 중단"
        snapshot
        END_REASON=timeout
        w=$(app_pids | awk '{print $1}')
        [ -n "$w" ] && dx kill -TERM "$w"
        for _ in 1 2 3 4 5; do dx test -f "$RUN/exit.txt" && break; sleep 1; done
        if ! dx test -f "$RUN/exit.txt"; then
            log "TERM 후 5초 동안 종료되지 않음 → KILL"
            dx pkill -KILL -x 'agent-leak-ap[p]'
            for _ in 1 2 3 4 5; do dx test -f "$RUN/exit.txt" && break; sleep 1; done
        fi
        break
    fi
done
log "앱 종료 감지 (${END_REASON})"

# monitor 가 "앱 PID 를 기록한 뒤의" NOT_RUNNING 을 최소 1줄 남길 때까지 기다린 뒤 멈춘다(최대 15초).
# 앱이 뜨기 전에 찍힌 이른 NOT_RUNNING 은 종료 증거가 아니므로 인정하지 않는다.
for _ in $(seq 1 15); do
    dx awk '/PID:[0-9]/ { seen = 1 } seen && /NOT_RUNNING/ { ok = 1 } END { exit !ok }' "$RUN/monitor.log" 2>/dev/null && break
    sleep 1
done
dx pkill -f monitor.sh

# 회수
docker cp -q "$NAME:$RUN/app.raw.log" "$EV/app.raw.log" 2>/dev/null && tr -d '\r' < "$EV/app.raw.log" > "$EV/app.log" && rm -f "$EV/app.raw.log"
docker cp -q "$NAME:$RUN/monitor.log" "$EV/monitor.log" 2>/dev/null
docker cp -q "$NAME:$RUN/exit.txt" "$EV/exit.txt" 2>/dev/null
mkdir -p "$EV/agent-log"; docker cp -q "$NAME:/var/log/agent-app/." "$EV/agent-log/" 2>/dev/null
dx test -d "$RUN/snapshots" && docker cp -q "$NAME:$RUN/snapshots/." "$EV/snapshots/" 2>/dev/null

# summary.txt
EXIT_CODE=$(sed -n 's/^exit_code=\([0-9]*\).*/\1/p' "$EV/exit.txt" 2>/dev/null)
END_TS=$(sed -n 's/.*ended_at=\(.*\)$/\1/p' "$EV/exit.txt" 2>/dev/null)
[ -n "$END_TS" ] || END_TS=$(date '+%Y-%m-%d %H:%M:%S')
SURVIVAL=$(( $(date -d "$END_TS" +%s) - START_EPOCH ))
case "$EXIT_CODE" in
    137) SIG="SIGKILL" ;; 143) SIG="SIGTERM" ;; 0) SIG="정상 종료" ;; "") SIG="알 수 없음" ;; *) SIG="exit $EXIT_CODE" ;;
esac
if [ "$END_REASON" = timeout ]; then
    CAUSE="시간 초과 중단(생존 중 중단, --timeout ${TIMEOUT}s) → exit_code=${EXIT_CODE:-?} ($SIG, run-case.sh 가 보냄)"
else
    CAUSE="자체 종료 → exit_code=${EXIT_CODE:-?} ($SIG)"
fi
# 워커 PID 를 못 잡았으면 monitor.log 에 가장 많이 기록된 PID 를 쓴다(첫 줄은 런처일 수 있다).
[ -n "$WORKER" ] || WORKER=$(awk '/PID:[0-9]/ { c[$3]++ } END { for (k in c) if (c[k] > m) { m = c[k]; b = k } sub(/PID:/, "", b); print b }' "$EV/monitor.log" 2>/dev/null)

peak() { # $1 = 필드 이름(RSS|CPU), 워커 PID 샘플 중 최댓값과 그 시각
    # 기동 직후 첫 샘플은 런처(부모)일 수 있으므로 워커 PID 줄만 본다.
    awk -v f="$1" -v w="${WORKER:+PID:$WORKER}" '
        /PID:[0-9]/ && (w == "" || $3 == w) { for (i = 1; i <= NF; i++) if (index($i, f ":") == 1) {
            v = $i; sub(f ":", "", v); sub(/[%MB]+$/, "", v)
            if (v + 0 > max + 0 || n == 0) { max = v; at = $1 " " $2 } n++ } }
        END { if (n) printf "%s (%s)", max, at; else printf "-" }' "$EV/monitor.log" 2>/dev/null
}

{
    echo "case:          $CASE"
    echo "label:         $LABEL"
    echo "command:       $CMDLINE"
    echo "overrides:     ${OVERRIDES[*]:-없음}"
    echo "container:     $NAME (--cpus=2 --memory=2g --pids-limit=512 --network none, image $IMAGE)"
    echo "started_at:    $START_TS"
    echo "ended_at:      $END_TS"
    echo "survival_sec:  $SURVIVAL"
    echo "end_cause:     $CAUSE"
    echo "pid:           worker=${WORKER:-?} launcher=${LAUNCHER:-?}"
    echo "peak_rss_mb:   $(peak RSS)"
    echo "peak_cpu_pct:  $(peak CPU)"
    echo "monitor_lines: $(grep -c . "$EV/monitor.log" 2>/dev/null || echo 0)"
    echo "snapshots:     $(find "$EV/snapshots" -name '*-ps-ef.txt' | wc -l) 시점 (snapshots/*-ps-ef.txt 기준)"
    echo
    echo "--- env.txt"
    cat "$ENVF"
    echo
    echo "--- 핵심 로그 (grep -nE 'Scenario|Memory limit|Self-terminat|SELF-TERMINATED|WATCHDOG|BLOCKED|WAITING|Deadlock|RECOVERED' app.log)"
    grep -nE 'Scenario|Memory limit|Self-terminat|SELF-TERMINATED|WATCHDOG|BLOCKED|WAITING|Deadlock|RECOVERED' "$EV/app.log" 2>/dev/null | head -30
    echo
    echo "--- app.log 마지막 15줄"
    tail -n 15 "$EV/app.log" 2>/dev/null
} > "$EV/summary.txt"

log "증거: ${EV#"$ROOT"/}  생존 ${SURVIVAL}s  $CAUSE"
