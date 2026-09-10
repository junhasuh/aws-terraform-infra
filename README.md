# aws-terraform-infra

Terraform으로 AWS의 VPC, IAM, S3를 구성한 프로젝트입니다. S3에 상태 파일을 보관하고, 네트워크와 권한을 코드로 정의해 리소스 생성부터 삭제까지 진행했습니다.

퍼블릭·프라이빗 서브넷의 인터넷 연결 경로를 나누고, IAM 사용자와 EC2 역할을 각각 구성했습니다. 작업 중 발생한 오류와 확인 과정은 [TROUBLESHOOTING.md](./TROUBLESHOOTING.md)에 정리했습니다.

## 구성

```text
01-backend/    S3 원격 백엔드와 상태 잠금
02-vpc/        VPC, 서브넷, IGW, NAT Gateway, 라우팅
03-iam/        IAM 사용자, 그룹, 멤버십
04-iam-role/   EC2용 IAM 역할과 인스턴스 프로파일
05-s3/         S3 버킷과 객체
```

백엔드를 먼저 생성한 뒤 나머지 디렉터리에서 사용합니다. 각 구성은 별도 디렉터리에서 실행하고 상태를 관리합니다.

## 네트워크

VPC는 `10.0.0.0/16`으로 잡고, `ap-northeast-2a`에 퍼블릭 서브넷과 프라이빗 서브넷을 하나씩 배치했습니다.

```text
VPC 10.0.0.0/16 · ap-northeast-2a
│
├── Public subnet  10.0.0.0/24
│   ├── 기본 경로: 0.0.0.0/0 → IGW → Internet
│   └── NAT Gateway + EIP
│
└── Private subnet  10.0.10.0/24
    └── 기본 경로: 0.0.0.0/0 → NAT Gateway → IGW → Internet
```

퍼블릭 서브넷은 IGW로, 프라이빗 서브넷은 NAT Gateway로 기본 경로를 연결했습니다. 프라이빗 서브넷에서는 NAT를 통해 외부로 연결을 시작하고 응답을 받을 수 있지만, 외부에서 NAT를 거쳐 새 연결을 시작할 수는 없습니다. ([AWS 문서](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html))

구성하면서 신경 쓴 부분은 다음과 같습니다.

- **서브넷과 NAT의 AZ를 맞췄습니다.** 프라이빗 서브넷의 인터넷 트래픽이 다른 AZ의 NAT를 경유하지 않도록 둘 다 `ap-northeast-2a`에 배치했습니다.
- **퍼블릭 IPv4 자동 할당을 켰습니다.** 처음에는 IGW 경로만 있으면 인터넷에 연결될 것으로 생각했습니다. IPv4로 IGW를 통해 직접 통신하려면 인스턴스에 퍼블릭 IP도 필요해 `map_public_ip_on_launch = true`로 설정했습니다. 보안 그룹과 네트워크 ACL도 해당 트래픽을 허용해야 합니다. ([AWS 문서](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Internet_Gateway.html))
- **라우트는 `aws_route`로 통일했습니다.** 같은 라우트 테이블에 인라인 `route {}`와 독립 리소스를 섞으면 관리 대상이 충돌할 수 있어, 라우트 테이블과 경로 정의를 분리했습니다. ([Provider 문서](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table))

## IAM

사용자·그룹 구성과 EC2용 역할을 나눠 작성했습니다. EC2 역할에는 신뢰 정책의 Principal을 `ec2.amazonaws.com`으로 지정하고, 인스턴스에 연결할 수 있도록 `aws_iam_instance_profile`을 함께 만들었습니다.

신뢰 정책에는 역할을 맡을 주체를, 권한 정책에는 허용할 작업을 정의했습니다.

현재 권한 범위는 넓게 열려 있습니다.

- `03-iam`: 사용자 두 명에게 `Action: *`, `Resource: *`인 인라인 정책이 직접 연결돼 있습니다. 그룹에는 멤버십만 있고 정책은 없습니다.
- `04-iam-role`: EC2 역할에 `s3:*`, `dynamodb:*` 권한이 전체 리소스를 대상으로 부여돼 있습니다.

다음으로 보완할 부분은 최소 권한 적용입니다. 사용자 인라인 정책을 제거하고, 그룹을 통해 별도의 작업용 역할을 맡도록 변경할 계획입니다. EC2 역할도 필요한 작업과 리소스 ARN으로 범위를 좁히려 합니다. CloudTrail 호출 기록을 바탕으로 권한을 점검하는 작업은 아직 진행하지 않았습니다.

## 실행

계정별 설정값은 `terraform.tfvars.example`을 복사해 `terraform.tfvars`에 입력합니다. 실제 값이 담긴 `terraform.tfvars`는 커밋하지 않습니다.

먼저 원격 상태를 저장할 백엔드를 생성합니다.

```bash
cd 01-backend
terraform init
terraform plan
terraform apply
```

이후 필요한 디렉터리에서 초기화와 구성을 진행합니다. VPC 기준 실행 순서는 아래와 같습니다.

```bash
cd ../02-vpc
terraform init
terraform validate
terraform plan
terraform apply

# 확인 후 VPC 리소스 삭제
terraform destroy
```

각 명령은 현재 디렉터리의 구성을 대상으로 실행됩니다. `02-vpc`에서 `destroy`해도 다른 디렉터리에서 만든 리소스는 삭제되지 않습니다.

## 비용과 현재 범위

NAT Gateway 유지 비용을 줄이기 위해 VPC는 생성 후 확인을 마치고 삭제했습니다. 현재 저장소에는 구성 코드만 남아 있습니다.

네트워크는 단일 AZ로 구성했습니다. AZ 장애에 대비한 이중화는 적용하지 않았으며, VPC에 배포할 EC2나 ALB도 아직 포함하지 않았습니다.

추가로 진행할 작업은 다음과 같습니다.

- IAM 사용자와 EC2 역할의 권한 축소
- 모듈화와 개발·운영 환경 분리
- CI에서 `terraform fmt`, `validate`, `plan` 실행
- 프라이빗 서브넷의 S3 접근을 위한 Gateway 엔드포인트 추가
