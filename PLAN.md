# b4-2 수행 계획 — agent-leak-app 장애 3종(OOM · CPU · Deadlock) 실측 분석

> 작성일: 2026-10-04 / 대상: b4-2 「컴퓨터가 갑자기 느려지거나 멈췄을 때 원인 찾아 고치기」 미션
> 상태: 탐색 실행 후 실험 매트릭스 확정(6장), 실험 완료 후 결과 기록(7장).

## 1. 목표

제공 바이너리 `agent-leak-app`(arm64)을 **실제로 실행**해서 세 가지 장애를 재현하고, 관제 데이터와 로그를 근거로 원인을 밝혀 GitHub Issue 형식 리포트 3건으로 남긴다.

| 장애 | 재현 변수 | 보여야 하는 것 |
|---|---|---|
| OOM (Memory Leak) | `MEMORY_LIMIT` | RSS가 시간에 따라 선형으로 증가 → `Memory limit exceeded` → `SELF-TERMINATED`. 한도를 올리면 더 오래 생존 |
| CPU 과점유 | `CPU_MAX_OCCUPY` | 해당 프로세스의 CPU%가 급상승 → `WATCHDOG … SIGTERM`. 임계치를 바꾸면 종료 여부나 생존 시간이 달라짐 |
| Deadlock | `MULTI_THREAD_ENABLE` | PID는 살아 있지만 CPU≈0, RSS 고정, 로그 정지. 마지막 `WAITING … BLOCKED` 로그에서 순환 대기 도출. `false`면 회피 |

## 2. 환경 격리 방식

이 호스트는 운영 중인 다른 컨테이너(LLM 추론 서버 등)를 함께 돌린다. 실험이 이들에 영향을 주면 안 된다.

| 결정 | 선택 | 이유 |
|---|---|---|
| 실행 위치 | Docker 컨테이너(`ubuntu:24.04` 기반 이미지 `b4-2-lab`) | 미션이 격리 환경 실행을 권장한다. 호스트에 사용자·디렉터리를 만들지 않는다 |
| 자원 제한 | 모든 컨테이너 `--cpus=2 --memory=2g --pids-limit=512` | 메모리 누수·CPU 폭주·스레드 폭증이 호스트로 번지지 않게 막는다 |
| 실행 계정 | 이미지 안의 일반 사용자 `agent`(uid 1001) | 미션 조건: root가 아닌 일반 사용자 |
| 바이너리 | 이미지에 굽지 않고 실행 때 읽기 전용 마운트 | 이미지에 제공 바이너리가 섞이지 않고, 저장소에도 넣지 않는다(`.runtime/`은 gitignore) |
| 컨테이너 수명 | 실행 1회 = 컨테이너 1개, 끝나면 `docker rm -f` | 이전 실행의 로그·상태가 다음 실행에 섞이지 않는다 |
| 동시 실행 | 최대 2개, CPU 케이스는 단독 | CPU 측정이 다른 실험에 오염되지 않게 한다 |
| 컨테이너 이름 | `b42-<case>-<label>` | 다른 작업의 컨테이너와 구분하고, 정리 대상을 확실히 한다 |

## 3. 실험 원칙

1. **관찰 → 가설 → 검증.** 탐색 실행으로 부트 조건과 장애 발동 조건을 먼저 관찰하고, 관찰한 사실만으로 매트릭스를 짠다. 디컴파일·리버스 엔지니어링은 하지 않는다.
2. **변수 하나만 바꾼다.** Before/After 사이에는 해당 케이스의 변수 하나만 다르다. 나머지 변수는 다른 장애가 끼어들지 않는 값으로 고정한다.
3. **같은 조건 2회 이상.** 한 번의 결과는 우연일 수 있다. 케이스마다 Before 2회, After 2회 이상 실행한다.
4. **실측값만 쓴다.** 리포트의 PID·타임스탬프·로그 문구·수치는 `evidence/`에 실제로 있는 값만 쓴다.

## 4. 수집 증거

| 증거 | 수집 방법 | 위치 |
|---|---|---|
| 앱 실행 로그(stdout/stderr) | 앱을 백그라운드로 실행하고 출력을 파일로 보냄 | `evidence/<case>/<label>/app.log` |
| 앱 자체 로그 디렉터리 | `AGENT_LOG_DIR` 회수 | `evidence/<case>/<label>/agent-log/` |
| 관제 로그 | 컨테이너 안에서 `monitor.sh -i 5` | `evidence/<case>/<label>/monitor.log` |
| 시스템 도구 스냅샷 | `ps -ef`, `ps -L`, `top -H -b -n 1`, `/proc/PID/status`, `/proc/PID/task/*/stat` | `evidence/<case>/<label>/snapshots/` |
| 실행 요약 | 시작·종료 시각, 생존 시간, 종료 원인, 피크 RSS·CPU | `evidence/<case>/<label>/summary.txt` |

## 5. 작업 순서

1. 자료 준비(zip 다운로드, 압축 해제, arm64 확인)와 저장소 초기화
2. 실행 환경(이미지) 구성 + 탐색 실행(부트 확인, 장애 발동 조건 관찰)
3. `monitor.sh`를 테스트 먼저 작성(TDD)
4. 실험 실행기 `env/run-case.sh`
5. OOM → CPU(단독) → Deadlock 순서로 실험
6. 리포트 3건과 문서 작성, 병합

## 6. 탐색 결과와 확정한 실험 매트릭스

### 6.1 탐색에서 확인한 사실 (근거: `evidence/00-explore/`, 상세 과정은 WORKLOG.md)

| # | 관찰 | 근거 |
|---|---|---|
| 1 | 기본값(`env/agent.env`)으로 첫 시도에 부트 6단계 모두 `[OK]`. `AGENT_KEY_PATH`는 **디렉터리**(`$AGENT_HOME/api_keys`)여야 한다 | `boot.txt`, `boot-fail-keypath.txt`(`Key Path Mismatch. Expected: /home/agent/agent-app/api_keys`) |
| 2 | root 실행, `MEMORY_LIMIT=600`, secret.key 내용 불일치는 부트 단계에서 `[FAIL]` → `System Boot Failed`(exit 1) | `boot-fail-*.txt` |
| 3 | 앱은 같은 명령줄의 **런처(부모) + 워커(자식)** 2개 프로세스로 뜬다. 메모리·스레드·nice=10 은 워커에만 나타난다 | `a-default/snapshots/*-ps-ef.txt` |
| 4 | 출력이 파일이면 `>>> [SYSTEM] SELF-TERMINATED …` 줄이 사라진다. 의사 터미널로 실행하면 나타난다(자체 SIGKILL 직전 stdout 버퍼가 비워지지 않음) | `boot.txt` vs `oom-256-tty.txt` |
| 5 | 앱은 시작할 때 설정값으로 **시나리오 하나를 고른다**. `MEMORY_LIMIT≤256` → OOM(`MULTI_THREAD_ENABLE=true` 와 함께여도 OOM 이 먼저), `CPU_MAX_OCCUPY>50` → Watchdog, `MULTI_THREAD_ENABLE=true` → Deadlock, 모두 권장 범위(257MB 이상·50% 이하·false)면 `Healthy System Monitoring`. 256MB 와 CPU 50 초과를 함께 준 조합은 시험하지 않았다 | `a-default`, `b-multithread`, `c-cpu10`, `b2-multithread-mem512`, `d-mem384`, `e-cpu80-mem512`, `probe-banner.txt` |
| 6 | OOM 시나리오: Heap 이 약 3초마다 25MB 씩 늘고, `MEMORY_LIMIT` 을 넘는 순간 `Memory limit exceeded` → 자체 SIGKILL(exit 137). 256MB 에서 약 32초 | `a-default/app.log` |
| 7 | Healthy 시나리오(257MB 이상): Heap 이 한도에 닿으면 `Memory Usage Reached Limit … Starting cleanup` → `MEMORY RECOVERED` 후 25MB 부터 다시 증가. 종료되지 않는다 | `d-mem384/app.log` |
| 8 | Watchdog 시나리오: 앱이 로그로 보고하는 `[CpuWorker] Current Load` 가 5%부터 오르다 **50%를 넘는 순간** `CPU Threshold Violated!` → `WATCHDOG: INITIATING EMERGENCY ABORT (SIGTERM)`(exit 143). `CPU_MAX_OCCUPY≤50` 이면 그 값에서 `Peak reached … Starting cooldown` 후 다시 내려간다 | `e-cpu80-mem512/app.log`, `manual-512-healthy.app.log` |
| 9 | **그러나 OS 에서 잰 실제 CPU 는 오르지 않는다.** 같은 시간 monitor.sh 는 기동 직후 첫 샘플 8.0%를 빼면 0.2~1.2%, `top -H` 0.0%, `docker stats` 0.01~1.43% | `e-cpu80-mem512/monitor.log`, `snapshots/` |
| 10 | Deadlock 시나리오: 시작 약 7초 뒤 Worker-Thread-1/2 가 서로의 자원을 기다리는 `WAITING … (Status: BLOCKED)` 2줄을 마지막으로 로그 정지. PID 생존, CPU 0.0%, RSS 16.5MB 고정, 스레드 3개 모두 `futex_wait_queue` | `b2-multithread-mem512/` |

**미션 문서·계획과 다른 점:** CPU 케이스는 "낮은 값이 와치독을 일으킨다"가 아니었다. `CPU_MAX_OCCUPY` 를 **50보다 높이면** 와치독이 발동하고, 50 이하로 **낮추면** 회피된다. 그래서 Before 를 높은 값(80), After 를 50 으로 정했다.

### 6.2 실험 매트릭스 (실행: `env/run-matrix.sh`)

다른 장애가 끼어들지 않도록 케이스의 변수 하나만 바꾸고 나머지는 고정한다. 고정값은 "경고 없음" 값이다(`MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=50`, `MULTI_THREAD_ENABLE=false`).

| 케이스 | 변경 변수 | Before | After | 고정값 | 시간 제한 | 반복 | 스냅샷 간격 |
|---|---|---|---|---|---|---|---|
| OOM | `MEMORY_LIMIT` | 256 | 512 | CPU 50, MT false | 300초 (Before 평균 약 32초의 9배) | 각 2회 (동시 2컨테이너) | Before 10초 / After 60초 |
| OOM 보조 | `MEMORY_LIMIT` | 128 | — | CPU 50, MT false | 300초 | 2회 | 10초 |
| CPU | `CPU_MAX_OCCUPY` | 80 | 50 | MEM 512, MT false | 300초 (Before 약 40초의 7배) | 각 2회 (**단독, 순차**) | Before 10초 / After 30초 |
| Deadlock | `MULTI_THREAD_ENABLE` | true | false | MEM 512, CPU 50 | 240초 (정지 후 3분 이상 관찰) | 각 2회 (동시 2컨테이너) | 30초 |

- OOM 보조(128MB)는 같은 OOM 시나리오 안에서 한도와 생존 시간이 비례하는지(누수 속도 일정) 확인하기 위한 것이다.
- 예상 실험 시간: OOM 약 7분 + Deadlock 약 9분 + CPU 약 12분 ≈ 28분 (탐색 약 20분 포함 시 90분 예산 안).

## 7. 실험 결과 (실행: 2026-10-04 09:13:24 ~ 09:39:59, `env/run-matrix.sh`)

| 케이스 | 실행 | 설정 | 생존(관찰) 시간 | 종료 원인 | 핵심 로그 |
|---|---|---|---|---|---|
| OOM | before-1 / before-2 | `MEMORY_LIMIT=256` | 32초 / 32초 | 자체 종료 exit 137 (SIGKILL) | `Memory limit exceeded (275MB >= 256MB)` → `SELF-TERMINATED (Memory Limit Exceeded)` |
| OOM | low128-1 / low128-2 (보조) | `MEMORY_LIMIT=128` | 18초 / 18초 | 자체 종료 exit 137 | `Memory limit exceeded (150MB >= 128MB)` |
| OOM | after-1 / after-2 | `MEMORY_LIMIT=512` | 303초+ / 303초+ | 시간 제한 중단(생존) | `Memory Usage Reached Limit (525MB). Starting cleanup...` 4회씩 |
| CPU | before-1 / before-2 | `CPU_MAX_OCCUPY=80` | 43초 / 34초 | 자체 종료 exit 143 (SIGTERM) | `CPU Threshold Violated! (56.38%)` / `(52.39…%)` → `WATCHDOG: INITIATING EMERGENCY ABORT (SIGTERM)` |
| CPU | after-1 / after-2 | `CPU_MAX_OCCUPY=50` | 305초+ / 305초+ | 시간 제한 중단(생존) | `Peak reached (50.00%). Starting cooldown...` 5회씩, WATCHDOG 0건 |
| Deadlock | before-1 / before-2 | `MULTI_THREAD_ENABLE=true` | 246초 / 246초 관찰 | 시간 제한 중단(무응답) | 기동 9초 뒤 `WAITING for [Socket_Pool_B]/[Shared_Memory_A]... (Status: BLOCKED)` 이후 로그 0줄 |
| Deadlock | after-1 / after-2 | `MULTI_THREAD_ENABLE=false` | 241초 / 241초 관찰 | 시간 제한 중단(정상 진행) | `[Scheduler] All tasks completed.`, LOG_AGE 최대 3초, BLOCKED 0건 |

- 실험 시간: 탐색 약 20분(04:37~04:57) + 매트릭스 26분 35초 = 약 47분. 90분 예산 안이다.
- 같은 조건 2회는 모든 케이스에서 종료 양상(자체 종료·생존·무응답)이 같았다. CPU before 의 생존 시간만 43/34초로 달랐다. 앱이 보고하는 부하 증가 폭이 실행마다 달라 50%를 넘는 시점이 달라졌기 때문이다.
- 증거 총량: `du -sh evidence` = 4.7M (50MB 기준 이하).
- 케이스별 상세 분석은 `issues/01-oom.md`, `issues/02-cpu.md`, `issues/03-deadlock.md`.
