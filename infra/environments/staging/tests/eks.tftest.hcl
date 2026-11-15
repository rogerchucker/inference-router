mock_provider "aws" {}

variables {
  kubernetes_version = "1.35"
  cluster_role_arn   = "arn:aws:iam::123456789012:role/example-eks-control-plane"
  private_subnet_ids = ["subnet-00000000000000001", "subnet-00000000000000002"]
}

run "staging_root_wires_the_cluster" {
  command = plan

  assert {
    condition     = output.cluster_name == "inference-router-staging"
    error_message = "The staging root must name the cluster inference-router-staging."
  }

  assert {
    condition = (
      length(aws_subnet.private) == 2 &&
      alltrue([for subnet in aws_subnet.private : !subnet.map_public_ip_on_launch])
    )
    error_message = "Staging must use two subnets without public IP assignment."
  }

  assert {
    condition = (
      aws_eks_node_group.workers.scaling_config[0].desired_size == 2 &&
      aws_eks_node_group.workers.ami_type == "AL2023_x86_64_STANDARD" &&
      aws_launch_template.workers.metadata_options[0].http_tokens == "required"
    )
    error_message = "Staging must start two x86 AL2023 workers with IMDSv2 required."
  }

  assert {
    condition = (
      length(aws_route_table_association.private) == 2 &&
      aws_route.private_internet.destination_cidr_block == "0.0.0.0/0" &&
      !aws_instance.session_host.associate_public_ip_address &&
      aws_vpc_security_group_ingress_rule.cluster_api_from_session_host.from_port == 443
    )
    error_message = "Both worker subnets need an egress route, and admin access must use the private session host over HTTPS."
  }
}

run "module_uses_private_endpoint_and_explicit_access" {
  command = plan

  module {
    source = "../../modules/eks-control-plane"
  }

  variables {
    cluster_name = "example"
  }

  assert {
    condition = (
      aws_eks_cluster.this.vpc_config[0].endpoint_private_access &&
      !aws_eks_cluster.this.vpc_config[0].endpoint_public_access
    )
    error_message = "The EKS API must be reachable only through its private endpoint."
  }

  assert {
    condition = (
      aws_eks_cluster.this.access_config[0].authentication_mode == "API" &&
      !aws_eks_cluster.this.access_config[0].bootstrap_cluster_creator_admin_permissions
    )
    error_message = "EKS must use access entries without granting the cluster creator implicit admin access."
  }

  assert {
    condition = (
      toset(aws_eks_cluster.this.vpc_config[0].subnet_ids) == var.private_subnet_ids &&
      aws_eks_cluster.this.role_arn == var.cluster_role_arn &&
      aws_eks_cluster.this.version == var.kubernetes_version
    )
    error_message = "The cluster must use the supplied subnets, control plane role, and Kubernetes version."
  }
}

run "module_rejects_fewer_than_two_distinct_subnets" {
  command = plan

  module {
    source = "../../modules/eks-control-plane"
  }

  variables {
    cluster_name       = "example"
    private_subnet_ids = ["subnet-00000000000000001", "subnet-00000000000000001"]
  }

  expect_failures = [var.private_subnet_ids]
}
