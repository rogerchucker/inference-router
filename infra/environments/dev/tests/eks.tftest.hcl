mock_provider "aws" {}

run "dev_cluster_matches_the_private_stage_pattern" {
  command = plan

  assert {
    condition     = output.cluster_name == "inference-router-dev"
    error_message = "Dev must have its own EKS cluster."
  }

  assert {
    condition = (
      aws_vpc.dev.cidr_block == "10.43.0.0/16" &&
      toset([for subnet in aws_subnet.private : subnet.cidr_block]) == toset(["10.43.0.0/24", "10.43.1.0/24"]) &&
      length(toset([for subnet in aws_subnet.private : subnet.availability_zone_id])) == 2 &&
      alltrue([for subnet in aws_subnet.private : !subnet.map_public_ip_on_launch]) &&
      length(aws_route_table_association.private) == 2 &&
      aws_route.private_internet.destination_cidr_block == "0.0.0.0/0"
    )
    error_message = "Dev needs two private subnets in distinct zones and a shared NAT route."
  }

  assert {
    condition = (
      aws_eks_node_group.workers.scaling_config[0].desired_size == 2 &&
      aws_eks_node_group.workers.ami_type == "AL2023_x86_64_STANDARD" &&
      aws_launch_template.workers.metadata_options[0].http_tokens == "required"
    )
    error_message = "Dev must start two x86 AL2023 workers with IMDSv2 required."
  }

  assert {
    condition = (
      aws_iam_role.cluster_admin.name == "inference-router-dev-cluster-admin" &&
      aws_eks_access_policy_association.cluster_admin.access_scope[0].type == "cluster" &&
      !aws_instance.session_host.associate_public_ip_address &&
      aws_vpc_security_group_ingress_rule.cluster_api_from_session_host.from_port == 443
    )
    error_message = "Dev operator access must use the Dev access entry and private Session Manager host."
  }

  assert {
    condition     = aws_secretsmanager_secret.providers.name == "inference-router/dev/providers"
    error_message = "Dev must use a separate Secrets Manager container."
  }
}
