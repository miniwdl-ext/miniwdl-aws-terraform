output "workflow_queue" {
  value       = aws_batch_job_queue.workflow.name
  description = "Batch job queue for workflow jobs (tagged so that miniwdl-aws-submit can detect task job queue)"
}

output "fs" {
  value       = aws_fsx_lustre_file_system.lustre.id
  description = "FSx for Lustre file system ID"
}

output "subnet" {
  value       = aws_subnet.public.id
  description = "Public subnet"
}

output "security_group" {
  value       = aws_security_group.all.id
  description = "Security group for filesystem and compute resources"
}
