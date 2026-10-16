# [Bug] OOM — Heap 증가로 MemoryGuard 종료, MEMORY_LIMIT 변경 후 캐시 정리 및 생존 확인

## 1. Description (현상 설명)

2026-10-16 KST, Ubuntu 22.04.5 LTS ARM64 컨테이너에서 제공 앱을 일반 사용자로 실행했다. `MEMORY_LIMIT=256`, `CPU_MAX_OCCUPY=30`, `MULTI_THREAD_ENABLE=false` 조건에서 앱 로그의 Heap이 25 MB 단위로 증가했다.

Heap이 275 MB에 도달하자 `MemoryGuard`가 설정값 256 MB 초과를 감지하고 PID 36059의 자체 종료를 기록했다. 실행 명령의 START부터 END까지 33초였으며 종료 코드는 137이었다.

CPU 및 멀티스레드 설정을 유지하고 `MEMORY_LIMIT`만 512로 변경해 재실행했다. 이 실행에서는 Heap 525 MB에서 캐시 정리 및 메모리 회복 로그가 출력되었고, 이후 Heap 25 MB부터 작업이 다시 진행됐다. 별도 `ps` 확인에서 주요 프로세스는 경과 시간 09:01에도 생존했다.

### 실행 환경

| 항목 | 실제 환경 |
| --- | --- |
| 프로젝트 | `codyssey_b4_2` |
| 호스트 | macOS / Apple Silicon |
| 컨테이너 | `agent-leak-lab` |
| 운영체제 / 아키텍처 | Ubuntu 22.04.5 LTS / aarch64 |
| 앱 실행 계정 | `agent-admin`, UID 1000 |
| 실행 파일 | `/home/agent-admin/agent-leak-app/agent-leak-app-arm64` |
| AGENT_HOME | `/home/agent-admin/agent-leak-app` |
| AGENT_PORT | `15034` |
| AGENT_UPLOAD_DIR | `$AGENT_HOME/upload_files` |
| AGENT_KEY_PATH | `$AGENT_HOME/api_keys` |
| AGENT_LOG_DIR | `/mission-docs/logs/setup` |
| 시간대 | KST, UTC+09:00 |
| 관측 도구 | `scripts/monitor.sh`, `ps`, 앱 실행 로그 |
| 관제 주기 | 각 측정 후 1초 대기, 명령 실행 시간에 따라 실제 간격은 1초보다 길 수 있음 |

## 2. Evidence & Logs (증거 자료)

### 2.1 재현 경로

사전 조건으로 일반 사용자, 필수 디렉터리, 지정된 테스트 키, 환경변수 및 포트 사용 가능 여부를 확인했다. 앱 부팅 검사도 통과했다.

각 실행 전에 별도 터미널에서 관제를 시작했다.

~~~bash
# Before
bash /mission-scripts/monitor.sh   | tee -a /mission-docs/logs/oom/controlled-before-monitor.log

# After: Before 관제를 종료한 뒤 별도로 시작
bash /mission-scripts/monitor.sh   | tee -a /mission-docs/logs/oom/controlled-after-monitor.log
~~~

앱 실행은 아래 형식을 사용했다. Before는 MEMORY_LIMIT=256, After는 512로 설정했고 나머지 실험 조건은 유지했다.

~~~bash
# Before 실행. After에서는 MEMORY_LIMIT 값과 두 로그 파일 경로만 변경한다.
runuser -u agent-admin -- bash -lc '
set -e
export MEMORY_LIMIT=256
export CPU_MAX_OCCUPY=30
export MULTI_THREAD_ENABLE=false
cd "$AGENT_HOME"

printf "[START] %s\n" "$(date "+%Y-%m-%d %H:%M:%S %Z")"
env | sort | grep -E "^(AGENT_|MEMORY_LIMIT=|CPU_MAX_OCCUPY=|MULTI_THREAD_ENABLE=)"
exec ./agent-leak-app-arm64
' 2>&1 | tee -a /mission-docs/logs/oom/controlled-before-console.log

APP_EXIT=${PIPESTATUS[0]}
printf '[END] %s EXIT_CODE=%s\n'   "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$APP_EXIT"   | tee -a /mission-docs/logs/oom/controlled-before-console.log
~~~

After의 콘솔 저장 경로는 `controlled-after-console.log`이다. After 관측 시점에는 앱이 실행 중이었으므로 END 및 자연 종료 코드는 확인되지 않았다.

### 2.2 Before: 메모리 증가 및 보호 종료

실행 설정은 메모리 256 MB, CPU 설정 30, 멀티스레드 false였다.

| 관제 시각(KST) | PID | RSS(MiB) | CPU_AVG |
| --- | ---: | ---: | ---: |
| 15:19:29 | 36059 | 191.38 | 0.5% |
| 15:19:32 | 36059 | 216.38 | 0.5% |
| 15:19:36 | 36059 | 241.38 | 0.5% |
| 15:19:39 | 36059 | 266.39 | 0.5% |
| 15:19:41 | 36059 | 291.39 | 0.5% |

마지막 관측 RSS 291.39 MiB는 앱 로그의 Heap 275 MB와 별개 지표다. 앱 로그의 MB 표기는 원문을 유지했으며, 두 값을 동일한 측정 범위로 취급하지 않았다.

핵심 실행 로그:

~~~text
[START] 2026-10-16 15:19:08 KST

2026-10-16 15:19:10,846 [INFO] [MemoryWorker] Current Heap: 25MB
2026-10-16 15:19:13,879 [INFO] [MemoryWorker] Current Heap: 50MB
2026-10-16 15:19:38,139 [INFO] [MemoryWorker] Current Heap: 250MB
2026-10-16 15:19:41,157 [INFO] [MemoryWorker] Current Heap: 275MB
2026-10-16 15:19:41,159 [CRITICAL] [MemoryGuard] Memory limit exceeded (275MB ≥ 256MB) / (Recommend Over 256MB)
2026-10-16 15:19:41,160 [CRITICAL] [MemoryGuard] Self-terminating process 36059 to prevent system instability.
Killed
[END] 2026-10-16 15:19:41 KST EXIT_CODE=137
~~~

START부터 END까지의 실행 시간은 33초다.

### 2.3 After: 512 MB 설정과 메모리 회복 로그

실제 실행 환경 출력에서 변경값과 고정값을 확인했다.

~~~text
[START] 2026-10-16 15:23:41 KST
CPU_MAX_OCCUPY=30
MEMORY_LIMIT=512
MULTI_THREAD_ENABLE=false
~~~

관제에서는 PID 37449가 경과 시간 103초에도 존재했고, 해당 시점의 RSS는 316.57 MiB였다. 이후 확보된 마지막 관제 구간은 다음과 같다.

| 관제 시각(KST) | PID | RSS(MiB) | ELAPSED_s |
| --- | ---: | ---: | ---: |
| 15:25:24 | 37449 | 316.57 | 103 |
| 15:27:45 | 37449 | 391.58 | 243 |
| 15:27:47 | 37449 | 416.58 | 245 |
| 15:27:50 | 37449 | 441.58 | 249 |
| 15:27:53 | 37449 | 466.58 | 252 |
| 15:27:56 | 37449 | 491.59 | 255 |

이 구간에서는 메모리가 증가하고 있었다. 이후 앱 로그에서는 Heap이 525 MB에 도달했을 때 정리한 뒤 다시 작업하는 동작이 확인됐다.

~~~text
2026-10-16 15:30:12,969 [INFO] [MemoryWorker] Current Heap: 525MB
2026-10-16 15:30:12,970 [WARNING] [MemoryWorker] Memory Usage Reached Limit (525MB). Starting cleanup...
2026-10-16 15:30:12,982 [INFO] [System] Memory Cache Flushed. Process Stabilized.

>>> [SYSTEM] MEMORY RECOVERED (Cache Cleared) <<<

2026-10-16 15:30:18,027 [INFO] [MemoryWorker] Current Heap: 25MB
~~~

다음 주기에서도 동일한 유형의 로그가 확인됐다.

~~~text
2026-10-16 15:31:18,502 [INFO] [MemoryWorker] Current Heap: 525MB
2026-10-16 15:31:18,503 [WARNING] [MemoryWorker] Memory Usage Reached Limit (525MB). Starting cleanup...
2026-10-16 15:31:18,512 [INFO] [System] Memory Cache Flushed. Process Stabilized.

>>> [SYSTEM] MEMORY RECOVERED (Cache Cleared) <<<

2026-10-16 15:31:23,546 [INFO] [MemoryWorker] Current Heap: 25MB
~~~

### 2.4 생존 및 진행 확인

실행 로그가 계속 증가했고, 별도 명령으로 프로세스 상태도 확인했다.

~~~bash
ps -u agent-admin -o pid,ppid,stat,etime,args
~~~

~~~text
  PID  PPID STAT     ELAPSED COMMAND
37443 37441 S+         09:01 ./agent-leak-app-arm64
37449 37443 SNl+       09:01 ./agent-leak-app-arm64
~~~

PID 존재만으로 정상 진행을 판단하지 않았다. 캐시 정리 이후 Heap 기록과 CpuWorker 로그가 이어지는 사실을 함께 확인했다.

주요 프로세스에서 THREADS=3이 관측됐지만, 실제 실행 설정은 MULTI_THREAD_ENABLE=false였다. 해당 설정이 모든 내부 스레드를 비활성화한다고 가정하지 않았다.

### 2.5 증거 파일

아래 경로는 프로젝트에 배치한 증거 파일을 기준으로 한다. 이 리포트는 `reports/oom.md`로 저장한다.

| 내용 | 증거 |
| --- | --- |
| Before 앱 로그 | [controlled-before-console.log](../docs/logs/oom/controlled-before-console.log) |
| Before 관제 로그 | [controlled-before-monitor.log](../docs/logs/oom/controlled-before-monitor.log) |
| After 앱 로그 | [controlled-after-console.log](../docs/logs/oom/controlled-after-console.log) |
| After 관제 로그 | [controlled-after-monitor.log](../docs/logs/oom/controlled-after-monitor.log) |
| Before 메모리 초과 및 종료 | [04-controlled-before-console.png](../docs/screenshots/oom/04-controlled-before-console.png) |
| Before RSS 및 START/END | [05-controlled-before-monitor.png](../docs/screenshots/oom/05-controlled-before-monitor.png) |
| After 초기 생존 관제 | [07-controlled-after-monitor.png](../docs/screenshots/oom/07-controlled-after-monitor.png) |
| After 설정 및 회복 로그 | [07-controlled-after-console.png](../docs/screenshots/oom/07-controlled-after-console.png) |
| After 추가 회복 로그 | [07-controlled-after-console2.png](../docs/screenshots/oom/07-controlled-after-console2.png) |
| After 마지막 관제 및 ps | [08-controlled-after-final.png](../docs/screenshots/oom/08-controlled-after-final.png) |

Before의 앱 로그 캡처가 `05-controlled-before-monitor.png`라는 이름으로 저장되어 있다면 위 표에 맞춰 `04-controlled-before-console.png`로 정리한다. 실제 RSS 캡처는 `05-controlled-before-monitor.png`에 배치한다.

### 2.6 측정 범위와 제한

- 제공된 After 마지막 RSS 기록은 15:27:56까지다. 앱 실행 로그와 ps는 그 이후에도 생존 및 진행을 보여 주지만, 9분 전체의 연속 RSS 관측이 확인됐다고 기술하지 않았다.
- 회복 직전·직후 RSS가 내려가는 장면은 현재 캡처에 없다. 메모리 정리 및 Heap 재시작은 앱 로그를 근거로 기술했다.
- CPU_AVG는 ps가 계산하는 프로세스 생존 기간의 평균이다. 이 값으로 순간 CPU 사용률을 단정하지 않았다.
- 관측 종료 시점에 After 프로세스는 살아 있었다. 이후 실험 전환을 위해 수동 종료하면 시각과 사유를 별도 기록하며, 이를 장애 재발로 계산하지 않는다.

## 3. Root Cause Analysis (원인 분석)

### 확인된 직접 원인

Before에서는 Heap이 25 MB씩 증가했고 실제 RSS도 함께 상승했다. Heap 275 MB에서 `MemoryGuard`가 `275MB ≥ 256MB`를 기록한 직후 자체 종료 메시지가 출력됐다. 따라서 직접적인 종료 원인은 앱 내부 메모리 보호 정책의 임계값 초과로 판단한다.

종료 코드 137은 128+9로 SIGKILL 종료와 부합한다. 종료 코드만으로 시그널 발신자를 식별할 수는 없으므로, 원인 판단에는 MemoryGuard의 자체 종료 로그를 사용했다. 커널 OOM Killer에 의한 종료를 입증하는 커널 로그는 이 실험에서 제시하지 않았다.

Heap이 250 MB에서 다음 단계인 275 MB로 증가했기 때문에, 설정값인 256 MB와 정확히 같은 값에서 종료되지 않아도 초과 감지와 모순되지 않는다.

### 메모리 증가와 정리 동작

사용 중인 데이터를 계속 보유하면 Heap과 RSS가 증가할 수 있다. 이번 Before는 지속적인 데이터 누적 및 정리 부족과 일치하는 패턴을 보였다. 다만 바이너리의 소스 코드와 객체별 할당 이력을 조사하지 않았으므로, 특정 객체의 누수나 정확한 할당·해제 위치를 확정하지 않는다.

After에서는 동일 바이너리에서 MEMORY_LIMIT만 변경한 조건으로 캐시 정리 경로가 관측됐다. 525 MB에서 정리 메시지가 출력되고 이후 Heap이 25 MB부터 다시 증가했다. 따라서 단순히 종료 시점만 늦어진 것으로 제한하지 않고, 이 설정에서 실제로 관측된 정리 및 진행 유지 동작도 결과에 포함한다.

### 관련 OS 개념

- **Heap:** 프로그램이 실행 중 동적으로 확보한 데이터를 보관하는 메모리 영역이다.
- **RSS:** 프로세스의 메모리 중 RAM에 상주하는 부분의 크기다. 앱이 출력한 Heap 수치와 집계 범위가 다르다.
- **프로세스별 관측:** 부모 PID와 주요 작업 PID의 메모리 사용량이 다르므로, 여러 PID를 하나의 수치로 혼합하지 않았다.
- **앱 보호 기준:** MEMORY_LIMIT은 앱이 읽는 설정값이다. 이 기준 초과와 시스템 전체 물리 메모리 고갈은 구분한다.
- **회복 관측:** 앱의 데이터 정리 로그와 OS가 집계하는 RSS 감소는 각각의 자료로 확인해야 한다. 객체 참조가 해제돼도 할당자 정책 등에 따라 RSS 변화가 즉시 동일하게 나타난다고 가정하지 않는다.

## 4. Workaround & Verification (조치 및 검증)

### 조치 내용

CPU 관련 보호 종료의 영향을 줄이기 위해 두 비교 실행 모두 CPU_MAX_OCCUPY=30, MULTI_THREAD_ENABLE=false로 맞췄다. 그 상태에서 MEMORY_LIMIT만 256에서 512로 변경했다.

기본 설정 파일을 바꾸는 대신, 각 실행의 로그인 셸 내부에서 실험값을 export하고 실제 적용값을 실행 로그에 남겼다. 따라서 기본값을 다시 읽어 실험값이 덮이는 문제를 피했다.

### Before & After

| 비교 항목 | Before | After |
| --- | --- | --- |
| MEMORY_LIMIT | 256 MB | 512 MB |
| CPU_MAX_OCCUPY | 30 | 30 |
| MULTI_THREAD_ENABLE | false | false |
| 주요 PID | 36059 | 37449 |
| 시작 시각(KST) | 15:19:08 | 15:23:41 |
| 생존 결과 | START~END 33초 후 종료 | ps 경과 시간 09:01에도 생존 |
| 마지막 제공 RSS | 291.39 MiB | 491.59 MiB |
| 메모리 임계점에서의 로그 | Heap 275 MB, MemoryGuard 자체 종료 | Heap 525 MB, 캐시 정리 및 회복 |
| 정리 후 진행 | 해당 실행 종료 | Heap 25 MB부터 재시작, 이후 로그 계속 증가 |
| 종료 코드 | 137 | 관측 시 실행 중이므로 해당 없음 |

Before 시간은 START~END 차이이고 After 09:01은 ps의 ELAPSED다. After는 완료된 총 수명이 아니라 확인된 최소 생존 기간으로 해석했다.

### 검증 결론과 한계

MEMORY_LIMIT을 512로 변경한 실행은 Before의 종료 시점을 넘어 생존했고, 메모리 정리 및 작업 재개 로그도 확인됐다. 따라서 해당 설정에서 메모리 보호 종료를 회피하고 생존을 연장한 효과가 관측됐다.

이는 소스 코드의 누수 결함을 수정한 결과를 의미하지 않는다. 이 바이너리와 실험 조건에서 확인된 동작 차이이며, 전체 실행 기간에 대한 장기 안정성은 추가 검증 범위다.

초기 탐색 실행에서는 MEMORY_LIMIT=512, CPU_MAX_OCCUPY=100 조건에서 CpuWorker 임계값 위반으로 24초 만에 종료됐다. 이 실행을 메모리 상향에 따른 생존 연장 검증으로 사용하지 않고, CPU 설정을 30으로 고정한 본 비교를 별도로 수행했다.

### 추가 제안

- 운영 적용 시 메모리 상한을 프로세스 수와 가용 메모리에 맞춰 산정한다.
- 소스 접근이 가능하다면 보관 데이터의 크기 제한, 만료 정책, 주기적 정리와 객체 참조 해제 여부를 점검한다.
- 회복 직전·직후 RSS와 여러 회복 주기의 최저·최고값을 장시간 관측해 누적 증가 여부를 확인한다.
- CPU 및 Deadlock은 별도 케이스로 분석하고 해당 보호 정책이나 대기 상태의 증거를 수집한다.

참고: [Linux /proc 문서](https://cdn.kernel.org/doc/html/latest/filesystems/proc.html), [Bash 종료 상태 문서](https://www.gnu.org/s/bash/manual/html_node/Exit-Status.html).

