# [Bug] OOM (Memory Leak) - 실행 32초 만에 MemoryGuard 가 워커 프로세스를 SIGKILL 로 자체 종료

> 라벨: `bug` · 재현 환경: Docker 컨테이너(ubuntu:24.04, `--cpus=2 --memory=2g --pids-limit=512 --network none`), arm64 바이너리, 실행 계정 `agent`(uid 1001)
> PID 는 컨테이너 PID 네임스페이스 기준이다. 시각은 KST.

## 1. Description (현상 설명)

**무엇이:** `agent-leak-app` 을 기본 설정(`MEMORY_LIMIT=256`)으로 실행하면, 부트 6단계를 모두 통과한 뒤 약 32초 만에 프로세스가 예고 없이 사라진다. 종료 코드는 137(128+9, SIGKILL)이다.

**언제·어떤 조건에서:** `MEMORY_LIMIT=256`, `CPU_MAX_OCCUPY=50`, `MULTI_THREAD_ENABLE=false` 로 2회 실행했다. 2회 모두 같은 시점(32초)에 같은 로그를 남기고 종료됐다.
- before-1: 2026-10-04 09:13:24 시작 → 09:13:56 종료, 워커 PID 24
- before-2: 2026-10-04 09:13:26 시작 → 09:13:58 종료, 워커 PID 31

**관측 방법:** 같은 컨테이너에서 `monitor.sh -i 5` 로 워커 프로세스를 5초 간격으로 기록했다. 10초 간격으로 `ps`, `top -H`, `/proc/<PID>/status` 스냅샷도 수집했다(`env/run-case.sh`).

부트 단계에서 이미 경고가 있었다. 경고는 나왔지만 기동은 계속됐다.

```
 [ MEMORY ] Limit: 256MB 		[ WARNING: Recommend Over 256MB ]
```
(`evidence/oom/before-1/app.log`)

## 2. Evidence & Logs (증거 자료)

### 2-1. monitor.sh — RSS 가 시간에 따라 선형으로 증가

`evidence/oom/before-1/monitor.log` (전체):

```
[2026-10-04 09:13:24] PID:24 CPU:8.0% MEM:0.8% RSS:16.4MB THREADS:1 STATE:S LOG_AGE:0s
[2026-10-04 09:13:30] PID:24 CPU:0.2% MEM:3.2% RSS:66.4MB THREADS:1 STATE:S LOG_AGE:1s
[2026-10-04 09:13:35] PID:24 CPU:0.2% MEM:4.5% RSS:91.4MB THREADS:1 STATE:S LOG_AGE:3s
[2026-10-04 09:13:40] PID:24 CPU:0.4% MEM:6.9% RSS:141.4MB THREADS:1 STATE:S LOG_AGE:2s
[2026-10-04 09:13:45] PID:24 CPU:0.4% MEM:9.3% RSS:191.4MB THREADS:1 STATE:S LOG_AGE:1s
[2026-10-04 09:13:50] PID:24 CPU:0.2% MEM:10.6% RSS:216.4MB THREADS:1 STATE:S LOG_AGE:3s
[2026-10-04 09:13:55] PID:24 CPU:0.2% MEM:13.0% RSS:266.4MB THREADS:1 STATE:S LOG_AGE:2s
[2026-10-04 09:14:00] PID:- STATUS:NOT_RUNNING
```

- **시작 → 중간 → 종료 직전:** RSS 16.4MB(09:13:24) → 141.4MB(09:13:40) → 266.4MB(09:13:55).
  09:13:30~09:13:55 의 25초 동안 200MB 가 늘었다. 평균 **8.0MB/s** 로 일정하게 증가했다.
- 같은 시간 CPU 는 0.2~0.4%(기동 직후 첫 샘플 8.0% 제외)로 낮았다. 계산이 많아서가 아니라 **메모리만 쌓이는** 패턴이다.
- MEM% 는 컨테이너 cgroup 한도(`/sys/fs/cgroup/memory.max` = 2GiB) 대비 값이다. 그래서 13.0% 에서 끝났다.
  앱이 스스로 정한 한도 `MEMORY_LIMIT=256MB` 와는 기준이 다르다.
- 09:14:00 에 `PID:- STATUS:NOT_RUNNING`. 09:13:55 와 09:14:00 사이에 프로세스가 사라졌다.

before-2 도 같은 모양이다(`evidence/oom/before-2/monitor.log`: 66.4 → 91.4 → … → 266.4MB(09:13:57) → `NOT_RUNNING`(09:14:02)).

### 2-2. 시스템 도구 — 커널이 본 RSS 도 같은 속도로 증가

`/proc/24/status` 스냅샷 3개 (`evidence/oom/before-1/snapshots/0913{29,41,53}-status.txt`):

| 시각 | VmRSS | VmHWM(최대 RSS) | Threads |
|---|---|---|---|
| 09:13:29 | 67,992 kB | 67,992 kB | 1 |
| 09:13:41 | 170,408 kB | 170,408 kB | 1 |
| 09:13:53 | 247,220 kB | 247,220 kB | 1 |

VmRSS 와 VmHWM 이 항상 같다. 한 번도 줄지 않고 최고치를 계속 갱신했다는 뜻이다. 해제가 전혀 일어나지 않았다.

`evidence/oom/before-1/snapshots/091329-ps-ef.txt`: 런처(17)와 워커(24) 2개가 같은 명령줄로 떠 있다. 메모리는 워커에만 쌓인다.

```
$ ps -ef | grep agent-leak-app
UID          PID    PPID  C STIME TTY          TIME CMD
agent         15       8  0 09:13 ?        00:00:00 script -q -f -e -c /opt/agent/agent-leak-app /dev/null
agent         16      15  0 09:13 pts/0    00:00:00 sh -c /opt/agent/agent-leak-app
agent         17      16  0 09:13 pts/0    00:00:00 /opt/agent/agent-leak-app
agent         24      17  0 09:13 pts/0    00:00:00 /opt/agent/agent-leak-app
```

`evidence/oom/before-1/snapshots/091353-top-H.txt` (종료 3초 전):

```
    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
     24 agent     30  10  252780 247220   8648 S   0.0   0.2   0:00.11 agent-l+
```

RES 247,220 kB 이고 %CPU 는 0.0 이다. %MEM 0.2 는 호스트 전체 메모리(122,506 MiB) 대비 값이다. 그래서 수치가 작게 보인다. 이것이 monitor.sh 에서 cgroup 한도 기준을 쓴 이유다.

### 2-3. 프로그램 실행 로그 — 종료 직전·직후

`evidence/oom/before-1/app.log` 30~47행:

```
2026-10-04 09:13:26,552 [INFO] [MemoryWorker] Current Heap: 25MB
2026-10-04 09:13:29,575 [INFO] [MemoryWorker] Current Heap: 50MB
...
2026-10-04 09:13:53,723 [INFO] [MemoryWorker] Current Heap: 250MB
2026-10-04 09:13:56,745 [INFO] [MemoryWorker] Current Heap: 275MB
2026-10-04 09:13:56,746 [CRITICAL] [MemoryGuard] Memory limit exceeded (275MB >= 256MB) / (Recommend Over 256MB)
2026-10-04 09:13:56,746 [CRITICAL] [MemoryGuard] Self-terminating process 24 to prevent system instability.


>>> [SYSTEM] SELF-TERMINATED (Memory Limit Exceeded) <<<

Killed
```

- Heap 은 약 3.02초마다 정확히 25MB 씩 늘었다(25MB 09:13:26.552 → 275MB 09:13:56.745, 30.2초 동안 250MB = 8.3MB/s). monitor 의 RSS 증가 속도(8.0MB/s)와 맞는다.
  RSS 266.4MB = 기동 직후 RSS 16.4MB + Heap 250MB 이다.
- `Self-terminating process 24` 의 24 는 monitor·ps 가 본 워커 PID 와 같다. **앱이 자기 자신을 종료했다.**
- 종료 코드: `evidence/oom/before-1/exit.txt` → `exit_code=137 ended_at=2026-10-04 09:13:56`. `Killed` 는 상위 셸이 "자식이 SIGKILL 로 죽었다"고 출력한 것이다.
- 커널 OOM killer 가 아니다. 컨테이너 cgroup 한도 2GiB 중 266MB 만 쓰고 있었다. 커널이 개입할 상황이 아니었고, 로그에도 MemoryGuard 가 직접 종료했다고 나온다.

## 3. Root Cause Analysis (원인 분석)

**결함: 해제되지 않는 힙 누수.** MemoryWorker 가 약 3초마다 25MB 를 할당하고 참조를 계속 붙잡고 있다. 그래서 가비지 컬렉터가 회수할 수 없다.
증거는 세 가지다. VmRSS 가 단조 증가하고, VmHWM 과 항상 같으며, CPU 는 거의 0 이다. 일을 하지 않으면서 메모리만 쌓는 전형적인 누수 패턴이다.

**OS 동작 원리**

1. **가상 메모리와 RSS.** 프로세스는 힙(malloc/Python 객체 할당)으로 가상 주소를 받는다. 실제로 쓰기 시작한 페이지만 물리 메모리에 올라가 RSS(Resident Set Size)에 잡힌다. 누수된 객체도 "살아 있는 참조"이므로 페이지가 회수되지 않는다. 그래서 RSS 가 할당량만큼 그대로 늘어난다(Heap 250MB ↔ RSS +250MB).
2. **cgroup 메모리 한도.** 컨테이너의 cgroup v2 `memory.max`(2GiB)는 이 컨테이너 프로세스들의 RSS·페이지 캐시 합계 상한이다. 앱이 이 한도에 닿았다면 커널이 먼저 회수를 시도하고, 그래도 부족하면 **커널 OOM killer** 가 cgroup 안에서 점수(oom_score)가 높은 프로세스를 SIGKILL 했을 것이다.
3. **MemoryGuard(앱 정책) vs 커널 OOM killer.**

   | | 앱 MemoryGuard | 커널 OOM killer |
   |---|---|---|
   | 기준 | 앱이 센 Heap ≥ `MEMORY_LIMIT` | 커널 또는 cgroup 메모리가 실제로 부족 |
   | 시점 | 한도에 닿은 즉시(예방) | 이미 부족해진 뒤(사후) |
   | 대상 | 자기 자신(PID 24) | 점수가 높은 아무 프로세스(다른 서비스일 수도 있음) |
   | 흔적 | 앱 로그에 원인·수치·PID 를 남김 | 앱은 로그 없이 사라지고 `dmesg` 에만 남음 |

   MemoryGuard 가 자기 자신을 먼저 끊는 이유가 여기 있다. 누수가 계속되면 언젠가 커널 OOM killer 가 개입한다. 그때는 같은 서버의 **다른 프로세스**가 희생될 수 있고, 메모리 부족 동안 스왑과 페이지 회수 때문에 시스템 전체가 느려진다. 그 전에 원인 프로세스만 정리해서 피해 범위를 그 프로세스 하나로 묶는 것이다. 이번 실행에서도 커널 한도(2GiB)의 13% 지점에서 앱이 먼저 끊었다.

4. **왜 "예고 없이" 보였나.** SIGKILL 은 잡거나 무시할 수 없다. 그래서 정리 코드가 돌 기회가 없다. 실제로 출력이 파일로 리다이렉트된 탐색 실행(`evidence/00-explore/boot.txt`)에서는 마지막 `>>> [SYSTEM] SELF-TERMINATED …` 줄이 stdout 버퍼에 남은 채 사라졌다. 의사 터미널로 실행해야 이 줄이 보였다(`evidence/00-explore/oom-256-tty.txt`). 운영에서 이런 종료를 놓치지 않으려면 핵심 로그를 stderr 나 파일 로거로 즉시 flush 해야 한다.

## 4. Workaround & Verification (조치 및 검증)

**조치:** 환경변수 `MEMORY_LIMIT` 을 256 → **512**(허용 최대값)로 올렸다. 다른 변수는 그대로 두었다(`CPU_MAX_OCCUPY=50`, `MULTI_THREAD_ENABLE=false`).

```bash
env/run-case.sh oom after-1 --timeout 300 --snap-every 60 MEMORY_LIMIT=512 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=false
```

**Before & After** (생존 시간·종료 원인·피크 RSS 는 각 `evidence/oom/<label>/summary.txt`. 피크 CPU 는 `monitor.log` 에서 **워커 PID 샘플만**으로 다시 계산한 값이다. summary 의 `peak_cpu_pct` 는 런처의 첫 샘플(`PID:17 CPU:2.0% RSS:1.7MB`)을 포함한 경우가 있어 쓰지 않았다)

| 실행 | 설정값 | 생존 시간 | 종료 원인 | 피크 RSS | 피크 CPU (워커) |
|---|---|---|---|---|---|
| before-1 | `MEMORY_LIMIT=256` | **32초** | MemoryGuard 자체 종료, exit 137 (SIGKILL) | 266.4MB | 8.0% (기동 직후) |
| before-2 | `MEMORY_LIMIT=256` | **32초** | MemoryGuard 자체 종료, exit 137 (SIGKILL) | 266.4MB | 0.4% |
| after-1 | `MEMORY_LIMIT=512` | **303초 이상** | 종료 없음 → 시간 제한에서 run-case.sh 가 TERM(exit 143) | 516.7MB | 4.0% (기동 직후) |
| after-2 | `MEMORY_LIMIT=512` | **303초 이상** | 종료 없음 → 시간 제한에서 run-case.sh 가 TERM(exit 143) | 516.7MB | 4.0% (기동 직후) |
| (보조) low128-1 | `MEMORY_LIMIT=128` | 18초 | `Memory limit exceeded (150MB >= 128MB)`, exit 137 | 141.4MB | 0.4% |
| (보조) low128-2 | `MEMORY_LIMIT=128` | 18초 | `Memory limit exceeded (150MB >= 128MB)`, exit 137 | 141.4MB | 0.6% |

- 생존 시간은 Before 평균 32초에서 After 303초 이상으로 늘었다(303÷32 ≈ 9.5배 이상). After 는 시간 제한까지 죽지 않았다.
- 보조 실험: 같은 OOM 동작 안에서 128MB 는 18초, 256MB 는 32초였다. 누수 속도가 일정하다는 뜻이다(한도와 생존 시간은 선형이지만 정비례는 아니다). 그래서 **256MB 이하의 OOM 동작 안에서는** 한도를 올려도 종료 시점이 뒤로 밀릴 뿐 결국 도달한다. 512MB 에서 죽지 않은 이유는 아래처럼 앱이 다른 동작을 골랐기 때문이다.

**After 에서 실제로 일어난 일 — 같은 누수, 다른 대응.** 512MB 에서도 Heap 은 똑같이 25MB 씩 늘었다. 다만 한도에서 종료하지 않고 캐시를 비웠다(`evidence/oom/after-1/app.log`).

```
2026-10-04 09:14:34,910 [INFO] >>> Scenario Selected: [Healthy System Monitoring]
2026-10-04 09:15:36,346 [WARNING] [MemoryWorker] Memory Usage Reached Limit (525MB). Starting cleanup...
>>> [SYSTEM] MEMORY RECOVERED (Cache Cleared) <<<
```

300초 동안 이 정리가 4번(09:15:36, 09:16:41, 09:17:47, 09:18:52) 일어났다. monitor.log(30초 간격 발췌)는 RSS 가 톱니 모양으로 오르내린다(`evidence/oom/after-1/monitor.log`).

```
[2026-10-04 09:15:03] PID:27 CPU:1.0% MEM:13.0% RSS:266.6MB THREADS:3 STATE:S LOG_AGE:0s
[2026-10-04 09:15:33] PID:27 CPU:1.2% MEM:25.2% RSS:516.7MB THREADS:3 STATE:S LOG_AGE:0s
[2026-10-04 09:16:03] PID:27 CPU:1.0% MEM:10.6% RSS:216.6MB THREADS:3 STATE:S LOG_AGE:0s
[2026-10-04 09:16:33] PID:27 CPU:1.2% MEM:22.8% RSS:466.6MB THREADS:3 STATE:S LOG_AGE:1s
```

탐색에서 확인한 사실도 있다. `MEMORY_LIMIT` 이 256 이하이면 배너에 `WARNING: Recommend Over 256MB` 가 뜨고 MemoryGuard 종료 동작을 탄다. 257 이상이면 `[ OK ]` 와 함께 `Scenario Selected: [Healthy System Monitoring]` 이 선택된다(`evidence/00-explore/probe-banner.txt`). 384MB(`evidence/00-explore/d-mem384/`)와 512MB 에서는 한도에서 정리하는 동작을 직접 확인했다. 즉 이번 조치가 효과를 낸 것은 "여유 메모리가 늘어서"만이 아니다. **누수 중인 메모리를 한도에서 비우는 경로로 들어갔기 때문**이다.

**근본 해결 제안 (코드 수준)**

1. **누수 제거:** MemoryWorker 가 쌓는 컨테이너(list/dict 등)에 상한을 둔다. 다 쓴 항목은 `del`/`pop` 으로 참조를 끊는다. 캐시라면 `functools.lru_cache(maxsize=…)` 나 크기 제한 deque 처럼 **크기가 정해진 자료구조**를 쓴다.
2. **정리 경로를 기본으로:** 한도의 80% 같은 경고 수위에서 먼저 정리한다. 자체 종료는 정리가 실패할 때만 하는 최후 수단으로 둔다.
3. **관측 가능성:** 종료 직전 로그는 stderr 나 파일 로거로 즉시 flush 한다. SIGKILL 대신 정리 후 `sys.exit(비0)` 으로 끝내 종료 원인이 상위 관리자(systemd 등)에 남게 한다.
4. **운영 측 보완:** monitor.sh 에 RSS 증가 기울기(MB/분) 경보를 추가해 한도 도달 **전에** 알린다(README 「개선 방향」 참고).
