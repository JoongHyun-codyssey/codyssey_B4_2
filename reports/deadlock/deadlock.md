# [Bug] Deadlock - 두 작업 스레드의 상반된 락 획득 순서로 작업 진행 중단

## 1. Description (현상 설명)

2026-10-21(KST), Docker 컨테이너에서 일반 사용자 `agent-admin`으로 `agent-leak-app-arm64`를 실행했다. `MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=30`, `MULTI_THREAD_ENABLE=true` 조건에서 두 작업 스레드가 각자 확보한 자원을 유지한 채 상대 자원을 기다리는 로그를 출력했다. 프로세스는 종료되지 않았지만 작업 로그는 더 이상 진행되지 않았다.

14:25:13의 `WAITING ... (Status: BLOCKED)`가 마지막 작업 로그였으며, 14:30:54와 14:31:04의 측정에서도 PID·스레드가 존재했다. 두 측정 사이 CPU 시간·RSS·로그 줄 수는 변하지 않았다. 마지막 로그부터 두 번째 측정까지 약 5분 51초 동안 새 로그가 없었다.

`MULTI_THREAD_ENABLE`만 `false`로 변경해 재실행하자 앱은 `Healthy System Monitoring` 시나리오를 선택하고 `All tasks completed.`를 출력했다. 이후 CPU·메모리 작업 로그가 이어졌다. 관찰 구간에서 기존 교착 현상을 회피했다.

| 항목 | 실험 환경 |
| --- | --- |
| OS / 아키텍처 | Ubuntu 22.04 / Linux aarch64 |
| 격리 환경 | Docker 컨테이너 `agent-leak-lab` |
| 앱 실행 계정 | `agent-admin`, UID 1000 |
| 바이너리 | `/home/agent-admin/agent-leak-app/agent-leak-app-arm64` |
| 고정 조건 | `MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=30` |
| 변경 조건 | `MULTI_THREAD_ENABLE=true → false` |
| 관측 도구 | `monitor.sh`, `ps -ef`, `ps -L`, 실행 로그 |

## 2. Evidence & Logs (증거 자료)

### 2.1 재현 경로

필수 디렉터리·키 파일·환경변수가 준비된 컨테이너에서, 다른 앱 실행이 종료되고 15034 포트가 비어 있는 것을 확인한 뒤 실행했다.

터미널 A에서 관제:

```bash
bash /mission-scripts/monitor.sh \
  | tee -a /mission-docs/logs/deadlock/before-monitor.log
```

터미널 B에서 앱 실행:

```bash
runuser -u agent-admin -- bash -lc '
set -e
export MEMORY_LIMIT=512
export CPU_MAX_OCCUPY=30
export MULTI_THREAD_ENABLE=true
cd "$AGENT_HOME"
printf "[START] %s\n" "$(date "+%Y-%m-%d %H:%M:%S %Z")"
env | sort | grep -E "^(MEMORY_LIMIT=|CPU_MAX_OCCUPY=|MULTI_THREAD_ENABLE=)"
exec ./agent-leak-app-arm64
' 2>&1 | tee -a /mission-docs/logs/deadlock/before-console.log

APP_EXIT=${PIPESTATUS[0]}
printf '[END] %s EXIT_CODE=%s\n' \
  "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$APP_EXIT" \
  | tee -a /mission-docs/logs/deadlock/before-console.log
```

로그인 셸에서 프로파일을 읽은 뒤 환경변수를 지정했다. After는 위 명령의 `MULTI_THREAD_ENABLE=false` 및 로그 파일명을 `after-console.log`, `after-monitor.log`로 변경해 별도 기록했다. `tee -a`는 덧붙이므로 추가 실행 시 실행 경계와 파일명을 구분해야 한다.

### 2.2 Before 설정 및 마지막 로그

시작 기록은 `2026-10-21 14:25:04 KST`이며, 부팅 화면에서 `Concurrency: True [WARNING]`, `POTENTIAL DEADLOCK IN CONCURRENT MODE`를 확인했다.

핵심 로그 발췌:

```text
2026-10-21 14:25:11,379 [INFO] [AgentWorker][Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)
2026-10-21 14:25:11,379 [INFO] [AgentWorker][Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)
2026-10-21 14:25:13,398 [INFO] [AgentWorker][Worker-Thread-1] Need resource [Socket_Pool_B] to finish job.
2026-10-21 14:25:13,398 [INFO] [AgentWorker][Worker-Thread-2] Need resource [Shared_Memory_A] to write logs.
2026-10-21 14:25:13,398 [INFO] [AgentWorker][Worker-Thread-1] WAITING for [Socket_Pool_B]... (Status: BLOCKED)
2026-10-21 14:25:13,399 [INFO] [AgentWorker][Worker-Thread-2] WAITING for [Shared_Memory_A]... (Status: BLOCKED)
```

부팅 경고 자체를 교착상태의 증명으로 사용하지 않았다. 실제 락 확보·상대 자원 대기 로그와 OS 관측을 함께 분석했다.

### 2.3 PID 존재와 관제 정체

`ps -ef | grep '[a]gent-leak-app-arm64'`에서 일반 사용자 소유의 부모 PID `57165`, 자식 PID `57171`을 확인했다. root 소유의 `runuser` PID `57163`과 앱 PID를 구분했다.

관제에서 자식 프로세스 스레드는 14:25:11에 3개로 증가했고, 이후 제공된 구간에서 RSS 약 16.41MiB가 유지됐다. 후속 스레드 측정의 RSS는 16852KiB(약 16.46MiB)였으며 두 후속 측정 사이에는 변하지 않았다. 전체 관찰 기간의 메모리가 한 바이트도 변하지 않았다는 의미는 아니다.

앱은 그대로 두고 관제만 중지한 뒤 다음처럼 스레드를 확인했다.

```bash
ps -L -p 57165,57171 \
  -o pid,ppid,lwp,nlwp,stat,pcpu,time,rss,wchan:28,comm

wc -l /mission-docs/logs/deadlock/before-console.log
tail -n 4 /mission-docs/logs/deadlock/before-console.log
```

10초 간격으로 두 번 측정한 결과를 정리했다.

| 항목 | 14:30:54 KST | 14:31:04 KST |
| --- | --- | --- |
| 자식 PID | 57171 | 동일 |
| 자식 LWP | 57171, 57235, 57236 | 동일 |
| 자식 NLWP | 3 | 3 |
| 자식 스레드 STAT | 모두 `SNl+` | 동일 |
| 자식 스레드 %CPU | 모두 0.0% | 동일 |
| 자식 스레드 TIME | 모두 `00:00:00` | 동일 |
| 자식 RSS | 16852KiB | 동일 |
| WCHAN | 모두 `-` | 동일 |
| 콘솔 로그 줄 수 | 46 | 46 |
| 마지막 작업 로그 | 14:25:13의 `BLOCKED` | 동일 |

`TIME`은 경과 시간이 아니라 누적 CPU 시간이며 초 단위 표시다. `00:00:00`을 CPU를 전혀 사용하지 않았다는 의미로 해석하지 않는다. `ps`의 `%CPU` 및 monitor의 `CPU_AVG`는 실행 기간 평균이므로, 이 수치만으로 순간 CPU 사용 여부를 판단하지 않는다.

스레드는 같은 프로세스의 주소 공간을 공유하므로 각 행에 나타난 RSS를 합산하지 않는다. OS LWP와 로그의 `Worker-Thread-1/2` 사이의 정확한 일대일 대응도 확인하지 못했다.

### 2.4 After 설정 및 작업 진행

After는 14:34:27(KST)에 시작했다. `MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=30`, `MULTI_THREAD_ENABLE=false`를 확인했고, `Concurrency: False [OK]`가 출력됐다.

```text
2026-10-21 14:34:29,887 [INFO] >>> Scenario Selected: [Healthy System Monitoring]
2026-10-21 14:34:30,875 [INFO] [Thread-A] Resumed. Calculating... (100%)
2026-10-21 14:34:30,930 [INFO] [Thread-B] Resumed. Calculating... (100%)
2026-10-21 14:34:30,984 [INFO] [Thread-C] Resumed. Calculating... (100%)
2026-10-21 14:34:31,036 [INFO] [Scheduler] All tasks completed.
2026-10-21 14:34:31,055 [INFO] [MemoryWorker] Current Heap: 25MB
2026-10-21 14:34:31,055 [INFO] [CpuWorker] Started. Maximum CPU Limit: 30%
2026-10-21 14:34:42,563 [INFO] [CpuWorker] Peak reached (30.00%). Starting cooldown...
2026-10-21 14:34:58,200 [INFO] [CpuWorker] Cooldown complete (5.00%). Resuming load increase...
2026-10-21 14:35:31,748 [INFO] [MemoryWorker] Current Heap: 525MB
2026-10-21 14:35:31,749 [WARNING] [MemoryWorker] Memory Usage Reached Limit (525MB). Starting cleanup...
2026-10-21 14:35:31,761 [INFO] [System] Memory Cache Flushed. Process Stabilized.
```

`All tasks completed.`는 시작 기록 후 약 4초에 출력됐다. 마지막 제공 로그는 14:35:31로, 시작 후 약 64초까지 앱의 작업 로그가 진행됐다. 메모리 cleanup 경고와 완료 로그는 추가 동작의 증거이며, 이번 캡처의 프로세스 종료 로그는 아니다.

After 관제의 부모 PID는 `60258`, 자식 PID는 `60273`이다. 자식 RSS는 14:34:33의 41.55MiB에서 14:35:00의 266.58MiB까지 변했고, CPU_AVG는 제공된 해당 구간에서 약 1.1~1.4%였다. 자식 스레드 수는 3이었다. `false`를 OS 스레드가 하나뿐이라는 뜻으로 해석하지 않는다.

### 2.5 증거 파일

원본 로그:

- [before-console.log](../docs/logs/deadlock/before-console.log)
- [before-monitor.log](../docs/logs/deadlock/before-monitor.log)
- [before-thread-check.log](../docs/logs/deadlock/before-thread-check.log)
- [after-console.log](../docs/logs/deadlock/after-console.log)
- [after-monitor.log](../docs/logs/deadlock/after-monitor.log)

스크린샷은 실제 저장된 이름을 사용한다.

- [01-before-console.png](../docs/screenshots/deadlock/01-before-console.png): True 설정, 락 확보와 순환 대기
- [01-before-monitor.png](../docs/screenshots/deadlock/01-before-monitor.png): PID 유지, 스레드 증가 및 관제 수치
- [03-before-thread-check.png](../docs/screenshots/deadlock/03-before-thread-check.png): PID, 스레드, 10초 전후 로그 정체
- [04-after-console.png](../docs/screenshots/deadlock/04-after-console.png): False 설정, 정상 시나리오 시작
- [04-after-console2.png](../docs/screenshots/deadlock/04-after-console2.png): 작업 완료 및 후속 로그
- [04-after-monitor.png](../docs/screenshots/deadlock/04-after-monitor.png): After PID 유지와 자원 사용 변화

## 3. Root Cause Analysis (원인 분석)

### 3.1 락 획득 순서 불일치에 따른 순환 대기

| 작업 스레드 | 보유한 자원 | 추가로 필요한 자원 | 그 자원의 보유자 |
| --- | --- | --- | --- |
| Worker-Thread-1 | Shared_Memory_A | Socket_Pool_B | Worker-Thread-2 |
| Worker-Thread-2 | Socket_Pool_B | Shared_Memory_A | Worker-Thread-1 |

로그에 따르면 두 스레드는 반대 순서로 자원을 확보하려 한다. 기존 자원을 유지한 채 상대 자원을 기다리면 어느 쪽도 다음 단계로 진행하거나 정상 해제 지점에 도달하지 못하는 순환 대기가 생긴다. 마지막 `BLOCKED` 로그와 장시간 로그 정체, 살아 있는 PID·스레드를 종합하면 교착상태라는 진단을 강하게 뒷받침한다.

### 3.2 교착상태 4대 조건과 증거의 범위

| 조건 | 의미 | 이번 실험의 근거 |
| --- | --- | --- |
| 상호 배제 | 자원을 동시에 함께 사용할 수 없음 | 각 자원의 LOCK ACQUIRED와 다른 스레드의 대기 로그에 부합 |
| 점유 대기 | 이미 자원을 가진 채 추가 자원을 기다림 | Holding 이후 상대 자원에 대한 WAITING 로그 |
| 비선점 | 다른 스레드가 보유 자원을 임의로 회수하지 못함 | 관측 구간에서 보유 자원의 회수·해제나 타임아웃 없이 대기 지속. 구현 정책 자체는 미확인 |
| 순환 대기 | 서로의 자원을 기다리는 고리 존재 | Thread-1은 B, Thread-2는 A를 기다림 |

OS의 `S`는 이벤트를 기다리는 수면 상태이며 그 자체로 Deadlock을 뜻하지 않는다. 이번에는 앱 로그에서 구체적인 자원 보유·대기 관계를 확보했기 때문에 단순 유휴 상태와 구분했다.

`WCHAN=-`였으므로 futex 등 구체적인 커널 대기 함수는 확인하지 못했다. 접근 권한·실행 환경 등 여러 요인이 있을 수 있지만 원인은 확정하지 않았다. futex를 관측했다고 보고하지 않는다.

포트의 `LISTENING`은 소켓이 열려 있다는 증거이며 작업 정상 진행의 증거가 아니다. 이번 실험은 로그상의 작업 정체를 검증한 것으로, 별도의 요청·응답 시험까지 수행한 것은 아니다.

바이너리 역분석이나 소스 검토는 하지 않았다. 구체적인 락 구현 및 무한 대기의 내부 코드 경로를 직접 증명한 것은 아니며, 로그와 OS 관측에 근거한 진단이다.

## 4. Workaround & Verification (조치 및 검증)

### 4.1 임시 조치

Before 증거를 수집한 뒤 수동 종료임을 `[MANUAL STOP]`으로 기록하고 SIGTERM으로 기존 앱을 종료하도록 절차를 분리했다. 이러한 수동 종료 이후의 종료 코드를 교착상태의 자동 보호 종료로 해석하지 않는다.

다음 실행에서 `MULTI_THREAD_ENABLE=true → false`만 변경하고 메모리·CPU 설정은 유지했다. 이미 대기 중인 프로세스에 환경변수를 바꿔 교착을 해소한 것이 아니라, **설정을 변경해 새 프로세스를 실행한 회피 조치**다.

### 4.2 Before & After

| 항목 | Before | After |
| --- | --- | --- |
| MULTI_THREAD_ENABLE | true | false |
| 고정 환경변수 | MEMORY_LIMIT=512, CPU_MAX_OCCUPY=30 | 동일 |
| 앱 작업 로그 | 두 Worker가 상대 자원 대기, BLOCKED | Scheduler의 All tasks completed |
| 로그 진행 | 14:25:13 이후 14:31:04까지 새 로그 없음 | 시작 후 약 64초까지 후속 로그 진행 |
| PID | 57165 / 57171 존재 | 60258 / 60273 존재 |
| 스레드·자원 | 두 후속 측정에서 CPU 시간·RSS·스레드 동일 | 관제 RSS 변화 및 후속 작업 진행 |
| 판정 | 교착상태를 뒷받침하는 순환 대기·정체 확보 | 관찰 구간에서 해당 교착 현상 회피 |

After는 다른 시나리오와 작업 이름을 출력했다. 따라서 같은 멀티스레드 트랜잭션을 수정해 완료한 것으로 해석하지 않는다. 확인한 것은 설정 변경 후 앱이 선택한 실행 경로에서 작업이 완료되고 후속 로그가 진행됐다는 사실이다. 장시간 안정성이나 모든 입력에서의 교착 해소를 검증한 것은 아니다.

### 4.3 근본적 해결 제안

소스 수정이 가능한 단계에서는 모든 실행 경로에서 자원 잠금 순서를 A → B처럼 일관되게 맞춰 순환 대기를 방지하는 방안을 우선 검토한다. 타임아웃 또는 try-lock을 사용할 경우 이미 잡은 락 해제와 부분 작업 정리, 재시도 정책까지 설계해야 한다. 임계 구역을 줄이고 락 보유·대기 시간을 관측하는 것도 제안한다.

멀티스레드 모드를 끄는 것은 동시성 경로를 회피하는 임시 조치이며 구현 결함을 수정한 것은 아니다. 처리량 변화는 이번 실험에서 측정하지 않았다.

참고 문서:

- [procps ps(1): 스레드, 상태, CPU 시간](https://man7.org/linux/man-pages/man1/ps.1.html)
- [Linux proc_pid_wchan(5): 대기 위치 및 접근 권한](https://man7.org/linux/man-pages/man5/proc_pid_wchan.5.html)
- [Oracle Multithreaded Programming Guide: Avoiding Deadlock](https://docs.oracle.com/cd/E36784_01/html/E36868/guide-35930.html)
