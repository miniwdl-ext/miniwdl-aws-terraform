# miniwdl-aws-terraform/fsx

This variant of the [miniwdl-aws-terraform](https://github.com/miniwdl-ext/miniwdl-aws-terraform) configuration deploys [FSx for Lustre](https://aws.amazon.com/fsx/lustre/) (FSxL) instead of [EFS](https://aws.amazon.com/efs/). FSxL has greater upfront costs than EFS, but offers higher throughput scalability needed for large-scale operations.

Compared to the default EFS stack, the key differences here are:

1. FSxL and Batch compute environments are confined to one availability zone
2. Compute environment for workflow jobs (running miniwdl itself) uses EC2 instead of Fargate
3. Workflow and task compute environments have an additional cloud-init script that mounts FSxL

### Deploy

```
git clone https://github.com/miniwdl-ext/miniwdl-aws-terraform.git
cd miniwdl-aws-terraform/fsx
terraform apply \
    -var='availability_zone=us-west-2a' \
    -var='environment_tag=miniwdl-fsx' \
    -var='owner_tag=me@example.com' \
    -var='s3upload_buckets=["MY-BUCKET"]'
```

The following *additional* [variables](variables.tf) are available:

* **lustre_GiB** filesystem capacity; set to 1200 or a multiple of 2400 (default 1200)
* **lustre_weekly_maintenance_start_time** see [FSxL docs on WeeklyMaintenanceStartTime](https://docs.aws.amazon.com/fsx/latest/APIReference/API_UpdateFileSystemLustreConfiguration.html)

### Next steps

As with EFS, you'll need a way to browse & manage the remote FSx contents. FSx has fewer integrations with other AWS services like Fargate & Lambda to facilitate this. One additional option:

1. Open the security group for inbound SSH
2. Increase the workflow compute environment minvCpus, so that an instance will run persistently
3. Use [EC2 Instance Connect](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-connect-methods.html#connect-options) to SSH into the instance and interact with `/mnt/fsx`
