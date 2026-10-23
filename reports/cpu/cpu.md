# [Bug] CPU Spike - 작업 프로세스의 짧은 CPU 급상승과 내부 부하 임계치 위반 종료

> **검증 범위:** 2026-10-23 재검증에서 작업 PID 40의 실제 CPU 표본이 **0.0% → 23.8% → 0.0%**로 변하는 짧은 급상승 구간을 확인했다. 앱의 보호 종료와 CPU_MAX_OCCUPY 변경 후 작업 지속도 확인했다. 시스템 전체 CPU 포화나 요청 응답 지연은 입증하지 않았으며, 앱의 `Current Load`와 OS CPU 측정값을 구분한다.

## 1. Description (현상 설명)

2026-10-16(KST), 격리된 Docker 컨테이너에서 일반 사용자 `agent-admin`으로 `agent-leak-app-arm64`를 실행했다. `MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=100`, `MULTI_THREAD_ENABLE=false` 조건에서 앱의 `Current Load`가 5.00%에서 52.59%로 증가한 후 `CPU Threshold Violated!` 로그와 함께 프로세스가 종료됐다.

같은 환경에서 `CPU_MAX_OCCUPY`만 30으로 변경하자 내부 부하가 30.00%에 도달할 때 cooldown을 시작하고 5.00%에서 작업을 재개하는 로그가 반복됐다. 실행 시간 1분 38초 시점에 PID가 존재했으며, 이후 로그는 준비 완료 후 약 6분 58초까지 진행됐다.

초기 1초 간격 관제에서는 작업 프로세스의 표본 최댓값이 5%여서 짧은 상승 구간을 명확히 식별하지 못했다. 2026-10-23에 동일한 Before 설정으로 재실행하며 관제 간격을 0.2초로 줄였고, 작업 중 PID 40의 0.0% → 23.8% → 0.0% 변화를 원본의 연속 화면에서 확인했다. 이 실행에서는 앱 내부 부하가 56.25%일 때 보호 로그가 발생하고 시작 기록 후 약 43초에 종료됐다.

| 항목 | 환경 / 값 |
| --- | --- |
| 실행 환경 | Ubuntu 22.04, Linux aarch64, Docker 컨테이너 `agent-leak-lab` |
| 실행 계정 | `agent-admin` (일반 사용자) |
| 바이너리 | `/home/agent-admin/agent-leak-app/agent-leak-app-arm64` |
| 포트 | 컨테이너 내부 `0.0.0.0:15034` |
| 고정 조건 | `MEMORY_LIMIT=512`, `MULTI_THREAD_ENABLE=false` |
| 변경 조건 | `CPU_MAX_OCCUPY=100 → 30` |
| 분석 방법 | 실행 로그, 초기 `top -b -d 1`, 재검증 `top -b -d 0.2`, `ps` 수집. 바이너리 역분석 없음 |

## 2. Evidence & Logs (증거 자료)

### 2.1 재현 및 관제 경로

먼저 컨테이너 터미널 A에서 관제를 시작했다.

```bash
top -b -d 1 -u agent-admin \
  | tee -a /mission-docs/logs/cpu/before-top.log
```

컨테이너 터미널 B에서 다음과 같이 앱을 실행하고 종료 상태를 기록했다. 로그인 셸에서 프로파일을 읽은 **뒤에** 환경변수를 지정했다.

```bash
runuser -u agent-admin -- bash -lc '
set -e
export MEMORY_LIMIT=512
export CPU_MAX_OCCUPY=100
export MULTI_THREAD_ENABLE=false
cd "$AGENT_HOME"
printf "[START] %s\n" "$(date "+%Y-%m-%d %H:%M:%S %Z")"
env | sort | grep -E "^(MEMORY_LIMIT=|CPU_MAX_OCCUPY=|MULTI_THREAD_ENABLE=)"
exec ./agent-leak-app-arm64
' 2>&1 | tee -a /mission-docs/logs/cpu/before-console.log

APP_EXIT=${PIPESTATUS[0]}
printf '[END] %s EXIT_CODE=%s\n' \
  "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$APP_EXIT" \
  | tee -a /mission-docs/logs/cpu/before-console.log
```

After 실행은 관제·실행 로그 파일명을 `after-top.log`, `after-console.log`로 변경하고, `CPU_MAX_OCCUPY=30`으로 실행했다. 각 실행의 로그를 분리했다. 같은 파일명으로 추가 실행할 경우 `tee -a`가 내용을 덧붙이므로 실행 경계를 구분해야 한다.

### 2.2 Before: 보호 로그 및 종료

앱은 부팅 시 `CPU Limit: 100%`와 `WARNING: Recommend Under 50%`를 출력했다.

```text
2026-10-16 16:03:51,621 [INFO] Agent listening at port 15034
2026-10-16 16:03:53,639 [INFO] [CpuWorker] Started. Maximum CPU Limit: 100%
2026-10-16 16:03:53,642 [INFO] [CpuWorker] Current Load: 5.00%
2026-10-16 16:04:12,397 [INFO] [CpuWorker] Current Load: 32.91%
2026-10-16 16:04:15,525 [INFO] [CpuWorker] Current Load: 42.43%
2026-10-16 16:04:24,894 [INFO] [CpuWorker] Current Load: 52.59%
2026-10-16 16:04:25,001 [CRITICAL] [CpuWorker] CPU Threshold Violated! (52.59000000000001%).
Terminated
[END] 2026-10-16 16:04:25 KST EXIT_CODE=143
```

준비 완료 직후의 포트 리스닝 로그부터 종료 시점까지 약 33초다. 런처의 `[START]` 행은 해당 캡처에 없으므로 이 값을 전체 실행 시간으로 단정하지 않는다.

### 2.3 초기 Before: 1초 간격 OS CPU 실측과 앱 수치의 차이

`before-top.log`에서 앱 프로세스 행을 추출해 CPU 사용률 내림차순으로 정렬한 결과다. 아래 표는 추출 결과를 옮긴 것으로 원본 `top` 행의 형식과는 다르다.

| 시각(KST) | PID | top의 %CPU |
| --- | --- | ---: |
| 16:03:52 | 43586 (부모) | 7.0% |
| 16:04:22 | 43592 (자식) | 5.0% |
| 16:04:19 | 43592 (자식) | 5.0% |
| 16:04:15 | 43592 (자식) | 4.0% |
| 16:04:12 | 43592 (자식) | 4.0% |

**이 초기 실행의 수집된 프로세스별 표본 최댓값은 부모 7.0%, 자식 5.0%다.** 부모·자식 최댓값의 발생 시각은 다르므로 이를 더해 동시 사용률이라고 해석하지 않는다. 앱의 내부 부하 52.59%와 OS 측정값은 일치하지 않는다. 이 자료만으로 짧은 CPU 급상승을 식별하지 못해 2.5절의 0.2초 간격 재검증을 추가했다. 서로 다른 실행의 표본 최댓값 차이를 관제 간격 변경만의 효과로 단정하지 않는다.

### 2.4 After: 30%에서 cooldown, 5%에서 재개

부팅 화면에서 `MEMORY Limit: 512MB`, `CPU Limit: 30%`, `THREAD Concurrency: False`를 확인했다. 앱은 `Healthy System Monitoring` 시나리오를 선택했다.

```text
2026-10-16 16:10:52,578 [INFO] Agent listening at port 15034
2026-10-16 16:10:55,758 [INFO] [CpuWorker] Started. Maximum CPU Limit: 30%
2026-10-16 16:11:10,390 [INFO] [CpuWorker] Peak reached (30.00%). Starting cooldown...
2026-10-16 16:11:26,018 [INFO] [CpuWorker] Cooldown complete (5.00%). Resuming load increase...
2026-10-16 16:11:51,832 [INFO] [CpuWorker] Peak reached (30.00%). Starting cooldown...
2026-10-16 16:12:06,663 [INFO] [CpuWorker] Cooldown complete (5.00%). Resuming load increase...
2026-10-16 16:17:35,073 [INFO] [CpuWorker] Peak reached (30.00%). Starting cooldown...
2026-10-16 16:17:50,073 [INFO] [CpuWorker] Cooldown complete (5.00%). Resuming load increase...
```

16:12:31(KST)의 `ps` 출력에서 실행 시간 1분 38초인 두 프로세스를 확인했다.

```text
  PID  PPID STAT ELAPSED %CPU    RSS COMMAND
46187 46185 S+     01:38  0.0   1632 ./agent-leak-app-arm64
46193 46187 SNl+   01:38  1.0 272964 ./agent-leak-app-arm64
```

`ps`의 `%CPU`는 프로세스 실행 기간에 걸친 평균 지표이며, `top` 갱신 구간의 값과 동일하게 해석하지 않는다. 제공된 After `top` 화면의 16:12:16~16:12:20 구간에서 자식 프로세스 CPU는 0~2%였다. 메모리는 변하고 실행 로그도 이어져, 해당 시점에 작업이 계속 진행된다는 근거가 된다.

### 2.5 추가 재검증: 0.2초 간격으로 실제 급상승 구간 포착

2026-10-23, 다른 앱 프로세스와 15034 포트의 리스닝 행이 없는 것을 확인한 뒤 관제를 먼저 시작했다.

```bash
mkdir -p /mission-docs/logs/cpu/recheck-20261023-01

LC_ALL=C top -b -d 0.2 -w 180 -u agent-admin \
  | tee -a /mission-docs/logs/cpu/recheck-20261023-01/top.log
```

앱은 `MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=100`, `MULTI_THREAD_ENABLE=false`로 실행하고 `console.log`에 기록했다. 원본은 콘솔 51줄, top 5804줄이며, top은 16:42:03~16:44:18의 671개 화면을 포함한다. 앱이 없는 관제 시작·종료 구간을 CPU 0%인 앱 표본으로 간주하지 않았다.

작업 PID 40의 최고 CPU 표본은 16:43:17의 **23.8%**다. 전체 앱 표본의 최고값인 PID 34의 28.6%는 16:42:38의 부팅 시점이므로 작업 중 최고값과 구분했다.

핵심 연속 화면은 원본 top.log의 375~377번째 화면이며, 아래 표는 해당 값을 그대로 옮긴 것이다. `top`의 화면 시각은 초 단위라 서로 다른 갱신 화면이 같은 시각으로 표시될 수 있다. 밀리초 시각을 만들어 붙이지 않았다.

| 원본 화면 순번 | 표시 시각(KST) | PID 40의 %CPU | PID 40의 TIME+ | 시스템 CPU idle |
| --- | --- | ---: | --- | ---: |
| 375 | 16:43:17 | 0.0% | 0:00.30 | 99.4% |
| 376 | 16:43:17 | **23.8%** | **0:00.35** | 96.9% |
| 377 | 16:43:18 | 0.0% | 0:00.35 | 100.0% |

연속된 갱신 구간에서 낮은 사용률 → 짧은 급상승 → 낮은 사용률로 돌아오는 패턴이 확인되고, 누적 CPU 시간도 0.05초 증가했다. 상승 표본은 실제 CPU 사용을 반영하지만 지속적인 과점유나 시스템 전체 포화를 의미하지 않는다. 같은 화면의 RSS는 16800KiB로 유지됐다.

원본 행 발췌:

```text
top - 16:43:17 up 7 min,  0 users,  load average: 0.08, 0.04, 0.01
  PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
   40 agent-a+  30  10   23096  16800   8464 S   0.0   0.2   0:00.30 agent-leak-app-

top - 16:43:17 up 7 min,  0 users,  load average: 0.08, 0.04, 0.01
  PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
   40 agent-a+  30  10   23096  16800   8464 S  23.8   0.2   0:00.35 agent-leak-app-

top - 16:43:18 up 7 min,  0 users,  load average: 0.08, 0.04, 0.01
  PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
   40 agent-a+  30  10   23096  16800   8464 S   0.0   0.2   0:00.35 agent-leak-app-
```

위 발췌는 설명을 위해 시스템 요약·다른 PID 행을 생략했다. 원본의 전체 세 화면은 컨테이너에서 다음 명령으로 다시 표시할 수 있다. 행 번호는 첨부한 이번 원본에 한정된다.

```bash
sed -n '3397,3426p' \
  /mission-docs/logs/cpu/recheck-20261023-01/top.log
```

이 화면을 `docs/screenshots/cpu/12-recheck-spike-window.png`로 캡처하면 PID·열 제목·상승 전후의 원본 화면을 한 장에 제시할 수 있다. 보고서 작성 시점에는 원본 로그와 기존 최고값·상위 표본 캡처를 확보했으며, 이 추가 터미널 캡처는 촬영 안내 단계다.

동일 실행의 콘솔 로그:

```text
[START] 2026-10-23 16:42:38 KST
CPU_MAX_OCCUPY=100
MEMORY_LIMIT=512
MULTI_THREAD_ENABLE=false
2026-10-23 16:42:40,317 [INFO] [CpuWorker] Started. Maximum CPU Limit: 100%
2026-10-23 16:43:17,841 [INFO] [CpuWorker] Current Load: 48.79%
2026-10-23 16:43:20,972 [INFO] [CpuWorker] Current Load: 56.25%
2026-10-23 16:43:21,074 [CRITICAL] [CpuWorker] CPU Threshold Violated! (56.25000000000001%).
Terminated
[END] 2026-10-23 16:43:21 KST EXIT_CODE=143
```

top의 23.8% 표본과 앱의 48.79% 로그는 초 단위 표시상 같은 16:43:17에 속한다. 측정 기준이 다르므로 동일 수치로 취급하거나 정확한 발생 순서를 정하지 않는다. 앱 내부 부하 56.25%에서의 종료는 약 4초 뒤다. OS의 23.8% 표본이 직접 보호 임계치를 넘겼다고 주장하지 않는다.

### 2.6 증거 파일

원본 로그:

- [Before 실행 로그](../docs/logs/cpu/before-console.log)
- [Before top 로그](../docs/logs/cpu/before-top.log)
- [After 실행 로그](../docs/logs/cpu/after-console.log)
- [After top 로그](../docs/logs/cpu/after-top.log)
- [재검증 실행 로그](../docs/logs/cpu/recheck-20261023-01/console.log)
- [재검증 top 로그](../docs/logs/cpu/recheck-20261023-01/top.log)

스크린샷:

- [03-before-top.png](../docs/screenshots/cpu/03-before-top.png): Before OS 측정 구간
- [04-before-console.png](../docs/screenshots/cpu/04-before-console.png): Before 설정, 임계치 위반, 종료 상태
- [05-after-top.png](../docs/screenshots/cpu/05-after-top.png): After OS CPU 측정
- [06-after-console.png](../docs/screenshots/cpu/06-after-console.png): After 설정 및 작업 시작
- [07-after-process-check.png](../docs/screenshots/cpu/07-after-process-check.png): PID·실행 시간 및 로그 진행
- [08-cpu-log-verification.png](../docs/screenshots/cpu/08-cpu-log-verification.png): cooldown 반복 및 Before CPU 표본 상위값
- [09-recheck-console.png](../docs/screenshots/cpu/09-recheck-console.png): 2026-10-23 설정, 내부 부하 증가와 보호 종료
- [10-recheck-top-peak.png](../docs/screenshots/cpu/10-recheck-top-peak.png): 전체 최고값 28.6%, 부팅 시점으로 구분
- [11-recheck-worker-top10.png](../docs/screenshots/cpu/11-recheck-worker-top10.png): 작업 PID 40의 상위 표본, 권장 저장명

추가 촬영 예정: `docs/screenshots/cpu/12-recheck-spike-window.png` — 상승 전후의 연속 원본 화면. 해당 파일은 촬영 후 저장한다.

`01-after-baseline-top.png`는 대상 프로세스 행이 없는 화면이므로 정상 실행 중 CPU 관제의 증거로 사용하지 않았다. `02-process-check.png`는 앞선 OOM After 실행이 이미 끝났음을 확인한 별도 자료이며, 이번 CPU Before/After 실행과 혼합하지 않았다.

## 3. Root Cause Analysis (원인 분석)

### 3.1 관측으로 확인한 내용과 추론

1. **확인:** `CPU_MAX_OCCUPY=100`일 때 앱은 권장값 50% 미만이라는 경고를 출력했고, 내부 부하 52.59%에서 `CpuWorker`의 임계치 위반 로그 후 종료됐다.
2. **추론:** 직전 보호 로그와 `Terminated`, 종료 상태 143을 종합하면 CPU 보호 로직과 관련된 SIGTERM 종료로 해석할 근거가 있다. Bash에서 시그널 N에 의한 종료는 통상 `128+N`으로 표현되며, `143=128+15`다. 종료 코드만으로 시그널을 보낸 주체를 확정할 수는 없다.
3. **확인:** 설정을 30으로 낮추자 내부 부하가 30%에 도달할 때 cooldown하고 5%에서 재개했다. 관찰된 구간에서는 기존 보호 종료를 회피했다.
4. **미확정:** 내부 부하 지표의 계산 방식, 정확한 보호 임계치, 실제 CPU 연산 부하의 원인은 공개 로그만으로 규명하지 못했다. 설정값 100을 곧바로 종료 임계치 100%로 해석하지 않는다.
5. **추가 확인:** 2026-10-23 재검증에서 작업 PID 40의 OS CPU 표본 0.0% → 23.8% → 0.0%를 확보했다. 같은 실행은 내부 부하 56.25%에서 보호 로그 후 종료됐다. 프로세스의 짧은 CPU 급상승과 앱 보호 종료는 각각 관측한 사실이며, 둘의 지표를 동일시하지 않는다.

실제 로그에는 `WATCHDOG: ... SIGTERM`이라는 문구가 없었다. 따라서 과제의 예시 문구를 복사하지 않고 실제 `CpuWorker` 로그를 증거로 사용한다. 바이너리를 분석하지 않았으므로 무한 루프나 특정 함수의 결함을 확정 원인으로 제시하지 않는다.

### 3.2 관련 OS 원리와 이번 실험의 한계

CPU 연산을 계속 요구하는 프로세스가 많아지면 실행 대기 시간이 증가해 다른 작업의 응답이 늦어질 수 있다. 실제 지연을 입증하려면 프로세스 CPU 측정과 함께 실행 대기·요청 응답 시간 등의 자료가 필요하다.

`top`의 프로세스 `%CPU`는 이전 갱신 이후 CPU 사용 시간을 바탕으로 계산한다. 짧은 CPU 사용은 긴 측정 구간에서 평균화될 수 있다. 초기 1초 간격 실행과 재검증 0.2초 간격 실행은 별도 실행이며 작업 진행 수치도 달라, 표본 차이의 원인을 관제 간격 하나로 단정하지 않는다.

재검증에서는 **특정 프로세스의 짧은 CPU Spike를 확인했다.** 그러나 최고 표본에서도 시스템 CPU idle은 96.9%였고 요청 응답 시간은 측정하지 않았다. 따라서 시스템 전체 포화, 지속적인 CPU 과점유, CPU 경합에 의한 실제 Latency 발생까지 검증했다고 주장하지 않는다. 앱이 출력하는 `Current Load` 역시 정의가 확인되지 않은 별도 지표다.

시스템 전체 CPU 요약과 특정 프로세스 CPU는 범위가 다르며, Docker 환경의 시스템 요약을 Mac 전체 상태로 단정하지 않는다. 낮은 CPU와 PID 존재만으로 정상 상태나 Deadlock을 판단할 수도 없다. 작업 진행 로그를 함께 확인해야 한다.

## 4. Workaround & Verification (조치 및 검증)

### 4.1 임시 조치

`MEMORY_LIMIT=512`, `MULTI_THREAD_ENABLE=false`를 고정한 채 `CPU_MAX_OCCUPY`를 `100 → 30`으로 낮추고 재실행했다. 앱 로그에서 30% 도달 시 cooldown하는 동작을 확인했다. 이것이 OS의 CPU quota를 설정하거나 실제 CPU를 정확히 30%로 제한한다는 의미는 아니다.

### 4.2 Before & After

| 항목 | Before | After |
| --- | --- | --- |
| CPU_MAX_OCCUPY | 100 | 30 |
| 부팅 시 CPU 판정 | Recommend Under 50% 경고 | OK |
| 앱 내부 부하 제어 | 52.59%에서 임계치 위반 | 30%에서 cooldown, 5%에서 재개 |
| 종료 / 생존 | 16:04:25 종료, EXIT_CODE=143 | 16:12:31에 PID 존재, ELAPSED=01:38 |
| 추가 진행 근거 | 해당 없음 | 16:17:50까지 제어 로그 반복, 준비 완료 후 약 6분 58초 |
| OS CPU 표본 | 수집된 행 기준 부모 최대 7%, 자식 최대 5% | 제공된 16:12:16~20 구간에서 자식 0~2% |

After의 6분 58초는 마지막으로 확인한 로그까지의 관찰 기간이다. 자연 종료까지의 수명이나 장시간 안정성을 뜻하지 않는다. Before는 전체 로그에서 추출한 최댓값, After는 제공된 화면 구간의 값이므로 동일 기간의 최대 CPU 감소율을 계산하지 않는다.

위 표는 2026-10-16의 설정 변경 비교다. 별도 추가 실험인 2026-10-23 재검증은 Before 설정 100으로 실행했고, 약 43초에 보호 종료됐다. 해당 0.2초 관제에서 작업 PID 40의 최대 표본 23.8%와 상승 전후를 확인했다. 기존 After의 1초 측정값과 직접 비교해 CPU 감소율을 계산하지 않는다.

### 4.3 후속 확인 및 해결 제안

- 제공자에게 `Current Load` 정의, `CPU_MAX_OCCUPY`의 역할, 보호 종료 임계치와 시나리오 선택 조건을 확인한다.
- 짧은 CPU Spike는 재검증 원본에서 확인했다. 지속적인 과점유나 지연 영향까지 검증하려면 동일 조건·동일 관제 간격의 설정 전후 자료와 요청 응답 시간 등을 추가 확보한다. 관련 없는 부하를 만들어 앱의 장애 증거로 대신하지 않는다.
- 소스 코드를 수정할 수 있는 단계에서는 실제 CPU 프로파일을 근거로 원인을 찾고, 작업량 제한·대기·작업 분할 등을 검토한다. 이번에는 특정 구현 결함을 확인하지 못했으므로 제안으로만 남긴다.
- 현재 상태: **PID별 짧은 CPU 급상승 원본·수치, 보호 종료 로그, 설정 변경 비교 확보.** 상승 전후 세 화면은 2.5절의 명령으로 재표시해 추가 캡처한다. 요청 지연은 미측정이며 검증 한계로 유지한다.

참고 문서:

- [GNU Bash — Exit Status](https://www.gnu.org/software/bash/manual/html_node/Exit-Status.html)
- [procps top(1) 매뉴얼 — %CPU](https://man7.org/linux/man-pages/man1/top.1.html)
- [procps ps(1) 매뉴얼 — CPU 사용률](https://man7.org/linux/man-pages/man1/ps.1.html)
