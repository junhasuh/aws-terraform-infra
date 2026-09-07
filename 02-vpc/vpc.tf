# VPC · 서브넷 · IGW · NAT Gateway · 라우팅
#
# 주의: NAT Gateway는 시간당 과금(ap-northeast-2 기준 약 $0.059/h) + 데이터 처리 요금이다.
#       실습 검증이 끝나면 반드시 terraform destroy 로 정리할 것.

locals {
  # 퍼블릭·프라이빗을 같은 AZ에 묶는다. NAT Gateway가 퍼블릭 서브넷에 있으므로,
  # 프라이빗이 다른 AZ에 있으면 아웃바운드 트래픽이 매번 AZ를 건너 요금이 붙는다.
  az = "ap-northeast-2a"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true # 기본값 false. EC2 퍼블릭 DNS 이름이 필요하면 켜야 한다

  tags = { Name = "terraform-101" }
}

resource "aws_subnet" "public_subnet" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.0.0/24"
  availability_zone = local.az

  # 이걸 켜지 않으면 인스턴스에 퍼블릭 IP가 붙지 않는다.
  # IGW는 퍼블릭 IP ↔ 사설 IP를 1:1 매핑하는 것이므로,
  # 퍼블릭 IP가 없으면 퍼블릭 서브넷에 있어도 인터넷과 통신하지 못한다.
  map_public_ip_on_launch = true

  tags = { Name = "terraform-101-public-subnet" }
}

resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.10.0/24"
  availability_zone = local.az

  tags = { Name = "terraform-101-private-subnet" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "terraform-101-igw" }
}

resource "aws_eip" "nat" {
  domain = "vpc" # Provider v5에서 vpc = true 는 deprecated, v6에서 제거됨

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_nat_gateway" "nat_gateway" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_subnet.id

  # NAT Gateway가 EIP로 외부와 통신하려면 IGW가 VPC에 먼저 붙어 있어야 한다.
  # 참조 관계로는 드러나지 않는 의존성이라 명시한다.
  depends_on = [aws_internet_gateway.igw]

  tags = { Name = "terraform-NATGW" }
}

# ── 라우팅 ────────────────────────────────────────────────
# 퍼블릭과 프라이빗을 가르는 것은 서브넷 이름이 아니라
# 라우트 테이블이 0.0.0.0/0 을 어디로 보내느냐다.
#
# 인라인 route {} 블록과 독립 aws_route 리소스는 같은 테이블에 섞으면
# 서로의 규칙을 지우려 들어 plan에 diff가 영원히 남는다.
# 여기서는 aws_route 로 통일한다 — 나중에 피어링·VPN 경로를
# 다른 파일이나 모듈에서 붙일 수 있다.

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "terraform-101-rt-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id # IGW는 gateway_id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "terraform-101-rt-private" }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat_gateway.id # NAT는 nat_gateway_id
}

# 이 시점에 비로소 서브넷이 "퍼블릭"이 된다
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private_subnet.id
  route_table_id = aws_route_table.private.id
}
