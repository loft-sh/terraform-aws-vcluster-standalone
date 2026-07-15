# terraform-aws-vcluster-standalone

Terraform to create a standalone `vCluster` on AWS EC2 with:

- a dedicated VPC
- one public Network Load Balancer
- private control-plane nodes
- private worker nodes (x86_64 and optional arm64)
- SSM access to the instances

## Quickstart

1. Create a `terraform.tfvars` with sensible defaults:

```bash
cat > terraform.tfvars <<'EOF'
aws_region                  = "eu-central-1"
control_plane_count         = 3
worker_count                = 2
control_plane_instance_type = "t3.large"
worker_instance_type        = "t3.large"
kubernetes_version          = "v1.35.6"
vcluster_version            = "v0.35.1"
EOF
```
2. Deploy:

```bash
terraform init
terraform plan
terraform apply
```

3. Retrieve the kubeconfig from Parameter Store using the command Terraform prints after `apply`:

```bash
eval "$(terraform output -raw kubeconfig_retrieval_command)"
```

> If you get "ParameterNotFound" errors, it might take a couple of minutes until the kubeconfig is uploaded

4. Use the kubeconfig:

```bash
KUBECONFIG=./kubeconfig.yaml kubectl get nodes
```

## What Gets Created

- one VPC
- public subnets for the load balancer and NAT gateway
- private subnets for control-plane nodes
- private subnets for worker nodes
- one internet gateway
- one NAT gateway
- one public Network Load Balancer
- one bootstrap control-plane node
- additional control-plane nodes
- worker nodes (x86_64)
- optional arm64 worker nodes
- one EC2 IAM role with `AmazonSSMManagedInstanceCore`
- one advanced `SecureString` parameter containing the kubeconfig

## How It Works

- The NLB listens on `443`.
- The control-plane nodes are registered behind the NLB on port `8443`.
- The first control-plane node bootstraps the standalone cluster.
- The bootstrap control-plane node publishes `/var/lib/vcluster/kubeconfig.yaml` to AWS Systems Manager Parameter Store as an advanced `SecureString`.
- The other control-plane and worker nodes join through the same NLB endpoint.
- All EC2 instances are private and use the NAT gateway for outbound internet access.
- Access to the nodes is intended through AWS Systems Manager Session Manager.

## Accessing the Nodes

Start an SSM shell session:

```bash
aws ssm start-session --target <instance-id>
```

If you want to find instance IDs by tag:

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=vcluster-*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,InstanceId:InstanceId,PrivateIp:PrivateIpAddress}' \
  --output table
```

## Important Variables

The most relevant variables are:

| Variable | Default | Notes |
| --- | --- | --- |
| `aws_region` | `eu-central-1` | AWS region |
| `project_name` | `vcluster` | Prefix for resource names |
| `availability_zone_count` | `1` | Number of AZs used for subnet creation |
| `vpc_cidr` | `10.0.0.0/16` | CIDR block for the VPC |
| `allowed_public_cidrs` | `["0.0.0.0/0"]` | CIDRs allowed to reach the public NLB |
| `control_plane_count` | `1` | Total control-plane nodes including bootstrap node |
| `worker_count` | `3` | x86_64 worker node count |
| `arm_worker_count` | `0` | arm64 worker node count |
| `control_plane_instance_type` | `t3.large` | Control-plane EC2 size |
| `worker_instance_type` | `t3.large` | x86_64 worker EC2 size |
| `arm_worker_instance_type` | `a1.metal` | arm64 worker EC2 size |
| `control_plane_root_volume_size_gb` | `50` | Control-plane root EBS volume size |
| `worker_root_volume_size_gb` | `100` | Worker root EBS volume size |
| `kubernetes_version` | `v1.35.6` | Kubernetes version passed to vCluster |
| `vcluster_version` | `v0.35.1` | vCluster standalone version |
| `vcluster_name` | `vcluster` | Name of the standalone cluster |
| `control_plane_target_port` | `8443` | Port exposed on the control-plane instances |
| `kubeconfig_parameter_name` | `null` | Defaults to `/<project_name>/kubeconfig`; advanced `SecureString` used for kubeconfig retrieval |
| `ami_id` | `null` | Optional x86_64 AMI override |
| `arm_ami_id` | `null` | Optional arm64 AMI override |
| `key_name` | `null` | Optional SSH key pair |
| `ssh_allowed_cidrs` | `[]` | Optional SSH ingress ranges |

See [terraform.tfvars.example](/Users/fabiankramm/Programmieren/go/src/github.com/loft-sh/terraform-aws-vcluster-standalone/terraform.tfvars.example) and [variables.tf](/Users/fabiankramm/Programmieren/go/src/github.com/loft-sh/terraform-aws-vcluster-standalone/variables.tf) for the full set.

## Outputs

Useful outputs after apply:

- `cluster_endpoint`
- `load_balancer_dns_name`
- `vpc_id`
- `control_plane_private_ips`
- `worker_private_ips`
- `arm_worker_private_ips`
- `cluster_join_token`
- `kubeconfig_parameter_name`
- `kubeconfig_retrieval_command`

List them with:

```bash
terraform output
```

## Notes

- Instances do not get public IPs.
- SSH is optional, but SSM is the intended access path.
- The AMI defaults to Canonical Ubuntu 24.04 via public SSM parameter lookup, with separate lookups for x86_64 (`worker_count`) and arm64 (`arm_worker_count`) workers.
- arm64 workers are disabled by default (`arm_worker_count = 0`) and join the same cluster as the x86_64 workers; they are tagged `Arch = arm64`.
- The bootstrap scripts ensure SSM Agent is present and running.
- The kubeconfig is published by the bootstrap control-plane node into Parameter Store as an advanced `SecureString`.
- The NAT gateway is single-instance, so this is not a highly available network design across AZ failure.
- `user_data_replace_on_change = true` is enabled on the EC2 instances, so bootstrap-related changes can trigger replacement.

## Cleanup

```bash
terraform destroy
```
