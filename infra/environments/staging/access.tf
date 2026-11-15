resource "aws_iam_role" "cluster_admin" {
  name                 = "inference-router-staging-cluster-admin"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = var.cluster_admin_principal_arn }
    }]
  })
}

resource "aws_eks_access_entry" "cluster_admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.cluster_admin.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "cluster_admin" {
  cluster_name  = aws_eks_access_entry.cluster_admin.cluster_name
  principal_arn = aws_eks_access_entry.cluster_admin.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

resource "aws_iam_role" "session_host" {
  name = "inference-router-staging-session-host"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "session_host" {
  role       = aws_iam_role.session_host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "session_host" {
  name = "inference-router-staging-session-host"
  role = aws_iam_role.session_host.name
}

resource "aws_security_group" "session_host" {
  name        = "inference-router-staging-session-host"
  description = "Private Session Manager host with no inbound access"
  vpc_id      = aws_vpc.staging.id
}

resource "aws_vpc_security_group_egress_rule" "session_host_https" {
  security_group_id = aws_security_group.session_host.id
  description       = "HTTPS to AWS Systems Manager and the private EKS API"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "cluster_api_from_session_host" {
  security_group_id            = module.eks.cluster_security_group_id
  referenced_security_group_id = aws_security_group.session_host.id
  description                  = "HTTPS from the private Session Manager host"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_instance" "session_host" {
  ami                         = var.session_host_ami_id
  instance_type               = "t4g.micro"
  subnet_id                   = aws_subnet.private["usw2-az1"].id
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.session_host.name
  vpc_security_group_ids      = [aws_security_group.session_host.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
  }

  tags = { Name = "inference-router-staging-session-host" }

  depends_on = [
    aws_route.private_internet,
    aws_route_table_association.private,
    aws_iam_role_policy_attachment.session_host,
    aws_vpc_security_group_egress_rule.session_host_https,
  ]
}

output "cluster_admin_role_arn" {
  description = "Role to assume when generating a Kubernetes token for staging."
  value       = aws_iam_role.cluster_admin.arn
}

output "session_host_instance_id" {
  description = "Systems Manager port-forwarding target for the private EKS API."
  value       = aws_instance.session_host.id
}
