variable "aws_region" {
  description = "AWS region used for all resources."
  type        = string
  default     = "eu-central-1"
}

variable "project_name" {
  description = "Prefix used for naming AWS resources."
  type        = string
  default     = "vcluster-standalone"
}

variable "availability_zone_count" {
  description = "Number of availability zones to spread subnets across."
  type        = number
  default     = 1

  validation {
    condition     = var.availability_zone_count >= 1 && var.availability_zone_count <= 4
    error_message = "availability_zone_count must be between 1 and 4."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "allowed_public_cidrs" {
  description = "CIDR blocks allowed to reach the vCluster control-plane endpoint through the load balancer."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "key_name" {
  description = "Optional existing EC2 key pair name for SSH access."
  type        = string
  default     = null
  nullable    = true
}

variable "ssh_allowed_cidrs" {
  description = "CIDR blocks allowed to SSH to the instances when key_name is set."
  type        = list(string)
  default     = []
}

variable "control_plane_count" {
  description = "Total number of control plane nodes, including the bootstrap node."
  type        = number
  default     = 3

  validation {
    condition     = var.control_plane_count >= 1
    error_message = "control_plane_count must be at least 1."
  }
}

variable "worker_count" {
  description = "Number of worker nodes."
  type        = number
  default     = 2

  validation {
    condition     = var.worker_count >= 0
    error_message = "worker_count must be 0 or greater."
  }
}

variable "control_plane_instance_type" {
  description = "EC2 instance type for control plane nodes."
  type        = string
  default     = "t3.large"
}

variable "worker_instance_type" {
  description = "EC2 instance type for worker nodes."
  type        = string
  default     = "t3.large"
}

variable "control_plane_root_volume_size_gb" {
  description = "Root EBS volume size for control plane nodes."
  type        = number
  default     = 50
}

variable "worker_root_volume_size_gb" {
  description = "Root EBS volume size for worker nodes."
  type        = number
  default     = 50
}

variable "kubernetes_version" {
  description = "Kubernetes version passed to the standalone vCluster installer."
  type        = string
  default     = "v1.35.0"
}

variable "vcluster_version" {
  description = "vCluster standalone release version."
  type        = string
  default     = "v0.33.1"
}

variable "vcluster_name" {
  description = "Name of the vCluster standalone cluster."
  type        = string
  default     = "vcluster"
}

variable "control_plane_target_port" {
  description = "Port exposed by the standalone vCluster control plane on each control-plane node."
  type        = number
  default     = 8443
}

variable "ubuntu_ami_ssm_parameter_name" {
  description = "SSM parameter name used to resolve the Ubuntu AMI. Set ami_id directly if you want to bypass SSM lookup."
  type        = string
  default     = "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
}

variable "ami_id" {
  description = "Optional AMI ID override for all EC2 instances. When null, the Ubuntu AMI is looked up via SSM."
  type        = string
  default     = null
  nullable    = true
}

variable "cluster_join_token" {
  description = "Optional join token for the cluster. When null, Terraform generates one."
  type        = string
  default     = null
  nullable    = true
  sensitive   = true
}

variable "tags" {
  description = "Additional tags applied to all resources."
  type        = map(string)
  default     = {}
}
