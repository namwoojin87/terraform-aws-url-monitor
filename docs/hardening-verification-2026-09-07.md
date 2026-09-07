# 저비용 복구·알림 암호화 보완 검증

**결론: 코드 구현과 로컬 기능 검증 완료. AWS 미적용. 보안 gate는 FAIL이다.** 자동 검사를 활성화하거나 키·큐를 실제 생성하지 않았다. 이전의 AWS 수동 실행 증빙을 새 구성의 성공 증거로 사용하지 않는다.

## 구현 범위

| 보완 | 구현한 내용 | 실환경 상태 |
| --- | --- | --- |
| DB 복구 | 현재 상태·이력 테이블 모두 PITR 활성화, 기존 온디맨드·7일 TTL 유지 | 미적용, 실제 복구 미실행 |
| 실패 보관 | Scheduler 전달 실패 / Lambda 실행 실패용 Standard SQS 2개, SSE-SQS, 14일 보관 | 미생성, 전달 시험 미실행 |
| 비동기 처리 | Lambda 최대 이벤트 나이 300초 / 코드 오류 재시도 0회; Scheduler 300초 / 1회 유지 | 미적용, 자동 재실행 없음 |
| 실행 추적 | Active X-Ray, 필요한 쓰기 액션 2개만 추가 | 미적용, 모든 외부 호출의 상세 추적을 의미하지 않음 |
| 운영 화면 | 기존 AWS 지표 13개에서 20개 시계열로 확장 | 대시보드 미배포, 공개 공유·쿼리·커스텀 지표 없음 |
| SNS 암호화 | bootstrap 소유 고객 관리 키 1개, 연간 회전·30일 삭제 대기·Terraform 삭제 보호, 두 발행자 권한 제한 | 미생성, 암호화 후 앱/경보 발행 경로 미검증 |

구현 커밋은 `2f9ae9d4d96d1f3016b0497b32a6e208589cbda6`(복구·실패 보관)과 `a0a5464405610538cb0f9eb2d65417efdceefca7`(SNS 암호화)이다. 기존 격리 브랜치 `codex/monitoring-security-evidence`에서 작업했으며 `main` 병합이나 Terraform apply는 하지 않았다.

## 직접 재실행한 로컬 검증

코드 기준 커밋 `a0a5464`, 실행 시각 **2026-09-07 08:10:03–08:11:18 UTC / 17:10:03–17:11:18 KST**. 이후 문서 변경은 이 코드의 배포 증거가 아니다.

| 검사 | 실제 결과 |
| --- | --- |
| Python 전체 테스트 — Checkov가 설치된 격리 환경 | **71 passed**, 30.50초, exit 0 |
| Terraform bootstrap mock 테스트 | **9 passed, 0 failed**, exit 0 |
| Terraform runtime module mock 테스트 | **11 passed, 0 failed**, exit 0 |
| Terraform format 및 bootstrap/infra/module validate | 모두 exit 0 |
| TFLint 0.64.0 / whitespace 검사 | 모두 exit 0 |
| Checkov 3.3.16 전체 소스 검사 | **37 resources, 195 passed, 16 failed, 0 skipped, 0 parsing errors** |
| 보안 검사 판정 | scanner exit **1**, gate exit **1** — 통과 아님 |

테스트를 먼저 실행해 필요한 리소스·정책이 없어서 실패하는 것을 확인한 뒤 구현했다. 두 단계 모두 별도 리뷰에서 요구사항 준수·코드 품질 승인을 받았으며 Critical/Important/Minor 지적은 없었다. Mock 검증은 Terraform 구성·의존성·실제 정책 문서 입력을 검사하며 AWS 호출 권한이나 실제 알림 전달을 증명하지 않는다.

보안 검사는 어떤 항목도 제외하지 않았다. 기존 18개 지적 중 SNS 암호화 1개, PITR 2개, Lambda DLQ 1개, 추적 1개가 해소됐다. 그러나 새 KMS 정책에서 3개 지적이 추가되어 **13개 기존 항목 + 3개 새 항목 = 16개**가 남는다. 새 큐도 전체 검사에 포함됐으며 각각 `CKV_AWS_27`, `CKV_AWS_168`, `CKV2_AWS_73`을 통과했다. 정확한 주소와 위험은 [보안 검토](security-review.md)에 기록한다.

## 새 KMS 정책 지적의 맥락

`CKV_AWS_109`, `CKV_AWS_111`, `CKV_AWS_356`은 `bootstrap/alerts-encryption.tf`의 `aws_iam_policy_document.alerts_key`, 그중 `EnableAccountIAMPermissions`의 `kms:*` 문장을 지적한다. 이 문장은 모든 사용자에게 키를 공개하는 정책이 아니라 계정의 IAM 정책으로 이 키의 권한을 위임할 수 있게 하는 AWS 기본 키 정책 패턴이다. KMS 키 정책의 `Resource = "*"`는 이 정책이 붙은 키를 뜻한다. [AWS 기본 키 정책](https://docs.aws.amazon.com/kms/latest/developerguide/key-policy-default.html), [KMS 키 정책 형식](https://docs.aws.amazon.com/kms/latest/developerguide/key-policy-overview.html).

그렇더라도 계정 관리자/IAM 관리 권한을 신뢰하는 위험은 남는다. 일반 IAM 문서 검사와 KMS 키 정책 맥락을 검토해야 하며, **이 설명은 예외 승인이나 gate 통과 처리가 아니다**. 데이터 소스를 숨기는 리팩터링이나 의미 없는 조건 추가로 지적을 없애지 않았다. GitHub 배포 역할에 직접 추가한 KMS 권한은 정확한 키의 `DescribeKey`뿐이며, Lambda 암호화 사용은 정확한 키·SNS 서비스·토픽으로, CloudWatch 사용은 정확한 계정·경보·토픽으로 제한했다.

## 배포 전에 남은 일

1. 기존 13개와 KMS 문맥 3개의 처리 방향을 리소스별로 결정한다. 어떤 보안 예외도 아직 승인·적용하지 않았다.
2. 새 bootstrap 계획에서 키·별칭·정확한 IAM 추가 권한과 앞서 남은 bootstrap 수정 내용을 검토하고 별도 승인을 받는다. 과거 대시보드 전용 IAM 승인으로 대신하지 않는다.
3. bootstrap 키 별칭이 있어야 runtime이 이를 조회해 계획할 수 있다. 소스 검토·통합 결정 후 **새 saved runtime plan**을 만들고 production 승인을 받는다. Scheduler는 계속 OFF로 둔다.
4. 승인 범위를 정한 뒤 암호화된 앱 알림과 CloudWatch 경보의 두 발행 경로를 확인한다. DLQ 전달·재실행·PITR 복구도 별도 제한된 시험으로 다룬다.
5. 실제 적용·시연 결과를 확보한 뒤 제출용 아키텍처와 PPT를 갱신한다. 이번 문서는 로컬 구현을 실환경 완료로 표시하지 않는다.

키가 실제 생성되면 초기 보관료 월 USD 1 및 요청·세금이 발생하고, 첫 두 번 회전은 각각 월 USD 1 보관료를 더한다. 스케줄 중지나 runtime 삭제로 bootstrap 키 비용이 없어지지 않는다. 이번 로컬 검증에서는 키를 생성하지 않았다. 자세한 수명주기·비용 경계는 [SNS 운영 가이드](sns-encryption-runbook.md), 복구 절차는 [복구 운영 가이드](recovery-runbook.md)를 따른다.

## 재현 명령

기존에 초기화된 작업 공간에서 실행한다. 보안 검사 exit 1은 이 기록의 예상되는 실패 결과이며, 성공으로 바꿔 해석하지 않는다.

```powershell
.superpowers/checkov-venv/Scripts/python.exe -m pytest -o addopts= -q
terraform -chdir=bootstrap test
terraform -chdir=modules/url-monitor test
terraform fmt -check -recursive bootstrap infra modules
terraform -chdir=bootstrap validate
terraform -chdir=infra validate
terraform -chdir=modules/url-monitor validate
tflint --recursive --format compact
.superpowers/checkov-venv/Scripts/python.exe security/scan.py
```

원본 로컬 결과는 Git에 제외된 `security/reports/checkov.json`, `checkov.log`, `summary.md`에 보존한다. 과거 원격 실행과 이번 코드의 결과를 섞지 말고, PR의 해당 커밋을 대상으로 실행한 CI artifact를 확인한다.
