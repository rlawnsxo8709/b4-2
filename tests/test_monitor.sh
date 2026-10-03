#!/usr/bin/env bash
set -u; cd "$(dirname "$0")/.."; PASS=0; FAIL=0; TMP=$(mktemp -d); trap 'kill $BUSY $IDLE 2>/dev/null; [ -n "${PAIR:-}" ] && { pkill -P "$PAIR"; kill "$PAIR"; } 2>/dev/null; rm -rf "$TMP"' EXIT
ok(){ PASS=$((PASS+1)); echo "PASS $1"; }; ng(){ FAIL=$((FAIL+1)); echo "FAIL $1: $2"; }
LINE='^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] PID:[0-9]+ CPU:[0-9]+\.[0-9]% MEM:[0-9]+\.[0-9]% RSS:[0-9]+\.[0-9]MB THREADS:[0-9]+ STATE:[A-Z] LOG_AGE:([0-9]+s|-)$'
# 1) 바쁜 프로세스: CPU가 높게 잡혀야 함
bash -c 'exec -a fake-busy-target bash -c "while :; do :; done"' & BUSY=$!
sleep 1; bash monitor.sh -p fake-busy-target -o "$TMP/m.log" --once
L=$(tail -n1 "$TMP/m.log")
[[ $L =~ $LINE ]] && ok format || ng format "$L"
CPU=$(sed -E 's/.*CPU:([0-9]+)\..*/\1/' <<<"$L"); [ "$CPU" -ge 50 ] && ok busy_cpu || ng busy_cpu "$CPU"
# 2) 유휴 프로세스: CPU 낮음, 앱 로그 나이 기록
touch -d '-30 seconds' "$TMP/app.log"
bash -c 'exec -a fake-idle-target sleep 300' & IDLE=$!
sleep 0.5; bash monitor.sh -p fake-idle-target -o "$TMP/m.log" -l "$TMP/app.log" --once
L=$(tail -n1 "$TMP/m.log"); CPU=$(sed -E 's/.*CPU:([0-9]+)\..*/\1/' <<<"$L")
[ "$CPU" -le 5 ] && ok idle_cpu || ng idle_cpu "$CPU"
AGE=$(sed -E 's/.*LOG_AGE:([0-9]+)s/\1/' <<<"$L"); [ "$AGE" -ge 29 ] && ok log_age || ng log_age "$L"
# 3) 대상 없음: NOT_RUNNING 기록, 종료 코드 0, 누적(>>) 확인
bash monitor.sh -p no-such-process-xyz -o "$TMP/m.log" --once; RC=$?
tail -n1 "$TMP/m.log" | grep -qE '^\[.*\] PID:- STATUS:NOT_RUNNING$' && ok not_running || ng not_running "$(tail -n1 "$TMP/m.log")"
[ $RC -eq 0 ] && ok rc0 || ng rc0 $RC
[ "$(wc -l < "$TMP/m.log")" -eq 3 ] && ok append || ng append "$(wc -l < "$TMP/m.log")"
# 4) -n COUNT 반복
bash monitor.sh -p fake-idle-target -o "$TMP/n.log" -i 1 -n 3; [ "$(wc -l < "$TMP/n.log")" -eq 3 ] && ok count || ng count "$(wc -l < "$TMP/n.log")"
# 5) 런처(부모)와 워커(자식)가 같은 명령줄일 때: 실제 일을 하는 자식을 골라야 함
#    (탐색 실행에서 agent-leak-app 이 부모 1개 + 자식 1개로 뜨고, 자식만 메모리·CPU를 쓰는 것을 확인함)
bash -c 'exec -a fake-pair-target bash -c "(exec -a fake-pair-target bash -c \"while :; do :; done\") & wait"' & PAIR=$!
sleep 1; CHILD=$(pgrep -P "$PAIR" -f fake-pair-target)
bash monitor.sh -p fake-pair-target -o "$TMP/p.log" --once
L=$(tail -n1 "$TMP/p.log"); P=$(sed -E 's/.*PID:([0-9]+) .*/\1/' <<<"$L")
[ "$P" = "$CHILD" ] && ok pick_worker || ng pick_worker "parent=$PAIR child=$CHILD got: $L"
pkill -P "$PAIR" 2>/dev/null; kill "$PAIR" 2>/dev/null
echo "PASS $PASS / FAIL $FAIL"; [ $FAIL -eq 0 ]
