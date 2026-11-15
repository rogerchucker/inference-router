resource "aws_vpc" "staging" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "inference-router-staging" }
}

resource "aws_subnet" "private" {
  for_each = {
    usw2-az1 = "10.42.0.0/24"
    usw2-az2 = "10.42.1.0/24"
  }

  vpc_id                  = aws_vpc.staging.id
  availability_zone_id    = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = false

  tags = { Name = "inference-router-staging-private-${each.key}" }
}

# One NAT gateway serves both private staging subnets.
resource "aws_subnet" "nat_public" {
  vpc_id                  = aws_vpc.staging.id
  availability_zone_id    = "usw2-az1"
  cidr_block              = "10.42.2.0/24"
  map_public_ip_on_launch = false

  tags = { Name = "inference-router-staging-nat-public" }
}

resource "aws_internet_gateway" "staging" {
  vpc_id = aws_vpc.staging.id

  tags = { Name = "inference-router-staging" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.staging.id

  tags = { Name = "inference-router-staging-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.staging.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.nat_public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = { Name = "inference-router-staging-nat" }
}

resource "aws_nat_gateway" "staging" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.nat_public.id

  tags = { Name = "inference-router-staging" }

  depends_on = [aws_route.public_internet, aws_route_table_association.public]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.staging.id

  tags = { Name = "inference-router-staging-private" }
}

resource "aws_route" "private_internet" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.staging.id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

output "nat_egress_ip" {
  description = "Public source IP for staging internet egress."
  value       = aws_eip.nat.public_ip
}
