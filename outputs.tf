output "cluster_endpoint" {
  description = "Public endpoint for the standalone vCluster control plane."
  value       = "https://${aws_lb.control_plane.dns_name}"
}

output "load_balancer_dns_name" {
  description = "DNS name of the network load balancer."
  value       = aws_lb.control_plane.dns_name
}

output "vpc_id" {
  description = "ID of the created VPC."
  value       = aws_vpc.main.id
}

output "control_plane_private_ips" {
  description = "Private IPs of the control plane nodes."
  value       = concat([aws_instance.control_plane_bootstrap.private_ip], aws_instance.control_plane[*].private_ip)
}

output "worker_private_ips" {
  description = "Private IPs of the worker nodes."
  value       = aws_instance.worker[*].private_ip
}

output "cluster_join_token" {
  description = "Join token used to bootstrap the standalone cluster."
  value       = local.cluster_join_token
  sensitive   = true
}

output "kubeconfig_parameter_name" {
  description = "SSM Parameter Store name containing the exported kubeconfig."
  value       = local.kubeconfig_parameter_name
}

output "kubeconfig_retrieval_command" {
  description = "Command to retrieve the kubeconfig from SSM Parameter Store after apply."
  value       = "aws ssm get-parameter --region ${var.aws_region} --name '${local.kubeconfig_parameter_name}' --with-decryption --query 'Parameter.Value' --output text > kubeconfig.yaml"
}
