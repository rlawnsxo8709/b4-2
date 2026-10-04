# agent-leak-app 장애 3종 분석 — OOM · CPU 과점유 · Deadlock (b4-2)

> 제공 바이너리 `agent-leak-app`(arm64)을 격리된 Docker 컨테이너에서 **실제로 실행**했다. 직접 만든 `monitor.sh` 와 리눅스 표준 도구(`ps`, `top`, `/proc`)로 증거를 모아, 장애 3종을 GitHub Issue 형식 리포트로 분석했다.
> 리포트의 PID·타임스탬프·로그·수치는 모두 `evidence/` 에 있는 실측값이다.

| | |
|---|---|
| 리포트 | [issues/01-oom.md](issues/01-oom.md) · [issues/02-cpu.md](issues/02-cpu.md) · [issues/03-deadlock.md](issues/03-deadlock.md) |
| 실행 환경 | Docker 29 · ubuntu:24.04 컨테이너 · 호스트 Linux aarch64 |
| 관제 스크립트 | [monitor.sh](monitor.sh) (Bash, `/proc` 기반) · 테스트 [tests/test_monitor.sh](tests/test_monitor.sh) |
| 실험 실행기 | [env/run-case.sh](env/run-case.sh) · [env/run-matrix.sh](env/run-matrix.sh) |

설계와 실험 매트릭스는 [PLAN.md](PLAN.md), 시행착오 기록은 [WORKLOG.md](WORKLOG.md), 과제 목표·평가 문항 답변은 [EXPLAIN.md](EXPLAIN.md)에 있다.

---

## 목차

1. [결과 요약](#결과-요약)
2. [실행 환경](#실행-환경)
3. [재현 방법](#재현-방법)
4. [monitor.sh 사용법](#monitorsh-사용법)
5. [증거 폴더 인덱스](#증거-폴더-인덱스)
6. [요구사항 체크리스트](#요구사항-체크리스트)
7. [관찰과 미션 설명이 다른 점](#관찰과-미션-설명이-다른-점)
8. [monitor.sh 개선 방향](#monitorsh-개선-방향)
9. [검증](#검증)
10. [폴더 구조](#폴더-구조)

---

## 결과 요약

케이스마다 변수 하나만 바꿔 Before 2회, After 2회 실행했다(2026-10-04 09:13~09:40).

| 케이스 | 변수 | Before | After | 핵심 증거 |
|---|---|---|---|---|
| **OOM** | `MEMORY_LIMIT` | 256 → **32초 / 32초** 만에 MemoryGuard 자체 종료(exit 137) | 512 → **303초 이상 / 303초 이상** 생존(시간 제한) | RSS 16.4→266.4MB, 8.0MB/s 선형 증가 · `Memory limit exceeded (275MB >= 256MB)` · `SELF-TERMINATED` |
| **CPU** | `CPU_MAX_OCCUPY` | 80 → **43초 / 34초** 만에 Watchdog 자체 종료(exit 143) | 50 → **305초 이상 / 305초 이상** 생존(시간 제한) | 앱 Load 5%→56.38% · `CPU Threshold Violated!` · `WATCHDOG: INITIATING EMERGENCY ABORT (SIGTERM)` |
| **Deadlock** | `MULTI_THREAD_ENABLE` | true → 기동 9초 뒤 로그 정지, **LOG_AGE 232초 / 237초까지 무응답**(PID 생존) | false → **241초 동안 정상 진행**, 로그 정지 최대 3초 | CPU 0.0% · 스레드 3개 `futex_wait_queue` · `WAITING for […] (Status: BLOCKED)` 순환 |

보조 실험: `MEMORY_LIMIT=128` 은 18초 / 18초. 누수 속도가 일정해서 한도가 클수록 생존 시간이 길어진다(절편이 있는 선형 관계라 정비례는 아니다).

## 실행 환경

| 항목 | 내용 |
|---|---|
| 이미지 | `b4-2-lab:latest` = ubuntu:24.04 + `procps psmisc sysstat iproute2 ca-certificates tzdata` ([env/Dockerfile](env/Dockerfile)) |
| 실행 계정 | `agent`(uid 1001). root 로 실행하면 부트 1단계에서 실패한다(`evidence/00-explore/boot-fail-root.txt`) |
| 앱 파일 | `/home/agent/agent-app/{upload_files/, api_keys/secret.key}`(내용 `agent_api_key_test`, 권한 600), 로그 `/var/log/agent-app` |
| 바이너리 | 이미지에 굽지 않는다. 실행할 때 `.runtime/agent-leak-app-arm64` 를 `/opt/agent/agent-leak-app` 에 읽기 전용으로 마운트한다 |
| 컨테이너 제한 | `--init --cpus=2 --memory=2g --pids-limit=512 --network none`. 같은 호스트의 다른 서비스를 보호하기 위해서다 |
| 동시 실행 | b42-* 컨테이너 최대 2개(run-case.sh 가 막는다). CPU 케이스는 단독·순차 |
| 시간대 | 컨테이너 `TZ=Asia/Seoul`. 앱 로그, monitor.log, summary 가 같은 시간축이다 |

기본 환경변수 [env/agent.env](env/agent.env):

```bash
AGENT_HOME=/home/agent/agent-app
AGENT_PORT=15034
AGENT_UPLOAD_DIR=/home/agent/agent-app/upload_files
AGENT_KEY_PATH=/home/agent/agent-app/api_keys      # 디렉터리 경로 (boot-fail-keypath.txt 로 확인)
AGENT_LOG_DIR=/var/log/agent-app
MEMORY_LIMIT=256
CPU_MAX_OCCUPY=50
MULTI_THREAD_ENABLE=false
```

## 재현 방법

```bash
# 0) 바이너리 준비 (zip 은 저장소 밖 questions/ 에 있다)
mkdir -p .runtime && unzip -o ../questions/agent-app-leak.zip agent-leak-app-arm64 -d .runtime
chmod +x .runtime/agent-leak-app-arm64

# 1) 이미지 빌드
bash env/build.sh

# 2) 실행 1회 = 컨테이너 1개. KEY=VALUE 로 env/agent.env 값을 덮어쓴다
env/run-case.sh oom before-1 --timeout 300 --snap-every 10 MEMORY_LIMIT=256 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=false
env/run-case.sh cpu before-1 --timeout 300 --snap-every 10 MEMORY_LIMIT=512 CPU_MAX_OCCUPY=80 MULTI_THREAD_ENABLE=false
env/run-case.sh deadlock before-1 --timeout 240 --snap-every 30 MEMORY_LIMIT=512 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=true

# 3) 전체 매트릭스(PLAN.md 6.2) 한 번에
env/run-matrix.sh              # 또는 env/run-matrix.sh oom / deadlock / cpu
```

`run-case.sh` 가 하는 일:
1. 컨테이너 `b42-<case>-<label>` 을 띄운다.
2. 앱을 `agent` 로 실행한다(`env/launch.sh`: 의사 터미널 안에서 실행, 종료 코드 기록).
3. 같은 컨테이너에서 `monitor.sh -i 5` 를 함께 돌린다.
4. 5초마다 생존을 확인하고, `--snap-every` 초마다 스냅샷을 찍는다.
5. 앱이 스스로 끝나면 "자체 종료", `--timeout` 을 넘기면 "생존 중 중단"(TERM → 5초 뒤 KILL)으로 기록한다.
6. 로그를 회수하고 `summary.txt` 를 쓴 뒤 컨테이너를 지운다(trap).

## monitor.sh 사용법

```bash
monitor.sh [-p PATTERN] [-i INTERVAL_SEC] [-o LOG_FILE] [-l APP_LOG] [-n COUNT] [--once]
#  -p  pgrep -f 패턴 (기본 agent-leak-app)        -i  샘플 간격 초 (기본 5)
#  -o  기록 파일, >> 누적 (기본 $AGENT_LOG_DIR/monitor.log)
#  -l  앱 로그 파일 → LOG_AGE        -n  COUNT 번 기록 후 종료        --once  1번만
```

출력 형식(한 줄 = 한 샘플):

```
[YYYY-MM-DD HH:MM:SS] PID:<pid> CPU:<x.x>% MEM:<x.x>% RSS:<x.x>MB THREADS:<n> STATE:<R|S|D|Z|T> LOG_AGE:<n>s
[YYYY-MM-DD HH:MM:SS] PID:- STATUS:NOT_RUNNING            ← 대상이 없을 때 (종료 시점 증거)
```

실제 예 (`evidence/oom/before-1/monitor.log`):

```
[2026-10-04 09:13:55] PID:24 CPU:0.2% MEM:13.0% RSS:266.4MB THREADS:1 STATE:S LOG_AGE:2s
[2026-10-04 09:14:00] PID:- STATUS:NOT_RUNNING
```

| 필드 | 출처 | 왜 이렇게 쟀나 |
|---|---|---|
| PID | `pgrep -f PATTERN` 중 monitor 자신·하위 셸과 "자식도 패턴과 맞는 부모"를 뺀 가장 오래된 것 | 앱은 같은 명령줄의 런처(부모)와 워커(자식)로 뜬다. 메모리·스레드는 워커에만 있다 |
| CPU | `/proc/PID/stat` 14·15번째 필드(utime+stime) 차분 ÷ `getconf CLK_TCK` ÷ 경과초 × 100. 첫 샘플은 0.5초 간격 두 번 읽기 | `ps -o %cpu` 는 생애 평균이라 급상승을 놓친다. 코어 1개를 다 쓰면 100% 다 |
| MEM | RSS ÷ **cgroup 한도**(`/sys/fs/cgroup/memory.max`, 숫자일 때) × 100. 아니면 `MemTotal` 기준 | 컨테이너 안 `MemTotal` 은 호스트 전체(약 119GiB)라서 증가가 0.x%로 묻힌다. 이 실험의 기준은 2GiB 다 |
| RSS | `/proc/PID/status` 의 `VmRSS` | 실제로 물리 메모리에 올라온 양 |
| THREADS | `/proc/PID/status` 의 `Threads` | 동시성 모드(스레드 3개)를 구분 |
| STATE | `/proc/PID/stat` 3번째 필드 | 교착 시 계속 `S` |
| LOG_AGE | 현재 시각 − `stat -c %Y APP_LOG` | "살아 있지만 멈춤"을 숫자로 보여 준다(교착 시 5초마다 5씩 증가) |

알려진 동작: 기동 직후 첫 샘플은 워커가 아직 뜨기 전이라 런처 PID 를 잡을 수 있다(예: `PID:17 … RSS:1.7MB`). 다음 샘플부터는 워커를 잡는다. 이 런처 샘플 때문에 이번 증거의 summary `peak_cpu_pct` 일부가 런처 값(2.0%)이 됐다. 지금의 run-case.sh 는 워커 PID 샘플만으로 피크를 계산한다.

## 증거 폴더 인덱스

`evidence/<case>/<label>/` 한 폴더 = 실행 1회.

| 파일 | 내용 |
|---|---|
| `summary.txt` | 명령줄, 덮어쓴 env, 시작·종료 시각, **생존 시간**, **종료 원인**(자체 종료/시간 초과 중단 + exit code), 워커·런처 PID, 피크 RSS·CPU, 핵심 로그 줄, 앱 로그 마지막 15줄. ※ 이번 증거의 `peak_cpu_pct` 는 런처의 첫 샘플을 포함해 계산된 경우가 있다(oom/before-2, low128-1·2, deadlock/before-1). 리포트의 CPU 수치는 monitor.log 에서 워커 PID 샘플만으로 다시 계산했다. 이후 실행용으로 run-case.sh 는 수정했다 |
| `app.log` | 앱 stdout+stderr (의사 터미널 출력, `\r` 제거) |
| `monitor.log` | monitor.sh 5초 간격 기록 |
| `exit.txt` | `exit_code=… ended_at=…` |
| `env.txt` | 이 실행에 넘긴 환경변수 전체 |
| `agent-log/agent_app.log` | 앱이 `AGENT_LOG_DIR` 에 직접 쓴 로그 |
| `snapshots/HHMMSS-*.txt` | 같은 시각의 `ps -ef \| grep`, `ps -L … wchan`, `top -H -b -n 1 -p`, `top -b -n 1`, `/proc/PID/status`, `/proc/PID/task/*/{stat,wchan}`, 호스트의 `docker stats` |

| 폴더 | 실행 |
|---|---|
| `evidence/00-explore/` | 자료 확인(`data-file.txt`), 부트 확인(`boot.txt`, `boot-fail-*.txt`), 버퍼링 확인(`oom-256-tty.txt`), 배너 탐침(`probe-banner.txt`), 탐색 실행 a~e, 수동 Healthy 실행 로그(`manual-512-healthy.app.log`) |
| `evidence/oom/` | `before-1·2`(256), `low128-1·2`(128, 보조), `after-1·2`(512) |
| `evidence/cpu/` | `before-1·2`(80), `after-1·2`(50) |
| `evidence/deadlock/` | `before-1·2`(true), `after-1·2`(false) |
| `evidence/tdd/` | monitor.sh 테스트 RED(test 커밋 시점 재실행)·GREEN(호스트·컨테이너) 출력 |

총량 4.7MB (`du -sh evidence`).

## 요구사항 체크리스트

**사전 준비 (미션 4-1)**

| 조건 | 충족 | 근거 |
|---|---|---|
| root 가 아닌 일반 사용자 | ✅ `agent`(uid 1001) | `boot.txt` `[1/6] … [OK] Running as service user 'agent' (uid=1001)` |
| 필수 환경변수·디렉터리·로그 권한·포트 | ✅ | `boot.txt` `[2/6]~[5/6] [OK]` |
| `MEMORY_LIMIT` 50~512, `CPU_MAX_OCCUPY` 10~100, `MULTI_THREAD_ENABLE` | ✅ | `boot.txt` `[6/6] … MEMORY_LIMIT=256MB, CPU_MAX_OCCUPY=50%, MULTI_THREAD_ENABLE=False`, 범위 밖은 `boot-fail-memlimit-range.txt` |
| secret.key 내용 `agent_api_key_test` | ✅ | `boot.txt` `Verified 'secret.key' with correct key string.` |

**케이스별 필수 증거 (미션 2-3)**

| 케이스 | 필수 증거 | 파일 | 리포트 위치 |
|---|---|---|---|
| OOM | monitor.sh 메모리 상승 수치 | `evidence/oom/before-1/monitor.log` (RSS 16.4→141.4→266.4MB) | 01-oom §2-1 |
| OOM | 종료 직전·직후 로그 `Memory limit exceeded…`, `SELF-TERMINATED…` | `evidence/oom/before-1/app.log` 41·42·45행 | 01-oom §2-3 |
| OOM | `MEMORY_LIMIT` 변경 전후 비교(최소 2회) | `evidence/oom/{before,after}-{1,2}/summary.txt` | 01-oom §4 |
| CPU | CPU 사용률 급상승 구간(top/ps/관제) | `evidence/cpu/before-1/app.log`(Load 13.30→56.38%), `monitor.log`, `snapshots/092851-top-H.txt` | 02-cpu §2-1·2-2 |
| CPU | 종료 로그 `WATCHDOG… SIGTERM` | `evidence/cpu/before-1/app.log` 45·47행 | 02-cpu §2-1 |
| CPU | `CPU_MAX_OCCUPY` 변경 전후 비교 | `evidence/cpu/{before,after}-{1,2}/summary.txt` | 02-cpu §4 |
| Deadlock | PID 존재 (`ps -ef \| grep …`) | `evidence/deadlock/before-1/snapshots/092332-ps-ef.txt` | 03-deadlock §2-1 |
| Deadlock | CPU/MEM 변화 정체 (`top -H`, `ps -L`) | `…/092332-top-H.txt`, `…/092332-ps-L.txt`, `monitor.log` | 03-deadlock §2-2·2-3 |
| Deadlock | 마지막 로그 지점 `WAITING… BLOCKED` | `evidence/deadlock/before-1/app.log` 41·42행 | 03-deadlock §2-4 |
| Deadlock | 스레드/락 대기 추론 근거 | hold/wait 표, 순환 그래프, `task/*/wchan` = `futex_wait_queue` | 03-deadlock §3 |

**리포트 형식 (미션 2-1·2-2)**

| 항목 | 충족 |
|---|---|
| 3건 모두 `# [Bug] {장애 유형} - {한 줄 요약}` | ✅ |
| `## 1. Description` → `## 2. Evidence & Logs` → `## 3. Root Cause Analysis` → `## 4. Workaround & Verification` | ✅ |
| PID·타임스탬프·핵심 로그 문구 발췌(파일 경로 포함) | ✅ |
| Before & After 표, OS 동작 원리, 근본 해결 제안 | ✅ |

## 관찰과 미션 설명이 다른 점

미션 문서·결과 예시와 실제 바이너리 동작이 다른 부분이다. 리포트에는 관찰한 대로 적었다.

1. **CPU 케이스의 방향.** 낮은 `CPU_MAX_OCCUPY` 가 와치독을 일으키는 것이 아니었다. **50 을 넘는 값**에서 `WARNING: Recommend Under 50%` 와 함께 와치독 동작이 선택되고, 50 이하로 낮추면 회피된다. 그래서 Before=80, After=50 이다.
2. **CPU "급상승"은 앱 내부 지표다.** 앱 로그의 `Current Load` 는 5%→56% 로 오르지만, 같은 시간 OS 가 잰 워커의 CPU 는 0.0→2.0%(monitor), `top -H` 0.0%, 누적 CPU 시간 0.41초(40초 동안)였다. 리포트에는 두 값을 나란히 적었다.
3. **OOM 의 After 는 "더 오래 버팀"이 아니라 "다른 대응".** 257MB 이상이면 앱이 `Healthy System Monitoring` 동작을 고른다. 이때는 한도에서 `Starting cleanup… MEMORY RECOVERED` 로 메모리를 비우고 계속 산다. 미션 예시처럼 "10분 → 30분"으로 종료가 늦춰지는 모양이 아니었다. 256MB 이하에서는 약 3초당 25MB 씩 늘어, 한도가 클수록 늦게 죽는다(128MB 18초, 256MB 32초. 선형이지만 정비례는 아니다).
4. **설정 우선순위.** `MEMORY_LIMIT≤256` 이면 `MULTI_THREAD_ENABLE=true` 여도 OOM 이 먼저 일어난다(`evidence/00-explore/b-multithread/`). 그래서 CPU·Deadlock 케이스는 `MEMORY_LIMIT=512` 로 고정했다.
5. **`SELF-TERMINATED` 줄은 터미널에서만 보인다.** 출력을 파일로 보내면 SIGKILL 직전의 stdout 버퍼가 비워지지 않아 이 줄이 사라진다(`boot.txt` vs `oom-256-tty.txt`). 그래서 run-case.sh 는 앱을 의사 터미널(`script`) 안에서 실행한다.
6. **종료 시간.** 미션 예시는 "약 10분"이지만 이 바이너리·설정에서 OOM 은 32초, 와치독은 34~43초 만에 일어났다.

## monitor.sh 개선 방향

운영 서버라면 장애 **전에** 알리도록 다음을 추가하겠다. 평가 문항 답변은 [EXPLAIN.md](EXPLAIN.md) 5장에 있다.

| 개선 | 이번 증거에 비추어 |
|---|---|
| RSS 증가 기울기(MB/분)와 "한도 도달 예상 시각" 계산 → 임계치 전에 경보 | OOM before 는 8.0MB/s 로 일정했다. Heap 증가 시작 후 첫 3샘플(09:13:30~40)만으로 종료 시점을 1~2초 오차로 근사 예측할 수 있었다(EXPLAIN.md 5-1) |
| LOG_AGE > N초 + CPU≈0 + PID 생존 → "hang" 경보와 `ps -L -o wchan` 자동 수집 | Deadlock 은 LOG_AGE 만 단조 증가하고 나머지는 평평했다 |
| 앱 자체 지표(로그의 Load·Heap)와 OS 실측의 차이 경보 | CPU 케이스에서 앱 Load 56% vs 실측 2% |
| 비정상 종료 시 종료 코드·직전 로그 tail 을 함께 남기기 | 지금은 `NOT_RUNNING` 만 남고, 원인은 run-case.sh 가 따로 모은다 |
| 기록을 JSON/CSV 로도 남기기 | 그래프·대시보드로 바로 넘길 수 있다 |

## 검증

| 항목 | 결과 |
|---|---|
| `bash tests/test_monitor.sh` (호스트) | `PASS 9 / FAIL 0` (`evidence/tdd/green-host.txt`) |
| `docker run --rm --cpus=2 --memory=2g --pids-limit=512 -v "$PWD:/w:ro" -w /w b4-2-lab bash tests/test_monitor.sh` | `PASS 9 / FAIL 0` (`evidence/tdd/green-container.txt`) |
| TDD 순서 | 테스트 먼저 커밋. 구현 전 `PASS 0 / FAIL 8`(터미널 확인, 원본 미보존). `pick_worker` 는 탐색 후 추가, 첫 구현에서 FAIL 확인 후 수정(WORKLOG.md 3장). 보관된 증거는 test 커밋 시점 재실행 결과 `PASS 0 / FAIL 9`(`evidence/tdd/red-at-test-commit.txt`) |
| `shellcheck -f gcc`(koalaman/shellcheck:stable) monitor.sh·env/*.sh | 지적 0건. `env/snapshot.sh` 의 SC2009(`ps -ef \| grep`)는 미션이 요구하는 증거 형식이라 유지 |
| `bash -n` 전체 스크립트 | 통과 |
| `env/run-case.sh smoke …` | summary·로그·스냅샷 생성, 종료 후 b42-* 컨테이너 없음 |

## 폴더 구조

```
answers/
├── README.md          이 문서
├── PLAN.md            목표·격리 방식·실험 원칙·탐색 결과·실험 매트릭스·결과
├── EXPLAIN.md         미션 목표 4문항 + 평가 20문항 답변
├── WORKLOG.md         시도 / 결과 / 판단 기록
├── monitor.sh         관제 스크립트
├── tests/test_monitor.sh
├── env/
│   ├── Dockerfile  build.sh  agent.env
│   ├── launch.sh      컨테이너 안: 앱을 의사 터미널로 실행, 종료 코드 기록
│   ├── snapshot.sh    컨테이너 안: ps/top//proc 스냅샷
│   ├── run-case.sh    실행 1회 + 증거 회수 + summary
│   └── run-matrix.sh  확정한 실험 매트릭스 실행
├── issues/            01-oom.md  02-cpu.md  03-deadlock.md
└── evidence/          00-explore/  oom/  cpu/  deadlock/
```
