output "workflow_queue" {
  value       = aws_batch_job_queue.workflow.name
  description = "Batch job queue for workflow jobs (tagged so that miniwdl-aws-submit can detect workflow role, task job queue, and EFS access point)"
}

output "fs" {
  value       = aws_efs_file_system.efs.id
  description = "EFS file system ID"
}

output "fsap" {
  value       = aws_efs_access_point.ap.id
  description = "EFS access point ID"
}

output "subnets" {
  value       = aws_subnet.public[*].id
  description = "Public subnet for each availability zone"
}

output "security_group" {
  value       = aws_security_group.all.id
  description = "Security group for compute resources and EFS"
}
