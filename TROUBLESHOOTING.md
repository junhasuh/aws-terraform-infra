# TROUBLESHOOTING

작업 중 막힌 지점의 기록. 증상은 에러 메시지 원문 그대로 남긴다.

---

## 1. IAM 역할 권한 확장 중 `AccessDenied`

**증상**

```
aws_iam_role.hello: Refreshing state... [id=hello-iam-role]
Error: error reading IAM Role (hello-iam-role): AccessDenied:
User: arn:aws:sts::<ACCOUNT_ID>:assumed-role/hello-iam-role/i-0xxxxxxxxxxxxxxxx
is not authorized to perform: iam:GetRole on resource: role hello-iam-role
```

더 이상했던 점: 직전에 `~/.aws/credentials`를 지웠는데도 다른 AWS 명령은 계속 동작했다.

**확인 순서**

```bash
aws sts get-caller-identity   # IAM 사용자가 아니라 assumed-role 로 찍힘
env | grep AWS                # 환경변수에 남은 키 없음
```

**원인 — AWS 자격 증명 체인**

SDK와 CLI는 다음 순서로 자격 증명을 찾고 **먼저 발견된 것을 쓴다.**

1. 환경변수 `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
2. 공유 크리덴셜 파일 `~/.aws/credentials`
3. ECS 컨테이너 크리덴셜 엔드포인트
4. EC2 인스턴스 메타데이터(IMDS) — 인스턴스 프로파일의 임시 토큰

크리덴셜 파일을 지우자 4번으로 내려가 인스턴스 프로파일의 역할을 쓰게 됐고, 그 역할에는 `iam:GetRole`이 없었다. Terraform은 수정 전 항상 현재 상태를 조회(`Refreshing state...`)하므로 그 단계에서 막힌다.

**해결** — 콘솔에서 역할에 필요한 권한을 부여. 같은 코드가 그대로 통과.

**정리**

- 권한 없는 터미널 안에서는 스스로 권한을 넓힐 수 없다. 반드시 외부에서 부여해야 한다.
- AWS 에러의 첫 명령은 `aws sts get-caller-identity`. "무엇을 하려 했나"보다 "지금 누구인가"가 먼저다.
- `AdministratorAccess`를 EC2 역할에 붙이는 건 마지막 수단이다. 그 인스턴스에 접근 가능한 모든 프로세스가 계정 전체를 조작할 수 있게 된다. 붙였다면 막힌 단계를 통과한 직후 뗀다 — 콘솔에서 붙인 관리형 정책은 state 밖이라 `destroy`로도 사라지지 않는다.

---

## 2. IAM 그룹 멤버십 `NoSuchEntity` 404

**증상**

```
Error: NoSuchEntity: The user with name <username> cannot be found.
	status code: 404
	on devops_group.tf line 5, in resource "aws_iam_group_membership" "devops"
```

그런데 그 사용자를 만드는 `aws_iam_user` 리소스는 같은 코드 안에 선언돼 있었다.

**확인 순서**

```bash
# 1) 이름 오타 확인 — 선언부와 참조부 대조. 일치했다.
# 2) 실제 생성 여부
terraform state list | grep iam       # 사용자는 생성돼 있었다
```

→ "없다"가 아니라 "그 시점에는 아직 없었다". 이름이 아니라 **순서** 문제.

**원인 — 의존성 그래프가 만들어지지 않았다**

```hcl
# ✗ 문자열 목록은 "참조"가 아니라서 두 리소스가 무관한 것으로 판단된다
users = var.iam_user_list
```

Terraform은 리소스끼리의 참조 관계로 의존성 그래프를 만들어 실행 순서를 정한다. 의존성이 없는 리소스는 기본 10개(`-parallelism` 기본값)까지 병렬로 처리되므로, 사용자 생성 API가 끝나기 전에 멤버십 요청이 먼저 나갔다.

**해결**

```hcl
# ✓ 속성 참조 → 순서가 강제된다
users = [aws_iam_user.junha.name]

# for_each 로 만들고 있다면
users = [for u in aws_iam_user.members : u.name]
# count 로 만들고 있다면
users = aws_iam_user.members[*].name
# 변수를 유지해야 한다면
depends_on = [aws_iam_user.junha]
```

**정리**

- 선언형 도구에서 "코드에 함께 적혀 있다"는 "순서대로 실행된다"를 뜻하지 않는다.
- `aws_iam_group_membership`은 **그룹의 멤버 목록을 배타적으로 덮어쓴다.** 콘솔이나 다른 코드가 추가한 멤버를 매 apply마다 지운다. 여러 담당자가 같은 그룹을 나눠 관리한다면 사용자 관점인 `aws_iam_user_group_membership`이 안전하다.

---

## 3. 작업용 인스턴스가 저장 시 멈춤 — OOM

**증상** — Terraform 실행 중 편집기로 `.tf` 파일을 저장하면 인스턴스 전체가 응답하지 않음.

**확인 순서**

```bash
free -h
# Mem: 415Mi total / available 290Mi   ← Terraform 한 사이클을 버티기 어려운 수치
dmesg -T | grep -i "out of memory"     # Killed process ... → OOM 확정

# 인스턴스 타입 확정 (free -h 의 total 로는 확정 불가 — 커널 예약분 탓에 항상 작게 나온다)
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-type
```

**원인** — Terraform이 AWS Provider 플러그인을 메모리에 올린 상태에서 편집기가 파일 I/O 버퍼를 잡자 RAM 초과 → OOM-Killer.

**해결(임시)** — 2GB 스왑 파일

```bash
sudo swapoff -a
sudo dd if=/dev/zero of=/swapfile bs=128M count=16
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile swap swap defaults 0 0' | sudo tee -a /etc/fstab
free -h
```

**정리 — 이게 정답이 아닌 이유**

- 요금은 늘지 않는다. EBS는 **할당한 볼륨 크기** 기준 과금이라 그 안을 스왑으로 채워도 청구액은 같다.
- 그러나 스왑을 실제로 밟기 시작하면 EBS I/O가 폭증하고 gp2·gp3의 IOPS 크레딧을 소모해 전체가 더 느려진다. **학습 환경의 응급처치이고, 실서비스에서 스왑을 계속 밟고 있다면 답은 인스턴스 타입 상향이다.**
- `vm.swappiness` 기본값 60은 데스크톱 기준이다. 서버는 RAM 우선으로 `10` 정도가 적절하다.

---

## 에러 사전

| 에러 | 원인 | 조치 |
|---|---|---|
| `invalid character '{' after array element` | 정책 JSON `Statement` 배열의 쉼표 누락 | 근본 대책은 히어독 대신 `jsonencode()` |
| `MalformedPolicyDocument: Syntax errors in policy` | 키 오타 또는 `Version` 누락 | `"Version": "2012-10-17"` 명시 |
| `Reference to undeclared resource` | 선언명과 참조명 불일치, 또는 참조 대상만 먼저 삭제 | `destroy`도 코드 검증을 먼저 한다. 참조하는 블록도 같이 삭제하거나 `terraform state rm` |
| `BucketAlreadyExists` (409) | S3 버킷 이름은 **전 세계** 고유 (DynamoDB 테이블은 리전+계정 단위) | 계정 식별자나 `random_id` 접미사 |
| `Invalid AWS Region: var.aws_region` | `region = "var.aws_region"` — 따옴표 탓에 문자열 리터럴로 전달 | 따옴표 제거 |
| `Backend reinitialization required` | 에러가 아니라 절차 안내 | `terraform init` → state 복사 여부에 `yes` |
| `Unsupported Terraform Core version` | CLI가 v0.12. `source` 문법은 0.13+, AWS Provider 5.x는 TF 1.x 필요 | **`rm -rf .terraform`으로는 해결되지 않는다.** 바이너리 교체 (`tfenv`) |
| `Error refreshing state: AccessDenied` (403) | 백엔드 S3 권한 부족 | `s3:ListBucket`은 **버킷 ARN**에, `GetObject`류는 **객체 ARN(`/*`)** 에 부여. 이 둘을 혼동해 `/*`만 주는 경우가 흔하다 |

**에러가 났을 때의 순서**

1. `aws sts get-caller-identity` — 지금 누구로 실행 중인가
2. 코드의 `region`과 콘솔 리전이 같은가 — 리소스가 생성돼도 대시보드에 안 보이는 원인
3. 문법인가 권한인가 — `Invalid`/`Malformed`/`undeclared`는 문법, `AccessDenied`/`NoSuchEntity`는 권한·순서
4. `terraform state list` vs 콘솔 — state와 실제가 일치하는가
