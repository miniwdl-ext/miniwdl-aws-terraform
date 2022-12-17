/**************************************************************************************************
 * NOTICE: This configuration is an illustrative starting point for customization. For brevity,
 * it does not implement all security best practices in networking and IAM. Customize as needed for
 * your security requirements.
 *************************************************************************************************/

provider "aws" {
  default_tags {
    tags = {
      Owner       = var.owner_tag
      Environment = var.environment_tag
    }
  }
}

provider "cloudinit" {}

data "aws_availability_zones" "available" {}

/**************************************************************************************************
 * Networking
 *************************************************************************************************/

resource "aws_vpc" "vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
}

# For simplicity, one public subnet per availability zone. Private subnet(s) with NAT could work.
resource "aws_subnet" "public" {
  count                   = length(data.aws_availability_zones.available.names)
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = "10.0.${32 * count.index}.0/20"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  route_table_id = aws_route_table.public.id
  subnet_id      = aws_subnet.public[count.index].id
}

# Umbrella security group for Batch compute environments & EFS mount targets, allowing any traffic
# within the VPC and outbound-only Internet access.
# The ingress could be locked down to only allow EFS traffic (TCP 2049) within the VPC.
resource "aws_security_group" "all" {
  name   = var.environment_tag
  vpc_id = aws_vpc.vpc.id
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.vpc.cidr_block]
  }
  # Uncomment to open SSH to task worker instances via EC2 Instance Connect (for troubleshooting)
  /*
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  */
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

/**************************************************************************************************
 * EFS
 *************************************************************************************************/

resource "aws_efs_file_system" "efs" {
  encrypted        = true
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"
  # ^ Larger-scale workloads may need throughput_mode changed to "elastic" (not set by default due
  #   to increased cost). If you're sure you will NOT use "elastic" throughput_mode, then you may
  #   set performance_mode to "maxIO" to get more IOPS (but this must be set at initial filesystem
  #   creation, and isn't compatible with elastic throughput_mode).
  lifecycle_policy {
    transition_to_ia                    = "AFTER_14_DAYS"
    transition_to_primary_storage_class = "AFTER_1_ACCESS"
  }
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_efs_mount_target" "target" {
  count           = length(aws_subnet.public)
  file_system_id  = aws_efs_file_system.efs.id
  subnet_id       = aws_subnet.public[count.index].id
  security_groups = [aws_security_group.all.id]
}

resource "aws_efs_access_point" "ap" {
  file_system_id = aws_efs_file_system.efs.id
  posix_user {
    uid = 0
    gid = 0
  }
}

/**************************************************************************************************
 * Batch
 *************************************************************************************************/

resource "aws_iam_instance_profile" "task" {
  name = "${var.environment_tag}-task"
  role = aws_iam_role.task.name
}

data "cloudinit_config" "task" {
  gzip = false

  # enable EC2 Instance Connect for troubleshooting (if security group allows inbound SSH)
  part {
    content_type = "text/x-shellscript"
    content      = "yum install -y ec2-instance-connect"
  }

  part {
    content_type = "text/x-shellscript"
    content      = file("${path.module}/assets/init_docker_instance_storage.sh")
  }
}

resource "aws_launch_template" "task" {
  name                   = "${var.environment_tag}-task"
  update_default_version = true
  iam_instance_profile {
    name = aws_iam_instance_profile.task.name
  }
  user_data = data.cloudinit_config.task.rendered
}

# SPOT task environment+queue

resource "aws_batch_compute_environment" "task" {
  compute_environment_name_prefix = "${var.environment_tag}-task"
  type                            = "MANAGED"
  service_role                    = aws_iam_role.batch.arn

  compute_resources {
    type                = "SPOT"
    instance_type       = ["m5d", "c5d", "r5d"]
    allocation_strategy = "SPOT_CAPACITY_OPTIMIZED"
    max_vcpus           = var.task_max_vcpus
    subnets             = aws_subnet.public[*].id
    security_group_ids  = [aws_security_group.all.id]
    spot_iam_fleet_role = aws_iam_role.spot_fleet.arn
    instance_role       = aws_iam_instance_profile.task.arn
    # ^ Terraform requires instance_role even though it seems redundant with launch template

    launch_template {
      launch_template_id = aws_launch_template.task.id
      version            = aws_launch_template.task.latest_version
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_batch_job_queue" "task" {
  name                 = "${var.environment_tag}-task"
  state                = "ENABLED"
  priority             = 1
  compute_environments = [aws_batch_compute_environment.task.arn]
}

# EC2 On Demand fallback task environment+queue (for possible use after exhausting spot retries;

resource "aws_batch_compute_environment" "task_fallback" {
  compute_environment_name_prefix = "${var.environment_tag}-task-fallback"
  type                            = "MANAGED"
  service_role                    = aws_iam_role.batch.arn

  compute_resources {
    type                = "EC2"
    instance_type       = ["m5d", "c5d", "r5d"]
    allocation_strategy = "BEST_FIT_PROGRESSIVE"
    max_vcpus           = var.task_max_vcpus
    subnets             = aws_subnet.public[*].id
    security_group_ids  = [aws_security_group.all.id]
    spot_iam_fleet_role = aws_iam_role.spot_fleet.arn
    instance_role       = aws_iam_instance_profile.task.arn
    # ^ Terraform requires instance_role even though it seems redundant with launch template

    launch_template {
      launch_template_id = aws_launch_template.task.id
      version            = aws_launch_template.task.latest_version
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_batch_job_queue" "task_fallback" {
  name                 = "${var.environment_tag}-task-fallback"
  state                = "ENABLED"
  priority             = 1
  compute_environments = [aws_batch_compute_environment.task_fallback.arn]
}

# FARGATE workflow environment+queue

resource "aws_batch_compute_environment" "workflow" {
  compute_environment_name_prefix = "${var.environment_tag}-workflow"
  type                            = "MANAGED"
  service_role                    = aws_iam_role.batch.arn

  compute_resources {
    type               = "FARGATE"
    max_vcpus          = var.workflow_max_vcpus
    subnets            = aws_subnet.public[*].id
    security_group_ids = [aws_security_group.all.id]
    # With Fargate an IAM role is set in the task definition, not as part of the compute
    # environment -- see the workflow role below.
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_batch_job_queue" "workflow" {
  name                 = "${var.environment_tag}-workflow"
  state                = "ENABLED"
  priority             = 1
  compute_environments = [aws_batch_compute_environment.workflow.arn]

  # miniwdl-aws-submit only needs to be given the workflow queue name because it detects other
  # infrastructure defaults from these tags.
  tags = merge({
    WorkflowEngineRoleArn = aws_iam_role.workflow.arn
    DefaultTaskQueue      = aws_batch_job_queue.task.name
    DefaultFsap           = aws_efs_access_point.ap.id
    }, [var.enable_task_fallback ? { DefaultTaskQueueFallback = aws_batch_job_queue.task_fallback.name } : null]...
  )
}

/**************************************************************************************************
 * IAM roles
 *************************************************************************************************/

# For Batch EC2 worker instances running WDL tasks
resource "aws_iam_role" "task" {
  name = "${var.environment_tag}-task"

  assume_role_policy = <<-EOF
  {"Statement":[{"Principal":{"Service":"ec2.amazonaws.com"},"Sid":"","Effect":"Allow","Action":"sts:AssumeRole"}],"Version":"2012-10-17"}
  EOF

  # The following managed policies are convenient to keep this concise, but they're more powerful
  # than strictly needed: scopes can all be restricted to specific resources rather than
  # account-wide.
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role",
    "arn:aws:iam::aws:policy/AmazonElasticFileSystemClientReadWriteAccess",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess",
  ]
}

# For Batch Fargate tasks running miniwdl itself
# This role needs to be set with the Batch job definition, not as part of the compute environment;
# miniwdl-aws-submit detects it from the WorkflowEngineRoleArn tag on the workflow job queue, set
# above.
resource "aws_iam_role" "workflow" {
  name = "${var.environment_tag}-workflow"

  assume_role_policy = <<-EOF
  {"Statement":[{"Principal":{"Service":"ecs-tasks.amazonaws.com"},"Sid":"","Effect":"Allow","Action":"sts:AssumeRole"}],"Version":"2012-10-17"}
  EOF

  # The following managed policies are convenient to keep this concise, but they're more powerful
  # than strictly needed. The scopes can all be restricted to specific resources rather than
  # account-wide; and while certain "write" permissions to Batch and EFS are needed, it's less than
  # "FullAccess".
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy",
    "arn:aws:iam::aws:policy/AmazonElasticFileSystemClientFullAccess",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess",
    "arn:aws:iam::aws:policy/AWSBatchFullAccess",
  ]

  # permissions for --s3upload
  dynamic "inline_policy" {
    for_each = length(var.s3upload_buckets) > 0 ? [true] : []

    content {
      name = "${var.environment_tag}-workflow-s3upload"
      policy = jsonencode({
        Version = "2012-10-17",
        Statement = [{
          Effect   = "Allow",
          Action   = ["s3:PutObject"],
          Resource = formatlist("arn:aws:s3:::%s/*", var.s3upload_buckets),
          },
        ],
      })
    }
  }
}

# Boilerplate roles

resource "aws_iam_role" "batch" {
  name = "${var.environment_tag}-batch"

  assume_role_policy = <<-EOF
  {"Statement":[{"Principal":{"Service":"batch.amazonaws.com"},"Sid":"","Effect":"Allow","Action":"sts:AssumeRole"}],"Version":"2012-10-17"}
  EOF

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole",
  ]
}

resource "aws_iam_role" "spot_fleet" {
  name = "${var.environment_tag}-spot"

  assume_role_policy = <<-EOF
  {"Statement":[{"Principal":{"Service":"spotfleet.amazonaws.com"},"Sid":"","Effect":"Allow","Action":"sts:AssumeRole"}],"Version":"2012-10-17"}
  EOF

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AmazonEC2SpotFleetTaggingRole",
  ]
}

# The following service-linked roles can be created only once per account; trying to create them
# again fails the deploy, in which case set variable create_spot_service_roles = false.
# info: https://github.com/cloudposse/terraform-aws-elasticsearch/issues/5

resource "aws_iam_service_linked_role" "spot" {
  count            = var.create_spot_service_roles ? 1 : 0
  aws_service_name = "spot.amazonaws.com"
}

resource "aws_iam_service_linked_role" "spotfleet" {
  count            = var.create_spot_service_roles ? 1 : 0
  aws_service_name = "spotfleet.amazonaws.com"
}
