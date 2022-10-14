# miniwdl-aws-terraform

Use this [Terraform](https://www.terraform.io) configuration as a starting point to provision AWS infrastructure for [miniwdl-aws](https://github.com/miniwdl-ext/miniwdl-aws) -- including a VPC, EFS file system, Batch queues, and IAM roles.

**Before diving into this, please review simpler ways to use miniwdl-aws** described [there](https://github.com/miniwdl-ext/miniwdl-aws).

### Requirements

* AWS account with administrator/poweruser access
* git, terraform
* terminal session with [AWS CLI configured](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-quickstart.html) (credentials and default region)
* miniwdl-aws (`pip3 install miniwdl-aws`)

### Deploy

```
git clone https://github.com/miniwdl-ext/miniwdl-aws-terraform.git
cd miniwdl-aws-terraform
terraform init
terraform apply \
    -var='environment_tag=miniwdl' \
    -var='owner_tag=me@example.com' \
    -var='s3upload_buckets=["MY-BUCKET"]'
```

where

* `environment_tag` fills the Environment tag of each resource, and prefixes some resource names (for identification & deconfliction)
* `owner_tag` fills the Owner tag of each resource (typically your username/email)
* `s3upload_buckets` is a list of S3 bucket names where you may ask miniwdl-aws to upload workflow outputs (optional)

If you get an error about service roles already existing, add `-var=create_spot_service_roles=false` (these roles need to be created only once per account).

### Self-test

The deployment outputs the name of the Batch job queue for submitting workflows, `miniwdl-workflow` (`${environment_tag}-workflow`), which you can supply to the miniwdl-aws self-test:

```
miniwdl-aws-submit --self-test --follow --workflow-queue miniwdl-workflow
```

Or, set the environment variable `MINIWDL__AWS__WORKFLOW_QUEUE=miniwdl-workflow` instead of the `--workflow-queue` command-line option.

See [miniwdl-aws](https://github.com/miniwdl-ext/miniwdl-aws) for how to use `miniwdl-aws-submit` further.

### Next steps

The following Terraform variables are also available:

* `task_max_vpcus=256` maximum vCPUs for the Batch compute environment used for WDL task execution
* `workflow_max_vcpus=16` maximum vCPUs for the Batch compute environment used for miniwdl engine processes (limits maximum # of workflows running concurrently)
* `enable_task_fallback=true` enable fallback to EC2 On Demand compute environment after a task experiences `runtime.preemptible` spot interruptions (the on-demand environment & queue are always created, but not used by default)

Review the network configuration and IAM policies in [main.tf](main.tf). To keep the configuration succinct, we wrote in simple networking with public subnets, and existing IAM policies that are more powerful than strictly needed. Customize as needed for your security requirements.

You'll need a way to browse & manage the remote EFS contents. The companion [lambdash-efs](https://github.com/miniwdl-ext/lambdash-efs) is one option; the Terrafom deployment outputs the infrastructure details needed to deploy it (pick any subnet). Or, set up an instance/container mounting the EFS, to access via SSH or web app (e.g. [JupyterHub](https://jupyter.org/hub), [Cloud Commander](http://cloudcmd.io/), [VS Code server](https://github.com/cdr/code-server)).

### Using [FSx for Lustre](https://aws.amazon.com/fsx/lustre/) instead of [EFS](https://aws.amazon.com/efs/)

See [fsx/](fsx/) for a variant of the infrastructure configuration deploying Lustre instead of EFS. The default EFS stack is recommended to begin with, but large-scale operations may need the higher throughput offered by Lustre.
