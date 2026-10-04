#!/usr/bin/env bash
# 컨테이너 안에서 agent 사용자로 앱을 실행하고 종료 코드를 남긴다.
#
# - 앱을 의사 터미널(script) 안에서 실행한다. 출력이 파일(파이프)이면 앱의 stdout 이 블록 버퍼링되어
#   자체 SIGKILL 직전에 출력한 ">>> [SYSTEM] SELF-TERMINATED ..." 같은 줄이 사라진다
#   (탐색 실행 evidence/00-explore/boot.txt 와 oom-256-tty.txt 비교).
# - 바이너리 경로를 인자로 받지 않아 이 래퍼(bash launch.sh) 자신의 명령줄에는 앱 이름이 없다.
#   다만 그 아래의 script·sh -c 는 명령줄에 앱 경로가 들어가 monitor.sh 의 pgrep -f 에 걸린다.
#   이들과 런처를 실제로 걸러 내는 것은 monitor.sh 의 리프 선택(자식도 패턴과 맞는 부모는 제외)이다.
# - 종료 코드가 128+N 이면 시그널 N 으로 끝났다는 뜻이다(143=SIGTERM, 137=SIGKILL).
RUN_DIR=${RUN_DIR:-/home/agent/run}
BIN=/opt/agent/agent-leak-$(printf app)
script -q -f -e -c "$BIN" /dev/null < /dev/null > "$RUN_DIR/app.raw.log" 2>&1
rc=$?
printf 'exit_code=%s ended_at=%s\n' "$rc" "$(date '+%Y-%m-%d %H:%M:%S')" > "$RUN_DIR/exit.txt"
