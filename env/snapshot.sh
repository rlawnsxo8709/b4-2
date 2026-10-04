#!/usr/bin/env bash
# 컨테이너 안에서 대상 PID 의 시스템 도구 출력을 한 시점에 모아 파일로 남긴다.
# 사용법: snapshot.sh <출력 디렉터리> <PID>
# 파일 이름 앞의 HHMMSS 가 같은 파일들은 같은 시점의 스냅샷이다.
#
# 명령줄에 앱 이름을 그대로 쓰지 않는다([a]gent... 형태). 그대로 쓰면 이 스냅샷 명령이
# 잠깐 동안 monitor.sh 의 pgrep -f 패턴과 맞는 프로세스가 된다.
set -u
OUT=$1; PID=$2
mkdir -p "$OUT"
TS=$(date +%H%M%S); NOW=$(date '+%Y-%m-%d %H:%M:%S')
hdr() { printf '# %s (PID %s)\n$ %s\n' "$NOW" "$PID" "$1"; }

{ hdr "ps -ef | grep agent-leak-app"; ps -ef | head -1; ps -ef | grep '[a]gent-leak-app'; } > "$OUT/$TS-ps-ef.txt"
{ hdr "ps -L -o pid,lwp,stat,pcpu,pmem,wchan:32,comm -p $PID"; ps -L -o pid,lwp,stat,pcpu,pmem,wchan:32,comm -p "$PID"; } > "$OUT/$TS-ps-L.txt"
{ hdr "top -H -b -n 1 -p $PID"; top -H -b -n 1 -p "$PID"; } > "$OUT/$TS-top-H.txt"
{ hdr "top -b -n 1 -o %CPU | head -15"; top -b -n 1 -o %CPU | head -15; } > "$OUT/$TS-top.txt"
{ hdr "cat /proc/$PID/status"; cat "/proc/$PID/status"; } > "$OUT/$TS-status.txt" 2>&1
{ hdr "grep . /proc/$PID/task/*/stat /proc/$PID/task/*/wchan"; grep . /proc/"$PID"/task/*/stat /proc/"$PID"/task/*/wchan; echo; } > "$OUT/$TS-task.txt" 2>&1
