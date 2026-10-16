# [Bug] CPU Latency — 내부 부하 임계치 위반으로 프로세스 종료, CPU_MAX_OCCUPY 조정 후 종료 회피

> **검증 범위:** CPU 보호 로그와 종료, 설정 변경 후 작업 지속은 확인했다. 실제 OS CPU 급상승 및 요청 지연은 이번 측정에서 입증하지 못했다. 앱의 `Current Load`를 OS CPU 사용률로 해석하지 않는다.

## 1. Description (현상 설명)

2026-10-16(KST), 격리된 Docker 컨테이너에서 일반 사용자 `agent-admin`으로 `agent-leak-app-arm64`를 실행했다. `MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=100`, `MULTI_THREAD_ENABLE=false` 조건에서 앱의 `Current Load`가 5.00%에서 52.59%로 증가한 후 `CPU Threshold Violated!` 로그와 함께 프로세스가 종료됐다.

같은 환경에서 `CPU_MAX_OCCUPY`만 30으로 변경하자 내부 부하가 30.00%에 도달할 때 cooldown을 시작하고 5.00%에서 작업을 재개하는 로그가 반복됐다. 실행 시간 1분 38초 시점에 PID가 존재했으며, 이후 로그는 준비 완료 후 약 6분 58초까지 진행됐다.

| 항목 | 환경 / 값 |
| --- | --- |
| 실행 환경 | Ubuntu 22.04, Linux aarch64, Docker 컨테이너 `agent-leak-lab` |
| 실행 계정 | `agent-admin` (일반 사용자) |
| 바이너리 | `/home/agent-admin/agent-leak-app/agent-leak-app-arm64` |
| 포트 | 컨테이너 내부 `0.0.0.0:15034` |
| 고정 조건 | `MEMORY_LIMIT=512`, `MULTI_THREAD_ENABLE=false` |
| 변경 조건 | `CPU_MAX_OCCUPY=100 → 30` |
| 분석 방법 | 실행 로그, `top -b -d 1`, `ps` 수집. 바이너리 역분석 없음 |

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

### 2.3 Before: OS CPU 실측과 앱 수치의 차이

`before-top.log`에서 앱 프로세스 행을 추출해 CPU 사용률 내림차순으로 정렬한 결과다. 아래 표는 추출 결과를 옮긴 것으로 원본 `top` 행의 형식과는 다르다.

| 시각(KST) | PID | top의 %CPU |
| --- | --- | ---: |
| 16:03:52 | 43586 (부모) | 7.0% |
| 16:04:22 | 43592 (자식) | 5.0% |
| 16:04:19 | 43592 (자식) | 5.0% |
| 16:04:15 | 43592 (자식) | 4.0% |
| 16:04:12 | 43592 (자식) | 4.0% |

**수집된 프로세스별 표본의 최댓값은 부모 7.0%, 자식 5.0%다.** 부모·자식 최댓값의 발생 시각은 다르므로 이를 더해 동시 사용률이라고 해석하지 않는다. 앱의 내부 부하 52.59%와 OS 측정값은 일치하지 않으며, 이 자료로 실제 CPU 과점유를 입증할 수 없다. 1초 간격 표본만으로 표본 사이의 모든 순간을 판단할 수도 없다.

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

### 2.5 증거 파일

원본 로그:

- [Before 실행 로그](../docs/logs/cpu/before-console.log)
- [Before top 로그](../docs/logs/cpu/before-top.log)
- [After 실행 로그](../docs/logs/cpu/after-console.log)
- [After top 로그](../docs/logs/cpu/after-top.log)

스크린샷:

- [03-before-top.png](../docs/screenshots/cpu/03-before-top.png): Before OS 측정 구간
- [04-before-console.png](../docs/screenshots/cpu/04-before-console.png): Before 설정, 임계치 위반, 종료 상태
- [05-after-top.png](../docs/screenshots/cpu/05-after-top.png): After OS CPU 측정
- [06-after-console.png](../docs/screenshots/cpu/06-after-console.png): After 설정 및 작업 시작
- [07-after-process-check.png](../docs/screenshots/cpu/07-after-process-check.png): PID·실행 시간 및 로그 진행
- [08-cpu-log-verification.png](../docs/screenshots/cpu/08-cpu-log-verification.png): cooldown 반복 및 Before CPU 표본 상위값

`01-after-baseline-top.png`는 대상 프로세스 행이 없는 화면이므로 정상 실행 중 CPU 관제의 증거로 사용하지 않았다. `02-process-check.png`는 앞선 OOM After 실행이 이미 끝났음을 확인한 별도 자료이며, 이번 CPU Before/After 실행과 혼합하지 않았다.

## 3. Root Cause Analysis (원인 분석)

### 3.1 관측으로 확인한 내용과 추론

1. **확인:** `CPU_MAX_OCCUPY=100`일 때 앱은 권장값 50% 미만이라는 경고를 출력했고, 내부 부하 52.59%에서 `CpuWorker`의 임계치 위반 로그 후 종료됐다.
2. **추론:** 직전 보호 로그와 `Terminated`, 종료 상태 143을 종합하면 CPU 보호 로직과 관련된 SIGTERM 종료로 해석할 근거가 있다. Bash에서 시그널 N에 의한 종료는 통상 `128+N`으로 표현되며, `143=128+15`다. 종료 코드만으로 시그널을 보낸 주체를 확정할 수는 없다.
3. **확인:** 설정을 30으로 낮추자 내부 부하가 30%에 도달할 때 cooldown하고 5%에서 재개했다. 관찰된 구간에서는 기존 보호 종료를 회피했다.
4. **미확정:** 내부 부하 지표의 계산 방식, 정확한 보호 임계치, 실제 CPU 연산 부하의 원인은 공개 로그만으로 규명하지 못했다. 설정값 100을 곧바로 종료 임계치 100%로 해석하지 않는다.

실제 로그에는 `WATCHDOG: ... SIGTERM`이라는 문구가 없었다. 따라서 과제의 예시 문구를 복사하지 않고 실제 `CpuWorker` 로그를 증거로 사용한다. 바이너리를 분석하지 않았으므로 무한 루프나 특정 함수의 결함을 확정 원인으로 제시하지 않는다.

### 3.2 관련 OS 원리와 이번 실험의 한계

CPU 연산을 계속 요구하는 프로세스가 많아지면 실행 대기 시간이 증가해 다른 작업의 응답이 늦어질 수 있다. 실제 지연을 입증하려면 프로세스 CPU 측정과 함께 실행 대기·요청 응답 시간 등의 자료가 필요하다.

`top`의 프로세스 `%CPU`는 이전 갱신 이후 CPU 사용 시간을 바탕으로 계산한다. 앱이 출력하는 `Current Load`는 정의가 확인되지 않은 별도 지표다. 이번 실행에서는 OS 표본 최댓값이 낮고, 응답 시간도 측정하지 않았다. 따라서 **실제 CPU Spike 또는 CPU 경합에 의한 Latency 재현을 완료했다고 주장하지 않는다.**

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

### 4.3 후속 확인 및 해결 제안

- 제공자에게 `Current Load` 정의, `CPU_MAX_OCCUPY`의 역할, 보호 종료 임계치와 시나리오 선택 조건을 확인한다.
- 실제 CPU 과점유를 검증하려면 앱 동작 구간을 포함한 PID별 측정과 요청 지연 자료를 추가 확보한다. 관련 없는 부하를 만들어 앱의 CPU 장애 증거로 대신하지 않는다.
- 소스 코드를 수정할 수 있는 단계에서는 실제 CPU 프로파일을 근거로 원인을 찾고, 작업량 제한·대기·작업 분할 등을 검토한다. 이번에는 특정 구현 결함을 확인하지 못했으므로 제안으로만 남긴다.
- 현재 상태: **보호 종료 및 설정 변경 비교는 확보 / 실제 OS CPU 급상승과 지연 증거는 미확보.** 제출 요건 중 실제 CPU 급상승 캡처를 충족했다고 표시하지 않는다.

참고 문서:

- [GNU Bash — Exit Status](https://www.gnu.org/software/bash/manual/html_node/Exit-Status.html)
- [procps top(1) 매뉴얼 — %CPU](https://man7.org/linux/man-pages/man1/top.1.html)
- [procps ps(1) 매뉴얼 — CPU 사용률](https://man7.org/linux/man-pages/man1/ps.1.html)
