# terraform-aws-vcluster-standalone

Terraform configuration for running a standalone `vCluster` on AWS EC2 with:

- a dedicated VPC
- public and private subnets
- an internet-facing Network Load Balancer
- separate control-plane and worker nodes
- private instances managed through AWS Systems Manager Session Manager

This repository is intentionally small and self-contained. It does not use any external Terraform modules.

## What This Deploys

The stack creates the following AWS resources:

- one VPC with DNS support enabled
- public subnets for the load balancer and NAT gateway
- private subnets for control-plane nodes
- private subnets for worker nodes
- one internet gateway
- one NAT gateway with one Elastic IP
- one internet-facing Network Load Balancer
- one target group and listener for the standalone vCluster API
- one IAM role and instance profile for EC2, including SSM access
- one bootstrap control-plane instance
- additional control-plane instances
- worker instances

## Architecture

Traffic flow:

1. Clients connect to the public NLB on `443`.
2. The NLB forwards traffic to the control-plane EC2 instances on `8443`.
3. Additional control-plane and worker nodes join the cluster by calling the same public load balancer endpoint.
4. Control-plane and worker nodes live in private subnets and use the NAT gateway for outbound internet access.
5. Administrative shell access is expected through SSM, not public IPs.

High-level layout:

```text
Internet
  |
  v
Public NLB :443
  |
  v
Control plane targets :8443
  |
  +--> bootstrap control-plane node
  +--> additional control-plane nodes

Private worker nodes
  |
  +--> join through the same public NLB endpoint

SSM Session Manager
  |
  +--> private control-plane and worker nodes
```

## Current Behavior

- EC2 nodes do not receive public IPs.
- The load balancer is public.
- The load balancer listener port is `443`.
- The control-plane target port on the EC2 instances is `8443`.
- Client IP preservation is disabled on the NLB target group so private nodes can safely join through the same public NLB.
- Control-plane and worker security groups allow full east-west traffic inside the VPC CIDR.
- SSH ingress is optional and disabled by default unless `key_name` and `ssh_allowed_cidrs` are set.

## How Bootstrap Works

The repository follows the standalone vCluster install flow described by Loft, but automates it with EC2 `user_data`.

Bootstrap sequence:

1. The first control-plane node writes `vcluster.yaml`.
2. It installs standalone vCluster from the configured release.
3. It bootstraps the cluster using the generated or provided join token.
4. Additional control-plane nodes join with `type=control-plane`.
5. Worker nodes join with `type=worker`.

The bootstrap scripts are stored in:

- `templates/control-plane-bootstrap.sh.tftpl`
- `templates/control-plane-join.sh.tftpl`
- `templates/worker-join.sh.tftpl`

## Prerequisites

You need:

- Terraform `>= 1.5`
- AWS credentials configured for the target account
- permissions to create VPC, EC2, IAM, ELBv2, EIP, NAT Gateway, and SSM-related resources
- AWS CLI if you want to use Session Manager from your terminal

Optional:

- an existing EC2 key pair if you want SSH available

## Usage

Create a local variables file:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Initialize Terraform:

```bash
terraform init
```

Review the plan:

```bash
terraform plan
```

Apply:

```bash
terraform apply
```

Destroy:

```bash
terraform destroy
```

## Important Variables

Common settings you are likely to change:

| Variable | Purpose | Default |
| --- | --- | --- |
| `aws_region` | AWS region for all resources | `eu-central-1` |
| `project_name` | Name prefix for resources | `vcluster-standalone` |
| `availability_zone_count` | Number of AZs to spread subnets across | `1` |
| `vpc_cidr` | CIDR for the VPC | `10.0.0.0/16` |
| `allowed_public_cidrs` | Public access allowed to the NLB listener | `["0.0.0.0/0"]` |
| `control_plane_count` | Total control-plane node count | `3` |
| `worker_count` | Total worker node count | `2` |
| `control_plane_instance_type` | Control-plane instance type | `t3.large` |
| `worker_instance_type` | Worker instance type | `t3.large` |
| `kubernetes_version` | Kubernetes version for standalone vCluster | `v1.35.0` |
| `vcluster_version` | vCluster release version | `v0.33.1` |
| `vcluster_name` | Cluster name | `vcluster` |
| `control_plane_target_port` | Port on the EC2 control-plane nodes behind the NLB | `8443` |
| `ubuntu_ami_ssm_parameter_name` | Canonical Ubuntu AMI lookup parameter | Ubuntu 22.04 `ebs-gp2` path |
| `ami_id` | Explicit AMI override | `null` |
| `cluster_join_token` | Optional fixed join token | `null` |
| `key_name` | Optional EC2 key pair for SSH | `null` |
| `ssh_allowed_cidrs` | Allowed SSH source ranges | `[]` |

The full variable definitions are in [variables.tf](/Users/fabiankramm/Programmieren/go/src/github.com/loft-sh/terraform-aws-vcluster-standalone/variables.tf).

## Example terraform.tfvars

```hcl
aws_region                  = "eu-central-1"
project_name                = "vcluster-standalone"
availability_zone_count     = 2
vpc_cidr                    = "10.0.0.0/16"
allowed_public_cidrs        = ["0.0.0.0/0"]
control_plane_count         = 3
worker_count                = 2
control_plane_instance_type = "t3.large"
worker_instance_type        = "t3.large"
kubernetes_version          = "v1.35.0"
vcluster_version            = "v0.33.1"
vcluster_name               = "vcluster"
control_plane_target_port   = 8443
```

For a more complete example, see [terraform.tfvars.example](/Users/fabiankramm/Programmieren/go/src/github.com/loft-sh/terraform-aws-vcluster-standalone/terraform.tfvars.example).

## Accessing the Nodes

Nodes are private. The intended access path is AWS Systems Manager Session Manager.

Start a shell session:

```bash
aws ssm start-session --target <instance-id>
```

Start a port-forwarding session:

```bash
aws ssm start-session \
  --target <instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["22"],"localPortNumber":["2222"]}'
```

If you also want SSH:

- set `key_name`
- set `ssh_allowed_cidrs`
- use SSM port forwarding, a bastion, or another private connectivity path

## Useful Outputs

After `terraform apply`, the configuration exposes:

- `cluster_endpoint`
- `load_balancer_dns_name`
- `vpc_id`
- `control_plane_private_ips`
- `worker_private_ips`
- `cluster_join_token` as a sensitive output

You can inspect them with:

```bash
terraform output
```

Sensitive output example:

```bash
terraform output -raw cluster_join_token
```

## Security Notes

- The EC2 instances are private by default.
- Public exposure is limited to the NLB listener on `443`, constrained by `allowed_public_cidrs`.
- Internal node-to-node traffic is allowed within the VPC CIDR.
- Outbound internet access is allowed from the nodes so they can download packages and the standalone installer.
- SSM agent installation is handled in `user_data`.

## Operational Notes

- The NAT gateway is single-instance. This is simpler and cheaper, but it is not highly available across AZ failure scenarios.
- The stack currently uses one shared private route table for all private subnets.
- `user_data_replace_on_change = true` is set on all EC2 instances. If you change the bootstrap scripts or certain instance settings, Terraform may replace nodes.
- The AMI lookup defaults to Canonical's public SSM parameter for Ubuntu 22.04. If that parameter is unavailable in your environment, set `ami_id` directly.
- The cluster join token is auto-generated unless you provide `cluster_join_token`.

## Repository Files

- `versions.tf`: Terraform and provider constraints
- `variables.tf`: input variables
- `main.tf`: networking, IAM, NLB, and EC2 resources
- `outputs.tf`: exported values after apply
- `terraform.tfvars.example`: example configuration
- `templates/`: bootstrap scripts for the different node roles

## Validation

The configuration in this repository is expected to validate with:

```bash
terraform validate
```

It is still your responsibility to run a real `terraform plan` in the target AWS account before apply, because quotas, permissions, AZ availability, and AMI resolution can differ by account and region.
