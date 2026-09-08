# aws-terraform-infra

Terraform으로 VPC와 IAM, S3 원격 백엔드를 만들어 본 실습 저장소.

인프런 「IaC with Terraform」을 따라 시작했는데 교재 코드가 AWS Provider v2 시절 문법이라 절반쯤은 다시 써야 했다. 뭘 왜 바꿨는지는 아래 표에 정리해 뒀다. 막힌 지점은 [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md)에 에러 원문이랑 확인 순서를 그대로 남겼다.

## 구성

```
01-backend/    S3 버킷과 상태 잠금. 나머지가 상태를 여기 올린다
02-vpc/        VPC, 서브넷, IGW, NAT Gateway, 라우팅
03-iam/        IAM 사용자와 그룹, 멤버십
04-iam-role/   EC2가 맡는 역할과 인스턴스 프로파일
05-s3/         S3 버킷과 객체
```

번호가 곧 구성 순서다. 백엔드가 먼저 있어야 나머지가 상태를 저장할 데가 생긴다.

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

## 네트워크

퍼블릭이냐 프라이빗이냐를 가르는 건 서브넷 이름이 아니라 라우트 테이블이다. 0.0.0.0/0을 IGW로 보내면 퍼블릭이고 NAT Gateway로 보내면 프라이빗이다. 이름은 상관없다.

IGW는 퍼블릭 IP와 사설 IP를 1대1로 매핑하니까 밖에서 먼저 접속을 걸 수 있다. NAT는 여러 사설 IP를 EIP 하나로 묶는 다대일 변환이라 반대 방향 매핑이 아예 없다. 프라이빗에 인바운드가 안 되는 건 보안 그룹이 막아서가 아니라 돌아올 길이 없어서다.

퍼블릭과 프라이빗은 같은 AZ에 뒀다. NAT가 퍼블릭 서브넷에 있는데 프라이빗이 다른 AZ면 아웃바운드가 매번 AZ를 건너고 그만큼 요금이 붙는다.

`map_public_ip_on_launch`는 켜 놨다. IGW는 퍼블릭 IP가 붙은 인스턴스만 상대해서, 이게 꺼져 있으면 퍼블릭 서브넷에 있어도 인터넷이 안 된다. 처음엔 이걸 몰라서 한참 헤맸다.

라우트는 전부 `aws_route`로 통일했다. 인라인 `route {}` 블록과 독립 리소스를 한 테이블에 섞으면 서로 상대 규칙을 지우려 들어서 plan에 diff가 계속 남는다.

## IAM

여긴 코드가 아직 엉성하다. 먼저 적어 둔다.

권한이 실제로 붙어 있는 자리가 세 군데인데 하나도 최소 권한이 아니다.

- `03-iam`의 사용자 두 명한테 인라인 정책이 직접 붙어 있다. Action도 Resource도 전부 `*`다. 정책 이름부터가 `super_admin`이다. 실습하다 권한 때문에 막히는 게 싫어서 열어 둔 건데 최소 권한 원칙과 정확히 반대다.
- 그룹에는 정책이 없다. `aws_iam_group`과 멤버십만 있어서 지금 devops 그룹은 권한 경계가 아니라 이름표다.
- `04-iam-role`의 역할은 사람이 전환해서 쓰는 역할이 아니다. 신뢰 정책의 Principal이 `ec2.amazonaws.com`이라 EC2만 맡을 수 있다. IAM 사용자가 `sts:AssumeRole`을 호출해도 이 역할은 거부한다.

```
지금       User ──▶ 인라인 정책 (*:*)
           User ──▶ Group (정책 없음)
           EC2  ──▶ Role (Principal: ec2) ──▶ s3:* / dynamodb:* on *

가려는 곳  User ──▶ Group ──(sts:AssumeRole)──▶ Role ──▶ 필요한 만큼만
           사용자 인라인 정책은 걷어낸다
```

아래처럼 가면 사람이 나가거나 부서를 옮길 때 그룹에서 빼는 것만으로 권한이 사라진다. 평소엔 권한이 없는 상태라 실수로 프로덕션을 건드릴 일도 줄어든다. 지금은 그 전 단계다.

권한을 좁히는 건 처음부터 정답을 맞히는 작업이 아니라고 본다. 일단 돌려 보고 CloudTrail에 남은 실제 호출을 보면서 깎아 나가는 쪽이 맞다. 아직 안 했다.

신뢰 정책과 권한 정책은 답하는 질문이 다르다. `assume_role_policy`는 누가 이 역할을 맡을 수 있느냐고, `aws_iam_role_policy`는 이 역할이 뭘 할 수 있느냐다. 신뢰 정책에 작업 권한을 넣으면 AWS가 형식 자체를 거부한다.

IAM Role은 EC2에 직접 안 붙는다. `aws_iam_instance_profile`을 거쳐야 장착된다. 이걸 몰라서 역할만 만들어 놓고 왜 안 붙나 했다.

정책 JSON은 히어독보다 `jsonencode()`가 낫다. 히어독은 내용을 안 보고 그대로 AWS에 던져서 쉼표 하나 빠진 걸 AWS가 거부한 뒤에야 알게 된다. `jsonencode()`는 HCL 객체로 쓰니까 오타가 `terraform validate`에서 잡히고, 리소스 참조도 문자열 보간 없이 그냥 넣을 수 있다.

## 교재에서 고친 것

| 항목 | 교재 | 현행 | 이유 |
|---|---|---|---|
| 프로바이더 버전 제약 | `provider "aws" { version = ... }` | `terraform { required_providers {} }` | 0.13부터 자리가 옮겨졌다. 구문법은 deprecated |
| S3 버저닝 | `aws_s3_bucket` 안의 인라인 `versioning {}` | `aws_s3_bucket_versioning` 별도 리소스 | Provider 4.0에서 분리됐다. 설정 하나 바꿔도 버킷 전체가 재계산되고 부분 실패하면 상태가 꼬였다 |
| 상태 잠금 | DynamoDB `terraform-lock` 테이블 | `use_lockfile = true` | `dynamodb_table` 인자가 deprecated 됐다. S3에 `.tflock` 파일을 조건부로 만들어 잠그니 테이블이 필요없다 |
| 정책 `Version` | 생략 | `"2012-10-17"` 명시 | 생략하면 2008년 버전으로 취급돼서 정책 변수가 조용히 안 먹는다 |
| 그룹 멤버십 | `aws_iam_group_membership` | `aws_iam_user_group_membership` 검토 중 | 전자는 멤버 목록을 배타적으로 덮어써서, 콘솔이나 다른 코드가 넣은 멤버를 apply 할 때마다 지운다 |
| 보안 그룹 규칙 | `aws_security_group_rule` | `aws_vpc_security_group_ingress_rule` | 구 리소스는 규칙 하나에 CIDR을 여러 개 넣을 수 있어서 Terraform이 세는 규칙 수와 AWS 쪽이 어긋났다. 신규는 규칙 하나에 CIDR 하나 |
| S3 버킷 이름 | 교재 예제 이름 그대로 | 식별자 붙임 | 버킷 이름은 리전이나 계정이 아니라 전 세계에서 고유해야 한다. DynamoDB 테이블과 다른 점 |

## 실행

```bash
cd 01-backend
terraform init && terraform apply     # 백엔드용 버킷과 잠금 먼저

cd ../02-vpc
terraform init
terraform validate && terraform plan  # 여기까지는 돈 안 든다
terraform apply                       # NAT 과금 시작
terraform destroy                     # 확인 끝나면 바로
```

`terraform.tfvars`는 계정 고유값이라 커밋하지 않는다. `terraform.tfvars.example`을 복사해서 채우면 된다.

## 비용

NAT Gateway는 시간당 과금이다. 한 달 내내 켜 두면 5만 원이 넘는다. 그래서 `02-vpc`는 apply로 통신만 확인하고 destroy 했고 저장소에는 코드만 남아 있다.

프라이빗에서 S3에 붙을 일이 생기면 NAT 말고 Gateway 엔드포인트를 쓰는 게 맞다. 엔드포인트 자체가 무료고 NAT 데이터 처리 요금도 안 붙는다.

## 아직 안 된 것

단일 AZ다. 이중화하려면 AZ마다 서브넷과 NAT를 따로 둬야 하는데 NAT는 AZ당 하나씩 필요해서 비용이 그대로 두 배가 된다. 학습용이라 하나로 뒀다.

모듈화, 환경 분리, CI에서 plan 자동 실행은 아직이다. VPC 위에 올라갈 EC2나 ALB도 없다. IAM은 위에 적은 대로다.
