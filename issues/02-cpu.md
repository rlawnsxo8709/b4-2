# [Bug] CPU 과점유 - CPU_MAX_OCCUPY=80 에서 CpuWorker 부하가 50%를 넘는 순간 Watchdog 이 SIGTERM 으로 프로세스 종료

> 라벨: `bug` · 재현 환경: Docker 컨테이너(ubuntu:24.04, `--cpus=2 --memory=2g --pids-limit=512 --network none`), arm64 바이너리, 실행 계정 `agent`(uid 1001). CPU 케이스는 다른 실험 컨테이너 없이 **단독, 순차**로 실행했다.
> PID 는 컨테이너 PID 네임스페이스 기준이다. 시각은 KST.

## 1. Description (현상 설명)

**무엇이:** `CPU_MAX_OCCUPY=80` 으로 실행하면, 앱 로그의 `[CpuWorker] Current Load` 가 5% 에서 계속 오르다 50% 를 넘는 순간 아래 로그를 남기고 프로세스가 종료된다. 기동 후 34~43초가 걸렸다. 종료 코드는 143(128+15, SIGTERM)이다.

```
[CRITICAL] [CpuWorker] CPU Threshold Violated! (56.38%).
>>> [SYSTEM] WATCHDOG: INITIATING EMERGENCY ABORT (SIGTERM) <<<
```

**언제·어떤 조건에서:** `CPU_MAX_OCCUPY=80`, `MEMORY_LIMIT=512`, `MULTI_THREAD_ENABLE=false` 로 2회 실행했다.
`MEMORY_LIMIT` 은 OOM 동작과 섞이지 않도록 512 로 고정했다. 256 이하이면 OOM 동작(32초에 자체 종료)이 선택된다(`evidence/00-explore/a-default/`, `c-cpu10/` 은 CPU 10%·256MB 조합). 256MB 와 CPU 50 초과를 함께 준 조합은 시험하지 않았다.
- before-1: 09:28:11 시작 → 09:28:54 종료(43초), 워커 PID 31
- before-2: 09:29:00 시작 → 09:29:34 종료(34초), 워커 PID 31

부트 배너가 이미 경고했다. 50 을 넘는 값(51~100)은 모두 같은 경고가 나왔다(`evidence/00-explore/probe-banner.txt`).

```
 [ CPU    ] Limit: 80%  		[ WARNING: Recommend Under 50% ]
```
(`evidence/cpu/before-1/app.log`)

## 2. Evidence & Logs (증거 자료)

### 2-1. 프로그램 실행 로그 — 부하 상승 구간과 종료 로그

`evidence/cpu/before-1/app.log` 30~49행:

```
2026-10-04 09:28:13,828 [INFO] [CpuWorker] Started. Maximum CPU Limit: 80%
2026-10-04 09:28:13,828 [INFO] [CpuWorker] Current Load: 5.00%
2026-10-04 09:28:16,943 [INFO] [CpuWorker] Current Load: 7.51%
2026-10-04 09:28:20,058 [INFO] [CpuWorker] Current Load: 8.60%
2026-10-04 09:28:23,174 [INFO] [CpuWorker] Current Load: 13.30%
2026-10-04 09:28:26,290 [INFO] [CpuWorker] Current Load: 19.02%
2026-10-04 09:28:29,404 [INFO] [CpuWorker] Current Load: 24.92%
2026-10-04 09:28:32,515 [INFO] [CpuWorker] Current Load: 26.58%
2026-10-04 09:28:35,630 [INFO] [CpuWorker] Current Load: 31.51%
2026-10-04 09:28:38,739 [INFO] [CpuWorker] Current Load: 37.37%
2026-10-04 09:28:41,848 [INFO] [CpuWorker] Current Load: 44.67%
2026-10-04 09:28:44,964 [INFO] [CpuWorker] Current Load: 47.36%
2026-10-04 09:28:48,080 [INFO] [CpuWorker] Current Load: 49.65%
2026-10-04 09:28:51,189 [INFO] [CpuWorker] Current Load: 49.85%
2026-10-04 09:28:54,304 [INFO] [CpuWorker] Current Load: 56.38%
2026-10-04 09:28:54,404 [CRITICAL] [CpuWorker] CPU Threshold Violated! (56.38%).

>>> [SYSTEM] WATCHDOG: INITIATING EMERGENCY ABORT (SIGTERM) <<<

Terminated
```

- 약 3.1초마다 부하 값이 올라 40초 만에 5.00% → 56.38% 가 됐다. **급상승 구간은 09:28:23 ~ 09:28:54**(13.30% → 56.38%)이다.
- 와치독은 설정 최대값 80% 가 아니라 **50% 를 처음 넘은 값**에서 발동했다. before-2 는 52.39%(09:29:34.223), 탐색 실행 `e-cpu80-mem512` 는 56.02% 였다. 세 번 모두 직전 값은 50% 미만(49.85%, 47.21%, 49.52%)이었다.
- `Terminated` 는 상위 셸이 "자식이 SIGTERM 으로 끝났다"고 출력한 줄이다. `evidence/cpu/before-1/exit.txt` → `exit_code=143 ended_at=2026-10-04 09:28:54`.
  이 시점에 run-case.sh 는 아무 신호도 보내지 않았다(summary 의 `end_cause: 자체 종료`). 앱이 **스스로** SIGTERM 으로 끝낸 것이다. 오류(크래시)가 아니라 보호 조치였다는 근거는 세 가지다. 로그 레벨이 `CRITICAL` 정책 메시지이고, 위반 값이 함께 기록됐고, 종료 신호가 SIGTERM(정상 종료 요청)이다.

### 2-2. monitor.sh·top·ps — 특정 프로세스의 CPU, 그리고 앱 지표와의 차이

monitor.sh 는 `/proc/31/stat` 의 utime+stime 차분으로 **5초 구간 CPU%** 를 잰다. 앱 로그의 부하 값과 같은 시간축에 놓았다(`evidence/cpu/before-1/monitor.log`, `app.log`).

| monitor 시각 | monitor CPU (OS 실측, 워커 PID 31) | 그 시점 앱이 마지막으로 보고한 Load |
|---|---|---|
| 09:28:17 | 0.0% | 7.51% |
| 09:28:22 | 0.2% | 8.60% |
| 09:28:27 | 0.6% | 19.02% |
| 09:28:32 | 1.0% | 24.92% |
| 09:28:37 | 0.6% | 31.51% |
| 09:28:42 | 1.6% | 44.67% |
| 09:28:47 | 1.0% | 47.36% |
| 09:28:52 | 2.0% | 49.85% |
| 09:28:57 | `PID:- STATUS:NOT_RUNNING` | (09:28:54 와치독 종료) |

```
[2026-10-04 09:28:17] PID:31 CPU:0.0% MEM:0.8% RSS:16.5MB THREADS:1 STATE:S LOG_AGE:1s
[2026-10-04 09:28:32] PID:31 CPU:1.0% MEM:0.8% RSS:16.5MB THREADS:1 STATE:S LOG_AGE:0s
[2026-10-04 09:28:52] PID:31 CPU:2.0% MEM:0.8% RSS:16.5MB THREADS:1 STATE:S LOG_AGE:1s
[2026-10-04 09:28:57] PID:- STATUS:NOT_RUNNING
```

before-2 도 같은 모양이다. monitor CPU 0.0 → 0.2 → 0.6 → 1.2 → 0.8 → 1.8%, 09:29:37 `NOT_RUNNING`.

`evidence/cpu/before-1/snapshots/092851-top-H.txt` (종료 3초 전, 해당 PID 의 스레드만):

```
top - 09:28:52 up 88 days, 12:32,  0 user,  load average: 2.14, 2.74, 2.15
Threads:   1 total,   0 running,   1 sleeping,   0 stopped,   0 zombie
    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
     31 agent     30  10   23368  16848   8648 S   0.0   0.0   0:00.41 agent-l+
```

`evidence/cpu/before-1/snapshots/092851-ps-L.txt`:

```
    PID     LWP STAT %CPU %MEM WCHAN                            COMMAND
     31      31 SN+   1.0  0.0 do_select                        agent-leak-app
```

호스트에서 본 컨테이너 전체(`snapshots/*-docker-stats.txt`): 0.99% → 2.55% → 0.01% → 1.14%.

**해석 — 두 가지를 구분해서 기록한다.**
1. **CPU 경보의 주체는 이 프로세스 하나다.** 부하 값을 내는 `[CpuWorker]` 와 종료되는 대상은 모두 워커 PID 31 이다. 컨테이너 안 프로세스 목록(`092851-top.txt`)에서 다른 프로세스는 모두 %CPU 0.0 이었다. top 머리말의 호스트 load average(2.14)는 호스트 전체(다른 서비스 포함)의 값이다. 이 컨테이너가 쓴 CPU(docker stats 0.01~2.55%)로는 설명되지 않는다. 그래서 이 장애는 "시스템 전체 과부하"가 아니라 **agent-leak-app 내부 CpuWorker 의 부하 상승**으로 식별된다.
2. **그러나 OS 가 잰 실제 CPU 사용률은 거의 오르지 않았다.** 앱이 보고한 Load 는 5% → 56% 였다. 같은 기간 OS 실측은 0.0% → 2.0% 로, 같은 방향으로 조금 올랐을 뿐이다. 누적 CPU 시간(TIME+)도 40초 동안 0.41초다. 스레드는 대부분 `do_select`(타이머 대기)에서 잠들어 있었다.
   따라서 이 바이너리의 "CPU 급상승"은 앱 내부에서 계산·보고하는 지표다. 와치독도 이 내부 지표를 기준으로 동작한다. 실제로 코어를 100% 태우는 부하였다면 monitor.sh 가 잡았을 것이다. 바쁜 루프 프로세스에서 구간 CPU 50% 이상을 잡는지는 `tests/test_monitor.sh` 의 `busy_cpu` 로 검증했다.
   그래서 이 리포트의 "급상승 구간"은 앱 로그의 Load 로 제시하고, OS 실측값은 나란히 적어 차이를 그대로 남긴다.

## 3. Root Cause Analysis (원인 분석)

**직접 원인 — 설정 상한이 와치독 임계치보다 높다.** 탐색과 본 실험에서 관찰한 동작은 다음과 같다(`evidence/00-explore/manual-512-healthy.app.log`, `evidence/cpu/*/app.log`).

| `CPU_MAX_OCCUPY` | CpuWorker 동작 | 결과 | 근거 수준 |
|---|---|---|---|
| 50 | Load 를 50% 까지 올림 → `Peak reached (50.00%). Starting cooldown...` → 5% 까지 내림 → 반복 | 와치독 미발동, 계속 생존 | **실제 실행**: `cpu/after-1·2`(각 300초), `manual-512-healthy.app.log` 등 |
| 10·30·49 | 배너 `[ OK ]`, `Scenario Selected: [Healthy System Monitoring]` 까지만 확인 | (장시간 동작은 미확인) | 10초 배너 탐침뿐(`probe-banner.txt`) |
| 51·70·80·90·100 | 배너 `WARNING: Recommend Under 50%`, CpuWorker 가 `Maximum CPU Limit: <값>%` 로 시작 | — | 10초 배너 탐침(`probe-banner.txt`) |
| 80 | Load 를 80 까지 올리려다 50% 를 넘음 | `CPU Threshold Violated!` → `WATCHDOG … (SIGTERM)` | **실제 실행**: `cpu/before-1·2`, `e-cpu80-mem512` |

와치독 임계치는 50% 로 보인다. 위반 값 56.38·52.39·56.02% 가 모두 50% 를 처음 넘은 값이었다. 반면 `CPU_MAX_OCCUPY` 는 작업자가 올라갈 수 있는 **상한**이다. 상한(80)이 임계치(50)보다 높으면 작업자는 반드시 임계치를 지나가므로, 와치독 발동은 시간 문제다. 부팅 시 경고(`Recommend Under 50%`)만 하고 기동을 막지 않는 것이 설정 결함이다.

**OS 동작 원리 — 왜 CPU 과점유가 시스템 지연이 되는가, 왜 단일 프로세스를 끊는가**

1. **타임슬라이스와 스케줄러.** 리눅스 CFS 스케줄러는 실행 가능한(R) 스레드들에게 CPU 시간을 나눠 준다. 각자의 가중치(nice)에 비례하는 몫이다. 계산만 하는 스레드는 받은 슬라이스를 끝까지 다 쓰고 곧바로 다시 실행 큐에 선다. 코어 수보다 이런 스레드가 많아지면 다른 프로세스는 실행 큐에서 기다리는 시간이 길어진다. 이것이 응답 지연(latency)이다. 웹 요청 처리, sshd, 관제 에이전트처럼 짧게 자주 깨어나야 하는 프로세스가 가장 먼저 느려진다.
2. **nice 와 cgroup.** 이 앱은 기동 직후 스스로 우선순위를 낮춘다(`[SafetyGuard] Process priority lowered (nice=10).`, `top` 의 `NI 10`, `PR 30`). nice 10 의 CFS 가중치는 nice 0 의 약 1/9 이다. 그래서 경합이 생기면 다른 프로세스가 먼저 CPU 를 받는다. 컨테이너의 `--cpus=2`(cgroup `cpu.max`)는 이 컨테이너 전체가 쓸 수 있는 CPU 시간에 상한을 둔다. 두 장치 모두 "덜 받게" 할 뿐 "멈추게" 하지는 못한다.
3. **와치독이 프로세스를 끊는 이유.** 과점유가 계속되면 nice·cgroup 만으로는 피해를 다 막지 못한다. 같은 코어의 다른 작업은 계속 지연된다. 무한 루프라면 스스로 끝나지도 않는다. 와치독은 임계치를 넘은 **원인 프로세스 하나만** 종료한다. 서버 전체(다른 서비스, 관제, 원격 접속)의 응답성을 지키고 피해 범위를 그 프로세스로 한정하는 것이다. 종료된 프로세스는 상위 관리자(systemd, 컨테이너 재시작 정책)가 깨끗한 상태로 다시 띄울 수 있다(fail-fast).
   SIGTERM 을 쓴 것도 의미가 있다. SIGTERM 은 잡을 수 있는 "정상 종료 요청"이라 프로세스가 정리 작업을 할 기회가 있다. OOM 케이스의 SIGKILL 과 다르다. CPU 과점유는 메모리 부족과 달리 정리할 시간을 줄 여유가 있다.

## 4. Workaround & Verification (조치 및 검증)

**조치:** 환경변수 `CPU_MAX_OCCUPY` 를 80 → **50**(권장 상한)으로 낮췄다. 다른 변수는 그대로 두었다(`MEMORY_LIMIT=512`, `MULTI_THREAD_ENABLE=false`).

```bash
env/run-case.sh cpu after-1 --timeout 300 --snap-every 30 MEMORY_LIMIT=512 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=false
```

**Before & After** (각 `evidence/cpu/<label>/summary.txt`, `monitor.log`, `app.log`)

| 실행 | 설정값 | 생존 시간 | 종료 원인 | 앱 보고 Load 최대 | 와치독 로그 | OS 실측 CPU (monitor, 워커 PID 샘플) | 피크 RSS |
|---|---|---|---|---|---|---|---|
| before-1 | `CPU_MAX_OCCUPY=80` | **43초** | Watchdog 자체 종료, exit 143 (SIGTERM) | 56.38% | 있음 | 0.0~2.0% | 16.5MB |
| before-2 | `CPU_MAX_OCCUPY=80` | **34초** | Watchdog 자체 종료, exit 143 (SIGTERM) | 52.39% | 있음 | 0.0~1.8% | 16.5MB |
| after-1 | `CPU_MAX_OCCUPY=50` | **305초 이상** | 종료 없음 → 시간 제한에서 run-case.sh 가 TERM(exit 143) | 50.00% | 0건 | 0.0~2.8% | 516.7MB |
| after-2 | `CPU_MAX_OCCUPY=50` | **305초 이상** | 종료 없음 → 시간 제한에서 run-case.sh 가 TERM(exit 143) | 50.00% | 0건 | 0.2~4.0% (4.0%는 기동 6초 뒤 첫 샘플, 이후 0.2~2.6%) | 516.7MB |

- 종료 여부가 바뀌었다. Before 2회는 모두 와치독으로 종료됐다(평균 38.5초). After 2회는 시간 제한 300초까지 살아 있었다. 생존 시간은 7.9배 이상(305÷38.5)이다.
- After 에서 CpuWorker 는 50.00% 에서 멈추고 내려가기를 반복했다(`evidence/cpu/after-1/app.log`, 300초 동안 `Peak reached` 5회).

  ```
  2026-10-04 09:29:41,603 [INFO] >>> Scenario Selected: [Healthy System Monitoring]
  2026-10-04 09:30:09,706 [INFO] [CpuWorker] Peak reached (50.00%). Starting cooldown...
  2026-10-04 09:30:34,613 [INFO] [CpuWorker] Cooldown complete (5.00%). Resuming load increase...
  2026-10-04 09:30:59,497 [INFO] [CpuWorker] Peak reached (50.00%). Starting cooldown...
  ```

- After 의 피크 RSS(516.7MB)와 OS 실측 CPU 가 Before 보다 약간 높은 이유는 이렇다. After 설정은 모두 권장 범위이므로 앱이 `Healthy System Monitoring` 동작을 고르고, 여기서 MemoryWorker(메모리 할당·정리)도 함께 돈다. OS 실측 CPU 는 기동 직후 첫 샘플을 빼면 Before/After 모두 3% 미만이다. 그래서 이 케이스의 Before/After 차이는 **OS CPU 수치가 아니라 앱 내부 Load 의 상한(56% → 50%)과 종료 여부**에서 나타난다.

**근본 해결 제안 (코드 수준)**

1. **설정 검증을 경고에서 차단으로:** `CPU_MAX_OCCUPY` 가 와치독 임계치보다 크면 부트 6단계에서 `[FAIL]` 로 막는다. 또는 상한을 `min(CPU_MAX_OCCUPY, WATCHDOG_THRESHOLD - 여유)` 로 자른다. 상한과 임계치를 같은 설정 원천에서 계산해 서로 어긋나지 않게 한다.
2. **스로틀링 먼저, 종료는 마지막:** 임계치에 가까워지면 작업자가 스스로 쉬게 한다(작업 단위 사이에 `sleep`/yield, 토큰 버킷으로 초당 작업량 제한). 와치독은 "경고 → 감속 → 일정 시간 지속 시 종료"의 단계로 동작하게 한다.
3. **실측 기반 감시:** 내부 계산값만 믿지 말고 `/proc/self/stat` 의 utime+stime 차분(monitor.sh 와 같은 방식)이나 cgroup `cpu.stat` 으로 실제 사용률을 함께 본다. 지표와 실측이 어긋나면 그 자체를 경보로 남긴다.
4. **OS 수준 상한:** 무거운 계산은 별도 프로세스로 분리하고 cgroup `cpu.max`(컨테이너 `--cpus`, systemd `CPUQuota=`)로 묶는다. 과점유가 생겨도 다른 서비스의 몫을 침범하지 못하게 한다.
