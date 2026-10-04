# [Bug] Deadlock - MULTI_THREAD_ENABLE=true 에서 워커 스레드 2개가 서로의 락을 기다리며 프로세스 무응답

> 라벨: `bug` · 재현 환경: Docker 컨테이너(ubuntu:24.04, `--cpus=2 --memory=2g --pids-limit=512 --network none`), arm64 바이너리, 실행 계정 `agent`(uid 1001)
> PID·LWP 는 컨테이너 PID 네임스페이스 기준이다. 시각은 KST.

## 1. Description (현상 설명)

**무엇이:** `MULTI_THREAD_ENABLE=true` 로 실행하면, 기동 약 9초 뒤부터 앱 로그가 한 줄도 더 나오지 않는다. 프로세스는 종료되지 않는다. PID 는 그대로 살아 있고, CPU 는 0.0%, 메모리는 변하지 않는다. 일을 하지도 죽지도 않는 **무응답(hang)** 상태가 시간 제한(240초)까지 계속됐다.

**언제·어떤 조건에서:** `MULTI_THREAD_ENABLE=true`, `MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=50` 로 2회 실행했다.
`MEMORY_LIMIT` 을 512 로 고정한 이유가 있다. 256 이하이면 OOM 동작이 먼저 선택돼 32초에 죽는다. 그러면 교착이 드러나지 않는다(`evidence/00-explore/b-multithread/`).
- before-1: 09:19:44 시작, 워커 PID 31. 마지막 로그 09:19:53.164 → 09:23:50 까지 무응답
- before-2: 09:19:46 시작, 워커 PID 24. 마지막 로그 09:19:55.187 → 09:23:52 까지 무응답

부트 배너가 이미 위험을 알렸다.

```
 [ THREAD ] Concurrency: True 		[ WARNING ]
--------------------------------------------------
 >>> SYSTEM WARNING: POTENTIAL DEADLOCK IN CONCURRENT MODE.
```
(`evidence/deadlock/before-1/app.log`)

## 2. Evidence & Logs (증거 자료)

판단 순서는 이렇다. ① 프로세스가 살아 있는가 → ② CPU 를 쓰고 있는가 → ③ 메모리가 변하는가 → ④ 로그가 진행되는가 → ⑤ 스레드는 각각 어디서 멈췄는가 → ⑥ 마지막 로그는 무엇을 말하는가. 네 가지 신호(PID 생존, CPU≈0, RSS 정체, 로그 정지)를 같은 시간축에서 확인했다.

### 2-1. PID 생존 (`ps -ef | grep …`)

`evidence/deadlock/before-1/snapshots/092332-ps-ef.txt` (마지막 로그 3분 39초 뒤):

```
$ ps -ef | grep agent-leak-app
UID          PID    PPID  C STIME TTY          TIME CMD
agent         15       8  0 09:19 ?        00:00:00 script -q -f -e -c /opt/agent/agent-leak-app /dev/null
agent         16      15  0 09:19 pts/0    00:00:00 sh -c /opt/agent/agent-leak-app
agent         17      16  0 09:19 pts/0    00:00:00 /opt/agent/agent-leak-app
agent         31      17  0 09:19 pts/0    00:00:00 /opt/agent/agent-leak-app
```

워커 PID 31 이 살아 있다. 누적 CPU 시간(TIME)은 `00:00:00` 이다.

### 2-2. monitor.sh — CPU 0.0%, RSS 정체, LOG_AGE 만 증가

`evidence/deadlock/before-1/monitor.log` 발췌(앞 3줄, 이후 30초 간격, 끝 2줄):

```
[2026-10-04 09:19:50] PID:31 CPU:0.0% MEM:0.8% RSS:16.4MB THREADS:1 STATE:S LOG_AGE:4s
[2026-10-04 09:19:55] PID:31 CPU:0.0% MEM:0.8% RSS:16.5MB THREADS:3 STATE:S LOG_AGE:2s
[2026-10-04 09:20:00] PID:31 CPU:0.0% MEM:0.8% RSS:16.5MB THREADS:3 STATE:S LOG_AGE:7s
[2026-10-04 09:20:40] PID:31 CPU:0.0% MEM:0.8% RSS:16.5MB THREADS:3 STATE:S LOG_AGE:47s
[2026-10-04 09:21:10] PID:31 CPU:0.0% MEM:0.6% RSS:13.2MB THREADS:3 STATE:S LOG_AGE:77s
[2026-10-04 09:21:40] PID:31 CPU:0.0% MEM:0.6% RSS:13.2MB THREADS:3 STATE:S LOG_AGE:107s
[2026-10-04 09:22:10] PID:31 CPU:0.0% MEM:0.6% RSS:13.2MB THREADS:3 STATE:S LOG_AGE:137s
[2026-10-04 09:22:40] PID:31 CPU:0.0% MEM:0.6% RSS:13.2MB THREADS:3 STATE:S LOG_AGE:167s
[2026-10-04 09:23:10] PID:31 CPU:0.0% MEM:0.6% RSS:13.2MB THREADS:3 STATE:S LOG_AGE:197s
[2026-10-04 09:23:40] PID:31 CPU:0.0% MEM:0.6% RSS:13.2MB THREADS:3 STATE:S LOG_AGE:227s
[2026-10-04 09:23:45] PID:31 CPU:0.0% MEM:0.6% RSS:13.2MB THREADS:3 STATE:S LOG_AGE:232s
[2026-10-04 09:23:50] PID:- STATUS:NOT_RUNNING
```

- **CPU:** 마지막 로그(09:19:53) 이후 모든 샘플이 0.0% 다.
- **LOG_AGE:** 5초마다 5씩 늘어 232초에 이르렀다. 앱 로그 파일이 그동안 한 번도 수정되지 않았다는 뜻이다.
- **STATE:** 5초 간격 샘플에서 계속 `S`(인터럽트 가능한 대기)였다. 샘플 시점에 실행 중(`R`)이었던 적은 없다.
- **RSS:** 16.5MB → 13.2MB 로 한 번 **줄었다.** 프로세스가 메모리를 쓴 것이 아니다. `/proc/31/status` 를 보면 원인이 나온다(`snapshots/092053-status.txt` → `092124-status.txt`).

  ```
  092053: VmRSS: 16856 kB  RssAnon: 8208 kB  RssFile: 8648 kB  VmSwap: 0 kB  voluntary_ctxt_switches: 12
  092124: VmRSS: 13564 kB  RssAnon: 8208 kB  RssFile: 5356 kB  VmSwap: 0 kB  voluntary_ctxt_switches: 12
  ```

  프로세스가 직접 쓰는 익명 메모리(RssAnon 8,208 kB)는 그대로다. 줄어든 것은 파일 매핑 페이지(RssFile, 실행 파일·공유 라이브러리)뿐이다.
  같은 스냅샷의 `top` 머리말을 보면, 호스트 여유 메모리(free)는 14,775.6 MiB(09:20:21) → **10,460.7 MiB(09:20:53, 이 구간 최저)** → 13,526.5 MiB(09:21:24)로 내려갔다가 회복됐다. 스왑 사용량은 약 11,135 MiB 로 세션 내내 거의 같았다(`092021`·`092053`·`092124-top-H.txt`).
  RssFile 감소는 여유 메모리 최저점 직후 구간(09:20:53~09:21:24)에 일어났다. 그래서 "커널이 오래 쓰이지 않은 깨끗한 파일 페이지를 회수했다"는 해석이 시간상 맞는다. 다만 회수 자체를 기록한 증거는 없으므로 **가설**로 둔다.
  확실한 것은 두 가지다. 프로세스 자신의 메모리(RssAnon)는 변하지 않았다. RssFile 은 이후 끝까지 5,356 kB 에서 다시 늘지 않았다.
  같은 기간 메인 스레드(31)의 `voluntary_ctxt_switches` 는 09:20:21 부터 끝까지 12 에서 멈춰 있었다. 메인 스레드가 그동안 깨어났다가 다시 잠든 적이 없다는 뜻이다. 워커 LWP 107·108 의 컨텍스트 스위치 수는 수집하지 않았다.
  before-2 는 RSS 16.5MB 가 끝까지 고정이었다. PID 가 잡힌 50샘플 중 기동 직후 2개만 16.4MB 이고 나머지 48개가 모두 `RSS:16.5MB` 다(`evidence/deadlock/before-2/monitor.log`).

### 2-3. 스레드 단위 (`ps -L`, `top -H`, `/proc/<pid>/task/*`)

`evidence/deadlock/before-1/snapshots/092332-ps-L.txt`:

```
$ ps -L -o pid,lwp,stat,pcpu,pmem,wchan:32,comm -p 31
    PID     LWP STAT %CPU %MEM WCHAN                            COMMAND
     31      31 SNl+  0.0  0.0 futex_wait_queue                 agent-leak-app
     31     107 SNl+  0.0  0.0 futex_wait_queue                 agent-leak-app
     31     108 SNl+  0.0  0.0 futex_wait_queue                 agent-leak-app
```

`evidence/deadlock/before-1/snapshots/092332-top-H.txt`:

```
    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
     31 agent     30  10  169928  13564   5356 S   0.0   0.0   0:00.02 agent-l+
    107 agent     30  10  169928  13564   5356 S   0.0   0.0   0:00.00 agent-l+
    108 agent     30  10  169928  13564   5356 S   0.0   0.0   0:00.00 agent-l+
```

- 스레드 3개가 **모두 `futex_wait_queue`** 에서 잠들어 있다. futex 는 리눅스가 뮤텍스·락·조건변수를 구현하는 커널 대기 큐다. 이 wchan 은 "락을 얻으려고(또는 다른 스레드를 기다리려고) 커널에서 잠든 상태"를 뜻한다.
- 워커 스레드로 보이는 LWP 107·108 의 누적 CPU 시간(TIME+)은 `0:00.00` 이다.
- `/proc/31/task/*/stat` 의 utime·stime(14·15번째 필드)을 8개 스냅샷(09:20:21~09:23:48)에서 비교했다. 3개 스레드 모두 값이 변하지 않았다(`snapshots/*-task.txt`: tid31 `1 1`, tid107 `0 0`, tid108 `0 0`). utime·stime 은 10ms(1틱) 단위다. 따라서 이 값이 고정이라는 것은 **약 3분 반 동안 각 스레드가 쓴 CPU 시간이 1틱(10ms) 미만**이었다는 뜻이다. 사실상 CPU 를 받지 못하고 잠들어 있었다.

before-2 도 같다. 스냅샷 마지막 시점에 `/proc/24/task/{24,106,107}/wchan` 이 모두 `futex_wait_queue` 였다.

### 2-4. 마지막 로그 지점 — `WAITING … BLOCKED`

`evidence/deadlock/before-1/app.log` 32~42행 (이후 run-case.sh 가 TERM 을 보낼 때의 `Terminated` 외에는 아무 줄도 없다):

```
2026-10-04 09:19:51,154 [INFO] [Worker-Thread-1] Process Started. Attempting to lock [Shared_Memory_A]...
2026-10-04 09:19:51,154 [INFO] [AgentWorker][Worker-Thread-2] Process Started. Attempting to lock [Socket_Pool_B]...
2026-10-04 09:19:51,154 [INFO] [AgentWorker] Waiting for worker threads to complete transactions...
2026-10-04 09:19:51,154 [INFO] [AgentWorker][Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)
2026-10-04 09:19:51,154 [INFO] [AgentWorker][Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)
2026-10-04 09:19:51,154 [INFO] [AgentWorker][Worker-Thread-1] Processing critical data in Memory A...
2026-10-04 09:19:51,154 [INFO] [AgentWorker][Worker-Thread-2] Establishing network connections in Pool B...
2026-10-04 09:19:53,164 [INFO] [AgentWorker][Worker-Thread-2] Need resource [Shared_Memory_A] to write logs.
2026-10-04 09:19:53,164 [INFO] [AgentWorker][Worker-Thread-1] Need resource [Socket_Pool_B] to finish job.
2026-10-04 09:19:53,164 [INFO] [AgentWorker][Worker-Thread-2] WAITING for [Shared_Memory_A]... (Status: BLOCKED)
2026-10-04 09:19:53,164 [INFO] [AgentWorker][Worker-Thread-1] WAITING for [Socket_Pool_B]... (Status: BLOCKED)
```

before-2(`evidence/deadlock/before-2/app.log` 39~42행)는 두 스레드의 출력 순서만 다르고 내용은 같다. 09:19:55.182 에 Thread-1 이 `WAITING for [Socket_Pool_B]`, 09:19:55.187 에 Thread-2 가 `WAITING for [Shared_Memory_A]` 를 남겼다.

## 3. Root Cause Analysis (원인 분석)

### 3-1. 로그로부터 자원 할당 그래프 만들기

마지막 로그를 스레드별로 나누면 "무엇을 쥐고(hold) 무엇을 기다리는가(wait)"가 나온다.

| 스레드 | 쥔 자원 (근거 줄) | 기다리는 자원 (근거 줄) |
|---|---|---|
| Worker-Thread-1 | `Shared_Memory_A` (`LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)`) | `Socket_Pool_B` (`WAITING for [Socket_Pool_B]... (Status: BLOCKED)`) |
| Worker-Thread-2 | `Socket_Pool_B` (`LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)`) | `Shared_Memory_A` (`WAITING for [Shared_Memory_A]... (Status: BLOCKED)`) |

어느 스레드에도 쥔 락을 놓는 로그(release/unlock)는 없다. 그래서 그래프는 다음과 같다.

```
            holds                    waits for
Thread-1 ───────────▶ Shared_Memory_A ◀─────────── Thread-2
    ▲                                                 │
    │ waits for                                holds  │
    └──────────────── Socket_Pool_B ◀─────────────────┘

    Thread-1 → (B 를 쥔) Thread-2 → (A 를 쥔) Thread-1   … 순환
```

`Thread-1 → Thread-2 → Thread-1` 로 대기 관계가 닫힌 고리(cycle)를 이룬다. 각자 상대가 락을 놓기를 기다리는데, 상대도 나를 기다리므로 영원히 진행되지 않는다.
메인 스레드는 `Waiting for worker threads to complete transactions...` 이후 두 워커가 끝나기를 기다린다(join). 그래서 메인도 함께 멈춘다. 2-3 에서 스레드 **3개 모두** `futex_wait_queue` 였던 것과 맞는다.

### 3-2. 교착상태 4대 조건이 모두 성립

| 조건 | 이 사례에서 | 근거 |
|---|---|---|
| 상호 배제 (Mutual Exclusion) | `Shared_Memory_A`, `Socket_Pool_B` 는 한 번에 한 스레드만 쥘 수 있는 락이다 | `CAUTION: Strict resource locking is enabled.`, 각 락을 한 스레드만 `LOCK ACQUIRED` |
| 점유 대기 (Hold and Wait) | 각 스레드가 락 하나를 쥔 채 다른 락을 요청한다 | `(Holding...)` 다음에 `Need resource …` → `WAITING for …` |
| 비선점 (No Preemption) | 상대 스레드가 쥔 락을 강제로 빼앗을 수 없고, 타임아웃도 없다 | 240초 동안 `BLOCKED` 이후 아무 로그 없음 |
| 순환 대기 (Circular Wait) | Thread-1 → Thread-2 → Thread-1 | 3-1 의 그래프 |

### 3-3. OS 동작 원리 — 왜 CPU 가 0 인가

- 사용자 공간의 락(Python `threading.Lock`, pthread mutex)은 경합이 생기면 `futex(FUTEX_WAIT)` 시스템 콜로 커널 대기 큐에 들어간다. 스레드 상태는 `S`(sleeping)가 된다.
- 잠든 스레드는 스케줄러의 실행 큐(run queue)에서 빠진다. 락을 쥔 쪽이 `FUTEX_WAKE` 로 깨워 주기 전까지 CPU 를 받지 못한다. 그래서 CPU 0.0%, utime·stime 고정(1틱 미만), 메인 스레드의 컨텍스트 스위치 횟수 고정이 나온다.
- 이것이 **CPU 100% 로 도는 무한 루프(livelock/busy loop)와 교착을 가르는 기준**이다. 둘 다 "응답 없음"이지만, 교착은 CPU 를 전혀 쓰지 않는 대기다.
- OS 는 사용자 공간 락의 교착을 스스로 감지하거나 풀어 주지 않는다. 프로세스는 정상적인 대기 상태로 보이므로 종료되지도 않는다. 외부 관제가 "살아 있지만 멈춤"을 따로 판정해야 하는 이유다.

## 4. Workaround & Verification (조치 및 검증)

**조치:** 환경변수 `MULTI_THREAD_ENABLE` 을 true → **false** 로 바꿨다. 다른 변수는 그대로 두었다(`MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=50`).

```bash
env/run-case.sh deadlock after-1 --timeout 240 --snap-every 30 MEMORY_LIMIT=512 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=false
```

**Before & After** (각 `evidence/deadlock/<label>/summary.txt`, `monitor.log`)

| 실행 | 설정값 | 관찰 시간 | 결과 | 로그 진행 | 피크 RSS | CPU (monitor.sh) |
|---|---|---|---|---|---|---|
| before-1 | `MULTI_THREAD_ENABLE=true` | 246초 | **교착** — 09:19:53 이후 로그 0줄, LOG_AGE 최대 232초 | 정지 | 16.5MB (이후 13.2MB) | 09:19:50 이후 전 샘플 0.0% |
| before-2 | `MULTI_THREAD_ENABLE=true` | 246초 | **교착** — 09:19:55 이후 로그 0줄, LOG_AGE 최대 237초 | 정지 | 16.5MB (고정) | 09:20:01 이후 전 샘플 0.0% |
| after-1 | `MULTI_THREAD_ENABLE=false` | 241초 | **정상** — 교착 없음 | app.log 220줄(빈 줄 제외), LOG_AGE 최대 3초 | 516.7MB (한도 도달 후 정리 반복) | 0.2~2.4% (기동 직후 첫 샘플 4.0% 제외) |
| after-2 | `MULTI_THREAD_ENABLE=false` | 241초 | **정상** — 교착 없음 | app.log 227줄(빈 줄 제외), LOG_AGE 최대 3초 | 516.7MB (한도 도달 후 정리 반복) | 0.2~2.8% (기동 직후 첫 샘플 8.0% 제외) |

네 실행 모두 시간 제한에서 run-case.sh 가 TERM 으로 멈췄다(exit 143). 차이는 "그동안 일을 했는가"다.

After 에서는 `Scenario Selected: [Healthy System Monitoring]` 이 선택됐다. Thread-A/B/C 작업이 `[Scheduler] All tasks completed.`(09:24:03.316)까지 끝났고, 이후 MemoryWorker·CpuWorker 로그가 시간 제한 직전(09:27:59)까지 계속 나왔다(`evidence/deadlock/after-1/app.log`). `BLOCKED`·`WAITING` 문구는 0건이다.
스레드도 실제로 일했다. 워커 스레드의 utime·stime 이 계속 늘었고, wchan 은 `futex_wait_queue` 가 아니라 `do_select`(타이머 대기)였다(`evidence/deadlock/after-1/snapshots/`).

```
092437-task.txt: tid30 S u=2 s=1 | tid41 S u=0 s=8  | tid42 S u=38  s=0   wchan: 30 futex_wait_queue, 41 do_select, 42 do_select
092800-task.txt: tid30 S u=2 s=1 | tid41 S u=6 s=59 | tid42 S u=215 s=0   wchan: 30 futex_wait_queue, 41 do_select, 42 do_select
```

(위 두 줄은 `/proc/30/task/*/stat` 의 3·14·15번째 필드와 `task/*/wchan` 을 한 줄로 요약한 것이다. 원본은 해당 파일에 있다.)

> 주의: `false` 는 동시 처리를 끄는 우회다. 교착 조건 중 하나(두 스레드가 동시에 락을 쥐는 상황)를 아예 없앨 뿐 결함 자체를 고치지는 않는다. 동시성이 필요한 운영 환경이라면 아래처럼 코드를 고쳐야 한다.

**근본 해결 제안 (코드 수준)** — 4대 조건 중 하나만 깨면 교착은 생기지 않는다.

1. **순환 대기 제거(가장 확실):** 모든 스레드가 같은 전역 순서로 락을 얻게 한다. 예: 항상 `Shared_Memory_A` → `Socket_Pool_B`. Thread-2 처럼 B 를 먼저 쥐는 경로를 없애면 고리가 생길 수 없다.
2. **점유 대기 제거:** 필요한 락을 한 번에 얻거나, 하나라도 못 얻으면 쥔 것을 모두 놓고 다시 시도한다.
3. **비선점 완화:** `lock.acquire(timeout=…)` 로 기다림에 상한을 둔다. 실패하면 쥔 락을 풀고 백오프 후 재시도한다. 이때 로그에 `LOCK TIMEOUT` 을 남겨 관제가 감지할 수 있게 한다.
4. **임계 구역 축소:** "Memory A 에서 데이터 처리" 중에 네트워크(Pool B)를 잡거나, "Pool B 연결" 중에 로그 쓰기(Memory A)를 하지 않게 한다. 락을 쥔 채 다른 자원을 요청하는 경로 자체를 줄인다.
5. **운영 측 보완:** monitor.sh 의 LOG_AGE 가 일정 시간(예: 60초) 넘게 늘면서 CPU≈0 이고 PID 가 살아 있으면 "hang" 경보를 낸다. 이때 `ps -L -o wchan` 스냅샷을 자동으로 남긴다.
