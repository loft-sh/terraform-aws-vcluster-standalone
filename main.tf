provider "aws" {
  region = var.aws_region
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ssm_parameter" "ubuntu_ami" {
  name = var.ubuntu_ami_ssm_parameter_name
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "kubeconfig_parameter_write" {
  statement {
    actions = [
      "ssm:PutParameter",
    ]

    resources = [
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.kubeconfig_parameter_name}",
    ]
  }
}

resource "random_password" "cluster_join_token" {
  length  = 32
  special = false
}

locals {
  az_count = min(var.availability_zone_count, length(data.aws_availability_zones.available.names))
  azs      = slice(data.aws_availability_zones.available.names, 0, local.az_count)

  cluster_join_token = coalesce(var.cluster_join_token, random_password.cluster_join_token.result)

  common_tags = merge(
    {
      Project   = var.project_name
      ManagedBy = "terraform"
    },
    var.tags,
  )

  public_subnet_cidrs = [
    for index in range(local.az_count) : cidrsubnet(var.vpc_cidr, 8, index)
  ]

  control_plane_subnet_cidrs = [
    for index in range(local.az_count) : cidrsubnet(var.vpc_cidr, 8, local.az_count + index)
  ]

  worker_subnet_cidrs = [
    for index in range(local.az_count) : cidrsubnet(var.vpc_cidr, 8, (local.az_count * 2) + index)
  ]

  resource_name_prefix = substr(replace(var.project_name, "_", "-"), 0, 20)
  selected_ami_id      = coalesce(var.ami_id, data.aws_ssm_parameter.ubuntu_ami.value)
  kubeconfig_parameter_name = coalesce(
    var.kubeconfig_parameter_name,
    "/${var.project_name}/kubeconfig",
  )
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-vpc"
  })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-igw"
  })
}

resource "aws_subnet" "public" {
  count = local.az_count

  vpc_id                  = aws_vpc.main.id
  availability_zone       = local.azs[count.index]
  cidr_block              = local.public_subnet_cidrs[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-public-${count.index + 1}"
    Tier = "public"
  })
}

resource "aws_subnet" "control_plane" {
  count = local.az_count

  vpc_id                  = aws_vpc.main.id
  availability_zone       = local.azs[count.index]
  cidr_block              = local.control_plane_subnet_cidrs[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-control-plane-${count.index + 1}"
    Tier = "control-plane"
  })
}

resource "aws_subnet" "worker" {
  count = local.az_count

  vpc_id                  = aws_vpc.main.id
  availability_zone       = local.azs[count.index]
  cidr_block              = local.worker_subnet_cidrs[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-worker-${count.index + 1}"
    Tier = "worker"
  })
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-nat-eip"
  })
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-nat"
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-public-rt"
  })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-private-rt"
  })
}

resource "aws_route_table_association" "public" {
  count = local.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "control_plane" {
  count = local.az_count

  subnet_id      = aws_subnet.control_plane[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "worker" {
  count = local.az_count

  subnet_id      = aws_subnet.worker[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "control_plane" {
  name        = "${local.resource_name_prefix}-control-plane-sg"
  description = "Control plane security group"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-control-plane-sg"
  })
}

resource "aws_security_group" "worker" {
  name        = "${local.resource_name_prefix}-worker-sg"
  description = "Worker security group"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-worker-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "control_plane_internal" {
  security_group_id = aws_security_group.control_plane.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
  description       = "Internal cluster traffic within the VPC"
}

resource "aws_vpc_security_group_ingress_rule" "worker_internal" {
  security_group_id = aws_security_group.worker.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
  description       = "Internal cluster traffic within the VPC"
}

resource "aws_vpc_security_group_ingress_rule" "control_plane_ssh" {
  for_each = var.key_name == null ? toset([]) : toset(var.ssh_allowed_cidrs)

  security_group_id = aws_security_group.control_plane.id
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "Optional SSH access to control plane nodes"
}

resource "aws_vpc_security_group_ingress_rule" "worker_ssh" {
  for_each = var.key_name == null ? toset([]) : toset(var.ssh_allowed_cidrs)

  security_group_id = aws_security_group.worker.id
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "Optional SSH access to worker nodes"
}

resource "aws_vpc_security_group_egress_rule" "control_plane_all" {
  security_group_id = aws_security_group.control_plane.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Outbound internet access"
}

resource "aws_vpc_security_group_egress_rule" "worker_all" {
  security_group_id = aws_security_group.worker.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Outbound internet access"
}

resource "aws_lb" "control_plane" {
  name                             = "${local.resource_name_prefix}-nlb"
  load_balancer_type               = "network"
  internal                         = false
  subnets                          = aws_subnet.public[*].id
  enable_cross_zone_load_balancing = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-nlb"
  })
}

resource "aws_lb_target_group" "control_plane" {
  name               = "${local.resource_name_prefix}-cp-tg"
  port               = var.control_plane_target_port
  protocol           = "TCP"
  target_type        = "instance"
  vpc_id             = aws_vpc.main.id
  preserve_client_ip = false

  health_check {
    enabled  = true
    protocol = "TCP"
    port     = tostring(var.control_plane_target_port)
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-control-plane-tg"
  })
}

resource "aws_lb_listener" "control_plane" {
  load_balancer_arn = aws_lb.control_plane.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.control_plane.arn
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${local.resource_name_prefix}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "kubeconfig_parameter_write" {
  name   = "${local.resource_name_prefix}-kubeconfig-parameter"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.kubeconfig_parameter_write.json
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.resource_name_prefix}-ec2-profile"
  role = aws_iam_role.ec2.name

  tags = local.common_tags
}

resource "aws_instance" "control_plane_bootstrap" {
  ami                         = local.selected_ami_id
  instance_type               = var.control_plane_instance_type
  subnet_id                   = aws_subnet.control_plane[0].id
  vpc_security_group_ids      = [aws_security_group.control_plane.id]
  key_name                    = var.key_name
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/control-plane-bootstrap.sh.tftpl", {
    aws_region                = var.aws_region
    cluster_join_token        = local.cluster_join_token
    kubeconfig_parameter_name = local.kubeconfig_parameter_name
    kubernetes_version        = var.kubernetes_version
    load_balancer_dns         = aws_lb.control_plane.dns_name
    vcluster_name             = var.vcluster_name
    vcluster_version          = var.vcluster_version
  })

  root_block_device {
    volume_size           = var.control_plane_root_volume_size_gb
    volume_type           = "gp3"
    delete_on_termination = true
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-cp-0"
    Role = "control-plane"
  })

  depends_on = [aws_lb_listener.control_plane]
}

resource "aws_instance" "control_plane" {
  count = max(var.control_plane_count - 1, 0)

  ami                         = local.selected_ami_id
  instance_type               = var.control_plane_instance_type
  subnet_id                   = aws_subnet.control_plane[(count.index + 1) % local.az_count].id
  vpc_security_group_ids      = [aws_security_group.control_plane.id]
  key_name                    = var.key_name
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/control-plane-join.sh.tftpl", {
    cluster_join_token = local.cluster_join_token
    load_balancer_dns  = aws_lb.control_plane.dns_name
  })

  root_block_device {
    volume_size           = var.control_plane_root_volume_size_gb
    volume_type           = "gp3"
    delete_on_termination = true
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-cp-${count.index + 1}"
    Role = "control-plane"
  })

  depends_on = [aws_instance.control_plane_bootstrap]
}

resource "aws_instance" "worker" {
  count = var.worker_count

  ami                         = local.selected_ami_id
  instance_type               = var.worker_instance_type
  subnet_id                   = aws_subnet.worker[count.index % local.az_count].id
  vpc_security_group_ids      = [aws_security_group.worker.id]
  key_name                    = var.key_name
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/worker-join.sh.tftpl", {
    cluster_join_token = local.cluster_join_token
    load_balancer_dns  = aws_lb.control_plane.dns_name
  })

  root_block_device {
    volume_size           = var.worker_root_volume_size_gb
    volume_type           = "gp3"
    delete_on_termination = true
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-worker-${count.index + 1}"
    Role = "worker"
  })

  depends_on = [aws_instance.control_plane_bootstrap]
}

resource "aws_lb_target_group_attachment" "control_plane_bootstrap" {
  target_group_arn = aws_lb_target_group.control_plane.arn
  target_id        = aws_instance.control_plane_bootstrap.id
  port             = var.control_plane_target_port
}

resource "aws_lb_target_group_attachment" "control_plane" {
  count = length(aws_instance.control_plane)

  target_group_arn = aws_lb_target_group.control_plane.arn
  target_id        = aws_instance.control_plane[count.index].id
  port             = var.control_plane_target_port
}
