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

# For simplicity: one public subnet in the desired availability zone. A private subnet with NAT
# would work too.
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = "10.0.0.0/20"
  availability_zone       = var.availability_zone
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
  route_table_id = aws_route_table.public.id
  subnet_id      = aws_subnet.public.id
}

# Umbrella security group for Batch compute environments & filesystem mount targets, allowing any
# traffic within the VPC and outbound-only Internet access.
# The ingress could be locked down to allow only FSxL traffic within the VPC,
# https://docs.aws.amazon.com/fsx/latest/LustreGuide/limit-access-security-groups.html#fsx-vpc-security-groups
resource "aws_security_group" "all" {
  name   = var.environment_tag
  vpc_id = aws_vpc.vpc.id
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.vpc.cidr_block]
  }
  # Uncomment to open SSH access via EC2 Instance Connect (for troubleshooting)
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
 * FSxL
 *************************************************************************************************/

resource "aws_fsx_lustre_file_system" "lustre" {
  subnet_ids                    = [aws_subnet.public.id]
  security_group_ids            = [aws_security_group.all.id]
  deployment_type               = "SCRATCH_2"
  storage_capacity              = var.lustre_GiB
  weekly_maintenance_start_time = var.lustre_weekly_maintenance_start_time

  lifecycle {
    prevent_destroy = true
  }
}

/**************************************************************************************************
 * Batch
 *************************************************************************************************/

data "cloudinit_config" "all" {
  # user data scripts for Batch worker instances
  gzip = false

  part {
    content_type = "text/x-shellscript"
    content      = file("${path.module}/../assets/init_docker_instance_storage.sh")
  }

  part {
    content_type = "text/x-shellscript"
    content      = <<-EOT
    #!/bin/bash
    set -euxo pipefail
    # enable EC2 Instance Connect for troubleshooting (if security group allows inbound SSH)
    yum install -y ec2-instance-connect && grep eic_run_authorized_keys /etc/ssh/sshd_config
    # mount FSxL to /mnt/net
    amazon-linux-extras install -y lustre2.10
    mkdir -p /mnt/net
    mount -t lustre -o noatime,flock ${aws_fsx_lustre_file_system.lustre.dns_name}@tcp:/${aws_fsx_lustre_file_system.lustre.mount_name} /mnt/net
    lfs setstripe -E 1G -c 1 -E 16G -c 4 -S 16M -E -1 -c -1 -S 256M /mnt/net
    df -h
    # Somehow the preceding steps nondeterministically interfere with ECS agent startup. Set a cron
    # job to keep trying to start it. (We can't simply `systemctl start ecs` here, because the ecs
    # systemd service requires cloud-init to have finished.)
    echo "* * * * * root /usr/bin/systemctl start ecs" > /etc/cron.d/ecs-workaround
    /usr/bin/systemctl reload crond
    EOT
  }
}

resource "aws_iam_instance_profile" "task" {
  name = "${var.environment_tag}-task"
  role = aws_iam_role.task.name
}

resource "aws_launch_template" "task" {
  name                   = "${var.environment_tag}-task"
  update_default_version = true
  iam_instance_profile {
    name = aws_iam_instance_profile.task.name
  }
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type = "gp3"
      volume_size = 40
      # ^ Large docker images may need more root EBS volume space on worker instances
    }
  }
  user_data = data.cloudinit_config.all.rendered
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
    subnets             = [aws_subnet.public.id]
    security_group_ids  = [aws_security_group.all.id]
    spot_iam_fleet_role = aws_iam_role.spot_fleet.arn
    instance_role       = aws_iam_instance_profile.task.arn

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

# EC2 On Demand fallback task environment+queue (for possible use after exhausting spot retries)

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

# EC2 On Demand workflow environment+queue

resource "aws_iam_instance_profile" "workflow" {
  name = "${var.environment_tag}-workflow"
  role = aws_iam_role.workflow.name
}

resource "aws_launch_template" "workflow" {
  name                   = "${var.environment_tag}-workflow"
  update_default_version = true
  iam_instance_profile {
    name = aws_iam_instance_profile.workflow.name
  }
  user_data = data.cloudinit_config.all.rendered
}

resource "aws_batch_compute_environment" "workflow" {
  compute_environment_name_prefix = "${var.environment_tag}-workflow"
  type                            = "MANAGED"
  service_role                    = aws_iam_role.batch.arn

  compute_resources {
    type                = "EC2"
    instance_type       = ["m5.large"]
    allocation_strategy = "BEST_FIT_PROGRESSIVE"
    max_vcpus           = var.workflow_max_vcpus
    subnets             = [aws_subnet.public.id]
    security_group_ids  = [aws_security_group.all.id]
    instance_role       = aws_iam_instance_profile.workflow.arn

    launch_template {
      launch_template_id = aws_launch_template.workflow.id
      version            = aws_launch_template.workflow.latest_version
    }
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
    DefaultTaskQueue = aws_batch_job_queue.task.name
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
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess",
  ]
}

# For Batch EC2 worker instances running miniwdl itself
resource "aws_iam_role" "workflow" {
  name = "${var.environment_tag}-workflow"

  assume_role_policy = <<-EOF
  {"Statement":[{"Principal":{"Service":"ec2.amazonaws.com"},"Sid":"","Effect":"Allow","Action":"sts:AssumeRole"}],"Version":"2012-10-17"}
  EOF

  # The following managed policies are convenient to keep this concise, but they're more powerful
  # than strictly needed. The scopes can all be restricted to specific resources rather than
  # account-wide; and while certain "write" permissions to Batch are needed, it's less than
  # "FullAccess".
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role",
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
        Statement = [
          {
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
