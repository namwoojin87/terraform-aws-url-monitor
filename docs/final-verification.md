# 실제 실행 및 마무리 검증 기록

검증일: **2026-09-07**. 기존 AWS 검사기의 수동 1회 실행과 소스 검증 기록이다. **신규 대시보드 배포 완료 또는 보안 검사 통과를 의미하지 않는다.**

## AWS 수동 1회 실행

서울 리전의 기존 `url-monitor-checker`를 비루트 운영자 세션에서 동기 방식으로 한 번 호출했다. 실행 전 신규 시연 ID가 두 테이블에 없고 Scheduler가 `DISABLED`인지 확인했다. SDK 재시도는 비활성화했다. 운영 `demo` 대신 별도 ID를 사용했다.

| 검증 항목 | 실제 결과 |
| --- | --- |
| 시연 ID / 대상 | `lab-final-20260907-7d934a` / `https://example.com` |
| 호출 시작 / 응답 수신 UTC | `2026-09-07T06:50:53.965821+00:00` / `2026-09-07T06:50:57.697171+00:00` |
| 검사 시각 | `2026-09-07T06:50:56.952978+00:00` (한국시간 15:50:56) |
| URL 응답 / 상태 / 응답시간 | HTTP `200` / `UP` / `299ms` |
| Lambda 응답 | `checked=1`, `errors=0`, 함수 오류 없음 |
| DynamoDB | 현재 상태 1건 및 해당 ID의 이력 1건 확인; 시각·상태·응답시간 일치 |
| 보존 설정 | 현재 상태와 이력의 `expires_at` 모두 검사 시각 기준 7일과 일치 |
| 기존 설정 보존 | `demo` 상태와 Scheduler 설정·입력이 실행 전후 동일, `DISABLED` 유지 |
| 알림 전이 | 실행 로그의 `transition=None`; 장애·복구 알림 시연은 수행하지 않음 |

`299ms`는 **단일 요청 표본**이며 평균·p95·SLA가 아니다. TTL 만료 속성은 확인했지만 실제 삭제 완료를 확인한 것은 아니다. 수동 생성한 시연 행은 삭제하지 않았으며 기존 TTL 처리를 따른다. 새 인프라, IAM 변경, Terraform apply 또는 자동 검사 활성화는 수행하지 않았다. 이 호출과 관련 요청·로그의 청구액을 실측하거나 무료라고 확인한 것은 아니다.

## 소스 및 GitHub 검증

- 최종 로컬 Python 테스트: **70 passed, 0 skipped**. 기존 59개, 실제 Checkov fixture 5개, 잘못된 scanner JSON 회귀 테스트 6개를 포함한다.
- 오류 처리 회귀 테스트는 먼저 실패를 확인했다. 누락 필드·잘못된 finding 타입·null 경로에 대해 scanner가 0/1을 반환해도 gate는 `2`와 ERROR 요약을 기록하고 PASSED를 출력하지 않는다. 외부 scanner 실행 경계만 대체하며 실제 JSON 처리와 파일 증빙을 검증한다.
- 전체 실제 Checkov 3.3.16 재실행: **30 resources / 154 pass / 18 fail / 0 skip / 0 parsing errors**, scanner와 gate 모두 종료 코드 `1`.
- 아래 원격 실행은 최초 게시 commit `00e8f30f8a5397414797661b58a0e443f5c78270`의 결과이다. 이후 오류 처리 보완 commit의 결과는 [PR #8 Checks](https://github.com/namwoojin87/terraform-aws-url-monitor/pull/8/checks)와 해당 commit을 대조한다.

| 실제 원격 실행 | 확인 결과 |
| --- | --- |
| [CI 34091253660](https://github.com/namwoojin87/terraform-aws-url-monitor/actions/runs/34091253660) | SUCCESS; Python, Terraform fmt/validate, bootstrap·module mock 테스트, TFLint 단계 성공 |
| [Terraform Security 34091253763](https://github.com/namwoojin87/terraform-aws-url-monitor/actions/runs/34091253763) | FAILURE; fixture 단계 성공, 전체 스캔 154/18/0으로 실패, 파싱 오류 0 |
| 같은 보안 실행의 증빙 | 요약 게시와 `terraform-security-evidence` artifact 업로드 성공 확인 |

## 남은 완료 조건

1. [보안 지적 18건](security-review.md)의 수정 범위 또는 정확한 리소스별 예외를 소유자가 검토·승인한다. 현재 승인된 예외는 없다.
2. PR 리뷰·병합 결정 후 새 bootstrap 보완 2건은 새 live plan을 검토하고 별도로 적용 승인한다. 이전 대시보드 IAM 적용 기록으로 이를 대체하지 않는다.
3. 신규 대시보드는 비용·계정 사용량을 확인하고 새 runtime saved plan과 production 승인을 거쳐 적용한다. 실제 위젯의 대상·리전·시간 범위를 검증한다.
4. 새 배포 결과가 확보되면 제출 PPT를 갱신한다. 기존 PPT를 최신 대시보드 배포 증빙으로 사용하지 않는다.

현재는 **기존 기능의 직접 실행 확인 완료, 확장 기능은 검토용 초안 PR 단계**이다. main 병합·보안 예외·대시보드 배포·PPT 갱신은 이 검증 기록에 포함하지 않는다.
