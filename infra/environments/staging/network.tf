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
