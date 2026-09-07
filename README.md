# aws-terraform-infra

Terraform으로 **VPC 네트워크**와 **IAM 권한 체계**, **S3 원격 백엔드**를 구성한 실습 저장소.

인프런 「IaC with Terraform」을 따라가며 만들었지만, 교재 코드가 AWS Provider v2 시절 문법이라 **v5 / Terraform 1.x 기준으로 다시 썼다.** 무엇을 왜 바꿨는지는 아래에 정리했다. 작업 중 막힌 지점은 [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md)에 에러 원문·확인 순서·원인 형태로 남겼다.

## 구성

```
01-backend/    S3 버킷 + 상태 잠금 — 다른 모듈들이 쓸 원격 백엔드를 먼저 만든다
02-vpc/        VPC · 서브넷 · IGW · NAT Gateway · 라우팅
03-iam/        사용자 → 그룹 → AssumeRole 구조
04-iam-role/   EC2가 맡는 역할 — 신뢰 정책과 권한 정책 분리 + 인스턴스 프로파일
05-s3/         S3 버킷과 객체, 원격 백엔드 연결
```

번호는 실제 구성 순서다. 백엔드가 먼저 있어야 나머지가 상태를 거기에 저장할 수 있다.

```
      Internet
          │
      ┌───▼────┐
      │  IGW   │
      └───┬────┘
          │ 0.0.0.0/0  (gateway_id)
   ┌──────▼──────────────────────────────────┐
   │ VPC 10.0.0.0/16    ap-northeast-2a      │
   │                                         │
   │  ┌── public 10.0.0.0/24 ─────────────┐  │
   │  │  rt-public → IGW                  │  │
   │  │  map_public_ip_on_launch = true   │  │
   │  │        ┌─────────┐                │  │
   │  │        │ NAT GW  │◄── EIP         │  │
   │  │        └────┬────┘                │  │
   │  └─────────────┼────────────────────-┘  │
   │                │ 0.0.0.0/0              │
   │                │ (nat_gateway_id)       │
   │  ┌─────────────▼── private 10.0.10.0/24─┐│
   │  │  rt-private → NAT GW                 ││
   │  │  아웃바운드 전용                       ││
   │  └──────────────────────────────────────┘│
   └──────────────────────────────────────────┘
```

## 설계에서 의도한 것

### 네트워크

**퍼블릭과 프라이빗을 가르는 것은 서브넷 이름이 아니라 라우트 테이블이 `0.0.0.0/0`을 어디로 보내느냐다.** 퍼블릭은 IGW로 — 퍼블릭 IP와 사설 IP를 1:1 매핑하므로 외부에서 먼저 접속을 시작할 수 있다. 프라이빗은 NAT Gateway로 — 여러 사설 IP를 하나의 EIP로 묶는 다:1 Source NAT라 **인바운드는 매핑 자체가 없어 경로가 존재하지 않는다.** 보안 그룹이 막아서가 아니라 주소 변환 구조상 도달할 수 없는 것이다.

**퍼블릭과 프라이빗을 같은 AZ에 묶었다.** NAT Gateway가 퍼블릭 서브넷에 있으므로 프라이빗이 다른 AZ면 아웃바운드가 매번 AZ를 건너 데이터 전송 요금이 붙는다.

**`map_public_ip_on_launch`를 켰다.** IGW는 퍼블릭 IP가 붙은 인스턴스만 매핑하므로, 이게 없으면 퍼블릭 서브넷에 있어도 인터넷과 통신하지 못한다.

**라우트는 `aws_route`로 통일했다.** 인라인 `route {}`와 독립 리소스를 같은 테이블에 섞으면 서로의 규칙을 지우려 들어 `plan`에 diff가 영원히 남는다. 분리해 두면 나중에 피어링·VPN 경로를 다른 파일에서 붙일 수 있다.

### IAM

**사용자에게 정책을 직접 붙이지 않는다.** 사용자는 그룹에 속하고, 그룹은 `sts:AssumeRole` 권한만 갖는다. 실제 작업 권한은 역할에 있다.

```
User ──▶ Group ──(sts:AssumeRole)──▶ Role ──▶ 실제 권한(S3, DynamoDB …)
```

이렇게 하면 퇴사·부서 이동 시 **그룹에서 빼는 것만으로 권한이 즉시 사라지고**, 평소에는 권한이 없는 상태라 실수로 프로덕션을 건드리는 사고도 줄어든다.

**신뢰 정책과 권한 정책은 답하는 질문이 다르다.** `assume_role_policy`는 "누가 이 역할을 맡을 수 있는가"(Principal + `sts:AssumeRole`), `aws_iam_role_policy`는 "이 역할이 무엇을 할 수 있는가"(Action + Resource). 신뢰 정책에 작업 권한을 넣으면 AWS가 정책 형식 자체를 거부한다.

**IAM Role은 EC2에 직접 붙지 않는다.** 소프트웨어적 개념이라 `aws_iam_instance_profile`이라는 어댑터를 거쳐 장착된다.

**정책 JSON은 히어독 대신 `jsonencode()`.** 히어독은 내용을 검사하지 않고 그대로 AWS에 보내서, 쉼표 누락이나 키 오타를 AWS가 거부한 뒤에야 알게 된다. `jsonencode()`는 HCL 객체로 쓰므로 괄호·쉼표를 Terraform이 만들어 주고 오타가 `terraform validate`에서 잡히며, 리소스 참조(`aws_iam_role.x.arn`)를 문자열 보간 없이 넣을 수 있다.

## 교재 코드에서 고친 것

| 항목 | 교재(구버전) | 현행 | 이유 |
|---|---|---|---|
| 프로바이더 버전 제약 | `provider "aws" { version = ... }` | `terraform { required_providers {} }` | Terraform 0.13부터 이동. 구문법은 deprecated |
| S3 버저닝 | `aws_s3_bucket` 안의 인라인 `versioning {}` | `aws_s3_bucket_versioning` 별도 리소스 | Provider 4.0에서 분리. 설정 하나만 바꿔도 버킷 전체가 재계산되고 부분 실패 시 상태가 꼬이던 문제 |
| 상태 잠금 | DynamoDB `terraform-lock` 테이블 | `use_lockfile = true` (S3 네이티브 락) | `dynamodb_table` 인자는 공식 deprecated. `<key>.tflock`을 조건부 생성해 잠그므로 별도 테이블이 필요 없다 |
| 정책 `Version` | 생략 가능 | `"2012-10-17"` 명시 | 생략하면 기본값 `2008-10-17`로 취급되어 정책 변수(`${aws:username}` 등)가 조용히 동작하지 않는다 |
| 그룹 멤버십 | `aws_iam_group_membership` | `aws_iam_user_group_membership` 검토 | 전자는 그룹 멤버 목록을 **배타적으로 덮어써서** 다른 코드나 콘솔이 추가한 멤버를 매 apply마다 지운다 |
| 보안 그룹 규칙 | `aws_security_group_rule` | `aws_vpc_security_group_ingress_rule` | 구 리소스는 규칙 1개에 CIDR 여러 개가 들어가 Terraform과 AWS의 규칙 개수가 어긋났다(drift). 신규는 규칙 1개 = CIDR 1개 |
| S3 버킷 이름 | 교재 예제 이름 그대로 | 식별자 접미사 | 버킷 이름은 리전·계정이 아니라 **전 세계에서 고유**해야 한다 (DynamoDB 테이블은 리전+계정 단위) |

## 실행

```bash
cd 01-backend
terraform init && terraform apply     # 백엔드용 버킷·잠금 먼저

cd ../02-vpc
terraform init
terraform validate && terraform plan  # ← 여기까지는 무료
terraform apply                       # NAT 과금 시작. 확인 끝나면 destroy
terraform destroy
```

`terraform.tfvars`는 계정 고유값이라 커밋하지 않는다. `terraform.tfvars.example`을 복사해 채운다.

## 비용에 대해

**NAT Gateway는 시간당 과금이다** (ap-northeast-2 기준 약 $0.059/h + 데이터 처리 요금). 한 달 켜두면 5만 원대다. 그래서 `02-vpc`는 `apply`로 동작을 확인한 뒤 `destroy`로 정리했고, 저장소에는 코드만 남겨 뒀다. 상시 띄워 둘 이유가 없는 리소스다.

같은 이유로 프라이빗 서브넷에서 S3에 접근할 일이 생기면 NAT가 아니라 **Gateway 엔드포인트**를 쓰는 게 맞다 — 엔드포인트 자체가 무료이고 NAT 데이터 처리 요금도 발생하지 않는다.

## 범위

**단일 AZ 구성이다.** 이중화하려면 AZ마다 서브넷과 NAT Gateway를 따로 둬야 하고, NAT는 AZ당 하나씩 필요해 비용이 그대로 배가 된다. 학습 목적이라 한 AZ로 뒀다.

모듈화와 멀티 환경(dev/stg/prod) 분리, CI에서의 `plan` 자동 실행은 아직이다. VPC 위에 올라가는 컴퓨트 계층(EC2·ALB)도 없다.
