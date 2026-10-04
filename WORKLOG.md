# b4-2 작업 기록 — 시도 / 결과 / 판단

> 시간순 기록이다. 모든 시각은 KST(호스트·컨테이너 동일)이며, 인용한 출력은 `evidence/` 파일에 그대로 있다.

## 0. 자료 준비

| 시도 | 결과 | 판단 |
|---|---|---|
| `gh api repos/MetaStudy999/codyssey-basic-system-troubleshooting/contents/agent-app-leak.zip -H "Accept: application/vnd.github.raw"` | 12,589,269 바이트 수신(목록 API 의 size 와 일치). sha256 `249c9c28…6641` | contents API 의 raw 미디어 타입으로 바로 받았다. curl 대체 경로는 필요 없었다 |
| `unzip -l` | 아래 출력 (`evidence/00-explore/data-file.txt`) | `__MACOSX/._*` 는 macOS 메타데이터라 풀지 않았다 |
| `file .runtime/agent-leak-app-arm64` | `ELF 64-bit LSB executable, ARM aarch64 … stripped` | 호스트가 aarch64 이므로 arm64 바이너리를 쓴다 |

```
Archive:  questions/agent-app-leak.zip
  Length      Date    Time    Name
---------  ---------- -----   ----
  6261928  2026-05-26 11:04   agent-leak-app-arm64
      194  2026-05-26 11:04   __MACOSX/._agent-leak-app-arm64
  6502016  2026-05-26 11:00   agent-leak-app-x86
      194  2026-05-26 11:00   __MACOSX/._agent-leak-app-x86
---------                     -------
 12764332                     4 files
```

zip 은 `../questions/` 에만 두고, 압축을 푼 바이너리는 `.runtime/`(gitignore)에 둔다. 저장소에는 들어가지 않는다.

## 1. 실행 환경

- 이미지 `b4-2-lab:latest` = ubuntu:24.04 + procps, psmisc, sysstat, iproute2, ca-certificates, **tzdata**(`TZ=Asia/Seoul`).
  - tzdata 를 추가한 이유: 앱 로그·monitor.log·run-case.sh 가 쓰는 시각을 같은 시간대로 맞춰야 같은 시간축으로 비교할 수 있다.
- 컨테이너: `--init --cpus=2 --memory=2g --pids-limit=512 --network none`.
  - `--init`: 앱이 고아가 되어 PID 1(sleep)에 붙으면 좀비로 남아 monitor 가 계속 "살아 있음"으로 볼 수 있다. tini 가 거둬 준다.
  - `--network none`: 앱은 0.0.0.0:15034 바인딩만 확인한다(부트 4단계). 외부 통신이 필요 없으므로 네트워크를 끊어 격리를 강화했다. 부트는 그대로 통과했다.

## 2. 탐색 실행 1 — 부트 확인

| 시각 | 시도 | 결과 | 판단 |
|---|---|---|---|
| 04:37:31 | 기본값 `env/agent.env`, `agent` 사용자, `timeout 60` | 6단계 모두 `[OK]`, `Agent READY`. 이후 Heap 이 3초마다 25MB 증가 → 04:38:03 `Memory limit exceeded (275MB >= 256MB)` → `Self-terminating process 22` → exit 137 (`boot.txt`) | 첫 시도에 부트 성공. 미션 표의 `AGENT_KEY_PATH` 는 디렉터리 경로가 맞았다 |
| 04:38:28 | root 로 실행 | `[1/6] Checking User Account [FAIL]` `Running as 'root' is forbidden.` → `System Boot Failed`, exit 1 (`boot-fail-root.txt`) | 반드시 `-u agent` 로 실행해야 한다 |
| 04:38:28 | `MEMORY_LIMIT=600` | `[6/6] … [FAIL] MEMORY_LIMIT too high (600MB). Maximum: 512MB` (`boot-fail-memlimit-range.txt`) | 실험값은 50~512 안에서 고른다 |
| 04:38:29 | `AGENT_KEY_PATH=…/no_such_dir` | `[2/6] … [FAIL] Key Path Mismatch. Expected: /home/agent/agent-app/api_keys` (`boot-fail-keypath.txt`) | 경로 값 자체를 검사한다. 디렉터리여야 한다 |
| 04:38:35 | secret.key 내용을 `wrong_key` 로 변경(직후 원복) | `[3/6] … [FAIL] Invalid Content in secret.key (Expected: 'agent_api_key_test', Found: 'wrong_key')` (`boot-fail-wrong-key.txt`) | 키 파일 경로·내용 오류는 부트 단계에서 드러난다 |

**발견 1 — SELF-TERMINATED 줄이 없다.** 미션 문서는 `>>> [SYSTEM] SELF-TERMINATED (Memory Limit Exceeded) <<<` 를 말하지만 `boot.txt`(출력이 파이프)에는 없었다.
같은 조건을 `docker exec -t`(의사 터미널)로 다시 돌리자 `Self-terminating process 347 …` 다음 줄에 나타났다(`oom-256-tty.txt`).
판단: 이 줄은 stdout 으로 나가는데, 출력이 터미널이 아니면 블록 버퍼링되고, 프로세스가 곧바로 SIGKILL 로 죽어 버퍼가 비워지지 않는다.
조치: `env/launch.sh` 가 앱을 `script -q -f -e -c …`(의사 터미널) 안에서 실행하게 바꿨다. 이후 모든 실험의 app.log 에 이 줄이 남는다.
그 대신 셸이 출력하는 `Killed`/`Terminated` 줄과 `\r` 이 따라오므로, 회수할 때 `\r` 만 지운다.

**발견 2 — 프로세스가 2개다.** 04:38:45 경 `MEMORY_LIMIT=512` 로 띄운 앱을 `ps -eo pid,ppid,ni,stat,nlwp,rss,cmd` 로 보았다(이 출력은 터미널에서만 보고 파일로 남기지 않았다). PID 91(부모, nice 0, RSS 1,784 kB)과 PID 92(91 의 자식, nice 10, 스레드 3개, RSS 42,612 kB)가 같은 명령줄 `/opt/agent/agent-leak-app` 이었다.
같은 구조가 이후 모든 실행의 스냅샷에 남아 있다. 예: `evidence/00-explore/a-default/snapshots/044747-ps-ef.txt`, `044747-top.txt`:

```
agent         17      16  0 04:47 pts/0    00:00:00 /opt/agent/agent-leak-app
agent         31      17  0 04:47 pts/0    00:00:00 /opt/agent/agent-leak-app
     17 agent     20   0    2792   1780   1576 S   0.0   0.0   0:00.04 agent-l+
     31 agent     30  10   73552  67992   8648 S   0.0   0.1   0:00.05 agent-l+
```

같은 명령줄의 부모(런처, RES 1.7MB, NI 0)와 자식(워커, NI 10, RES 증가)이다. 앱 로그의 `Self-terminating process <PID>` 도 자식 PID 다(`a-default/app.log` 의 `Self-terminating process 31`).
계획의 `pgrep -f -o`(가장 오래된 것)는 부모를 고르므로 메모리 증가가 전혀 보이지 않게 된다. → 3장의 monitor 수정으로 이어졌다.

## 3. monitor.sh (TDD)

| 단계 | 결과 |
|---|---|
| 계획의 테스트 8개 작성 후 실행(구현 없음) | `PASS 0 / FAIL 8` (RED) → `test:` 커밋 |
| 1차 구현(구간 CPU, cgroup 기준 MEM%, LOG_AGE, 자기 자신 제외) | 호스트 `PASS 8 / FAIL 0` |
| 발견 2 를 반영한 테스트 `pick_worker` 추가(부모·자식이 같은 명령줄인 가짜 프로세스) | `FAIL pick_worker: parent=706870 child=706872 got: … PID:706870 CPU:0.0% …` (RED) |
| 후보의 부모도 후보이면 부모를 빼도록 수정 | 호스트 `PASS 9 / FAIL 0`, 컨테이너(`docker run --rm … b4-2-lab bash tests/test_monitor.sh`) `PASS 9 / FAIL 0` |

위 표의 RED 출력 두 개는 그때 터미널에서만 확인했다. 임시 저장해 둔 사본은 다른 작업과 같이 쓰는 scratchpad 에서 덮어써져 남지 않았다.
그래서 마지막에 test 커밋(3222902) 시점을 임시 작업 트리로 꺼내 다시 실행해 "구현 전" 상태를 재현해 두었다. 결과는 `PASS 0 / FAIL 9`, exit 1 이다(`evidence/tdd/red-at-test-commit.txt`). 이 커밋에는 `pick_worker` 가 이미 들어 있어서 9개다.
현재 GREEN 결과는 `evidence/tdd/green-host.txt`, `evidence/tdd/green-container.txt` 다.

중간에 겪은 함정:
- 테스트를 터미널 한 줄에서 `for … bash tests/test_monitor.sh` 와 함께 실행하자 `busy_cpu` 가 실패했다. 그 명령줄 문자열 자체에 `fake-busy-target` 이 들어 있어 `pgrep -f` 가 내 셸을 "가장 오래된 대상"으로 골랐기 때문이다.
  `pgrep -f` 는 명령줄 어디에든 패턴이 있으면 잡는다는 점을 확인했다.
  - 그래서 컨테이너 안에서 실행하는 보조 명령(`run-case.sh`의 생존 확인, `snapshot.sh`)은 앱 이름을 `agent-leak-ap[p]`, `[a]gent-leak-app` 처럼 써서 monitor 의 패턴에 걸리지 않게 했다.
- `ps -L … wchan` 이 root 로 실행하면 `-` 로만 나왔다. 같은 sleep 프로세스를 root 로 보면 `0`, agent 로 보면 `hrtimer_nanosleep` 이었다.
  Docker 기본 권한에는 CAP_SYS_PTRACE 가 없어서 다른 사용자의 wchan 이 가려진다. → `snapshot.sh` 를 `agent` 로 실행하도록 바꿨다.

## 4. 실험 실행기

`env/run-case.sh smoke t1 --timeout 30 --snap-every 10 MEMORY_LIMIT=512` 로 검증했다. summary.txt·app.log·monitor.log·exit.txt·agent-log/·snapshots/(4시점)가 생겼다. 끝난 뒤 `docker ps -a | grep b42-` 는 비어 있었다. 검증 후 `evidence/smoke/` 는 지웠다.

## 5. 탐색 실행 2 — 장애 발동 조건

| 실행 | 설정(MEM/CPU/MT) | 배너 경고 | 결과 |
|---|---|---|---|
| `a-default` | 256 / 50 / false | MEMORY `WARNING: Recommend Over 256MB` | 32초, `Memory limit exceeded` → `SELF-TERMINATED`, exit 137 |
| `b-multithread` | 256 / 50 / true | MEMORY 경고 + THREAD `WARNING`, `POTENTIAL DEADLOCK IN CONCURRENT MODE` | 그래도 32초에 OOM 으로 종료. Deadlock 은 나타나지 않음 |
| `c-cpu10` | 256 / 10 / false | MEMORY 경고, CPU `[ OK ]` | 32초 OOM |
| (수동) `manual-512-healthy.app.log` | 512 / 50 / false | 없음 | `Scenario Selected: [Healthy System Monitoring]`. Heap 525MB 에서 `Starting cleanup…` → `MEMORY RECOVERED`, CpuWorker 는 50%에서 cooldown. 2분 30초 뒤 내가 TERM 으로 멈춤 |
| `d-mem384` | 384 / 50 / false | 없음 | Healthy. 400MB 마다 cleanup, 300초 시간 초과까지 생존 |
| `b2-multithread-mem512` | 512 / 50 / true | THREAD 경고 | 시작 7초 뒤 `WAITING … (Status: BLOCKED)` 2줄을 끝으로 로그 정지, 420초 동안 CPU 0.0%·RSS 16.5MB 고정, 스레드 3개 `futex_wait_queue` |
| `probe-banner.txt` | 257, 300 / CPU 10~100 | 257·300 은 `[ OK ]`. CPU 51 이상부터 `WARNING: Recommend Under 50%` | 51~100 은 CpuWorker 가 `Maximum CPU Limit: <값>%` 로 시작 |
| `e-cpu80-mem512` | 512 / 80 / false | CPU 경고 | `Current Load` 5%→56.02% 상승, `CPU Threshold Violated! (56.02%)` → `WATCHDOG: INITIATING EMERGENCY ABORT (SIGTERM)`, 40초, exit 143 |

판단:
1. 앱은 시작할 때 설정으로 시나리오를 하나 고른다. 그래서 각 케이스에서 나머지 변수는 "경고 없음" 값으로 고정해야 한다. 특히 Deadlock·CPU 케이스는 `MEMORY_LIMIT=512` 로 고정한다. 256 이면 OOM 이 먼저 일어난다.
2. CPU 케이스의 방향이 계획과 반대였다. 낮은 값은 오히려 정상이고, **50 초과**가 와치독을 일으킨다. Before=80, After=50 으로 정했다.
3. `e-cpu80` 에서 앱이 보고한 Load 는 56%까지 올랐지만, OS 가 잰 실제 CPU 는 monitor 0.2~1.2%(기동 직후 첫 샘플 8.0% 제외), `top -H` 0.0%, `docker stats` 최대 1.43% 였다. 이 "CPU 급상승"은 앱 내부 지표다. 실제로 코어를 태우지는 않는다. 리포트에는 두 값을 나란히 적고 이 차이를 명시한다.
4. OOM 의 Heap 증가 속도는 3초당 25MB 로 일정했다. 그래서 같은 OOM 시나리오 안에서 128MB 와 256MB 를 비교하면 생존 시간이 한도에 비례하는지 볼 수 있다. 이것을 보조 실험으로 추가했다.

확정한 매트릭스는 PLAN.md 6.2.

## 6. 본 실험 (`env/run-matrix.sh oom deadlock cpu`, 09:13:24 ~ 09:39:59)

| 시각 | 실행 | 결과 | 메모 |
|---|---|---|---|
| 09:13:24~09:14:04 | oom before-1·2 (동시) | 둘 다 32초, exit 137, `SELF-TERMINATED` 줄 기록됨 | 워커 PID 24 / 31. launch.sh 수정이 효과를 냈다 |
| 09:14:04~09:14:32 | oom low128-1·2 (동시) | 둘 다 18초, `Memory limit exceeded (150MB >= 128MB)` | 생존 시간이 한도에 비례 |
| 09:14:32~09:19:43 | oom after-1·2 (동시) | 둘 다 300초 시간 제한까지 생존, cleanup 4회씩 | RSS 가 516.7MB 까지 올랐다가 정리 후 다시 오르는 톱니 모양 |
| 09:19:43~09:24:00 | deadlock before-1·2 (동시) | 기동 9초 뒤 로그 정지, 246초 동안 CPU 0.0%, 스레드 3개 `futex_wait_queue` | before-1 은 09:21 경 RSS 16.5→13.2MB. RssAnon 은 그대로, RssFile 만 감소(커널의 파일 페이지 회수) |
| 09:24:00~09:28:11 | deadlock after-1·2 (동시) | 241초 동안 로그 계속, LOG_AGE 최대 3초 | 워커 스레드 utime·stime 증가, wchan `do_select` |
| 09:28:11~09:29:39 | cpu before-1 → before-2 (단독, 순차) | 43초 / 34초, `CPU Threshold Violated!` → `WATCHDOG … (SIGTERM)`, exit 143 | OS 실측 CPU 는 0.0→2.0% 로 조금만 상승 |
| 09:29:39~09:39:59 | cpu after-1 → after-2 (단독, 순차) | 둘 다 300초 시간 제한까지 생존, `Peak reached (50.00%)` 5회씩 | WATCHDOG 0건 |

실험 중 b42-* 컨테이너는 항상 2개 이하였다. 각 실행이 끝날 때 `run-case.sh` 의 trap 이 컨테이너를 지웠다.

## 7. 작업 중단과 재개

- 04:57 이후 작업 세션이 API 사용 한도로 끊겼다가 09:13 에 다시 이어졌다. 탐색 증거(`evidence/00-explore/`)는 그대로 재사용했다.
- 본 실험 뒤 세션이 한 번 더 끊겼다(09:40 이후). 재개 후 20개 실행 폴더 전부를 점검했다. 모두 summary·app.log·monitor.log·exit.txt·agent-log·snapshots 가 있었고, monitor.log 마지막 줄이 `NOT_RUNNING` 이었다. 중간에 끊긴 실행이 없어 다시 돌리지 않았다.

## 8. 실험 후 정리

| 시도 | 결과 | 판단 |
|---|---|---|
| `koalaman/shellcheck:stable` 로 스크립트 검사 | monitor.sh 의 쓰이지 않는 변수(SC2034), run-matrix.sh 의 `cd` 실패 미처리(SC2164), run-case.sh 의 `ls \| grep`(SC2010) 지적 | 셋 다 고쳤다. `snapshot.sh` 의 `ps -ef \| grep`(SC2009)은 미션이 요구하는 증거 형식이라 그대로 두었다 |
| 고친 뒤 재검증 | 호스트·컨테이너 테스트 `PASS 9 / FAIL 0`, `run-case.sh smoke t2 --timeout 15` 정상(summary 생성, 컨테이너 남지 않음) | 검증용 `evidence/smoke/` 는 지웠다 |
