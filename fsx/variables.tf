variable "owner_tag" {
  description = "Owner tag applied to all resources, e.g. your username/email"
}

variable "environment_tag" {
  description = "Environment tag applied to all resources, and used in some resource names"
  default     = "miniwdl-fsx"
}

variable "availability_zone" {
  description = "Availability zone for filesystem and Batch compute"
}

variable "lustre_GiB" {
  description = "Lustre filesystem capacity in GiB (1200 or a multiple of 2400)"
  default     = 1200
}

variable "lustre_weekly_maintenance_start_time" {
  description = "weekly UTC start time of FSX for Lustre 30-minute maintenance windows (%u:%H:%M)"
  default     = "1:00:00"
}

variable "s3upload_buckets" {
  description = "S3 bucket name(s) for automatic upload of workflow outputs with `miniwdl-aws-submit --s3upload`"
  type        = list(string)
  default     = []
}

variable "create_spot_service_roles" {
  description = "Create account-wide spot service roles (once per account)"
  type        = bool
  default     = false
}

variable "task_max_vcpus" {
  description = "Maximum vCPUs for task compute environment"
  type        = number
  default     = 256
}

variable "workflow_max_vcpus" {
  description = "Maximum vCPUs for workflow compute environment"
  type        = number
  default     = 16
}

variable "enable_task_fallback" {
  description = "Enable fallback to EC2 On Demand compute environment after a task experiences runtime.preemptible spot interruptions"
  type        = bool
  default     = false
}
