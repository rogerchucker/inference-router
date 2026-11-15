resource "aws_vpc" "dev" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "inference-router-dev" }
}

resource "aws_subnet" "private" {
  for_each = {
    usw2-az1 = cidrsubnet(var.vpc_cidr, 8, 0)
    usw2-az2 = cidrsubnet(var.vpc_cidr, 8, 1)
  }

  vpc_id                  = aws_vpc.dev.id
  availability_zone_id    = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = false

  tags = { Name = "inference-router-dev-private-${each.key}" }
}

# One NAT gateway serves both private dev subnets.
resource "aws_subnet" "nat_public" {
  vpc_id                  = aws_vpc.dev.id
  availability_zone_id    = "usw2-az1"
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 2)
  map_public_ip_on_launch = false

  tags = { Name = "inference-router-dev-nat-public" }
}

resource "aws_internet_gateway" "dev" {
  vpc_id = aws_vpc.dev.id

  tags = { Name = "inference-router-dev" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.dev.id

  tags = { Name = "inference-router-dev-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.dev.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.nat_public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = { Name = "inference-router-dev-nat" }
}

resource "aws_nat_gateway" "dev" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.nat_public.id

  tags = { Name = "inference-router-dev" }

  depends_on = [aws_route.public_internet, aws_route_table_association.public]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.dev.id

  tags = { Name = "inference-router-dev-private" }
}

resource "aws_route" "private_internet" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.dev.id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

output "nat_egress_ip" {
  description = "Public source IP for dev internet egress."
  value       = aws_eip.nat.public_ip
}
