# Create Automation For Deleting Terminated Instances in Chef Server with AWS Lambda

provider "aws" {
  region = "${var.region}"
}

# ------------------------------------------------------------------------------
# Define Terraform Configuration
#   region = "us-east-1"
#   bucket = "states" - s3 bucket
#   key = "<module>/terraform.tfstate" - S3 file name for remote state
# ------------------------------------------------------------------------------

terraform {
  required_version = "=0.9.11"
  backend "s3" {
    region = "us-east-1"
    bucket = "states"
    key = "lambda/terraform.tfstate"
    lock_table = "states"

  }
}

# ------------------------------------------------------------------------------
# Required output for network/vpc
# ------------------------------------------------------------------------------

data "terraform_remote_state" "network" {
  backend  = "s3"
  environment = "${terraform.env}"
  config {
    bucket = "${var.state_bucket}"
    key = "network/terraform.tfstate"
    region = "${var.region}"
  }
}

# Lambda Role with Required Policy
resource "aws_iam_role_policy" "lambda_policy" {
    name = "chef_node_cleanup_lambda"
    role = "${aws_iam_role.lambda_role.id}"
    policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents",
                "ec2:DescribeNetworkInterfaces",
                "ec2:CreateNetworkInterface",
                "ec2:DeleteNetworkInterface"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "kms:Decrypt"
            ],
            "Resource": "*"
        }
    ]
}
EOF
}

resource "aws_iam_role" "lambda_role" {
    name = "chef_node_cleanup_lambda"
    assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_kms_key" "lambdachef" {
  description = "KMS key for chef"
  policy =  <<EOF
{
   "Version": "2012-10-17",
  "Id": "key-default-1",
  "Statement": [
    {
      "Sid": "Enable IAM User Permissions",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::670834854537:root"
      },
      "Action": "kms:*",
      "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_kms_alias" "lambdachef" {
  name = "alias/lambdachef"
  target_key_id = "${aws_kms_key.lambdachef.key_id}"

  provisioner "local-exec" {
    command = "aws kms encrypt --key-id  ${aws_kms_key.lambdachef.key_id} --plaintext file://lambda-chef.pem > lambda-chef.json"
  }

  provisioner "local-exec" {
    command = "jq -r .CiphertextBlob lambda-chef.json > lambda-function/encrypted_pem.txt"
  }

  provisioner "local-exec" {
    command = "cd lambda-function; zip -r ../lambda_function_payload.zip *"
  }

}

# Lambda Function
resource "aws_lambda_function" "lambda_function" {
    depends_on = ["aws_kms_alias.lambdachef"]
    filename = "lambda_function_payload.zip"
    function_name = "chef_node_cleanup"
    role = "${aws_iam_role.lambda_role.arn}"
    handler = "main.handle"
    description = "Automatically delete nodes from Chef Server on termination"
    memory_size = 128
    runtime = "python2.7"
    timeout = 5
    #source_code_hash = "${base64encode(sha256(file("lambda_function_payload.zip")))}"
  vpc_config {
    subnet_ids = ["${data.terraform_remote_state.network.private_subnet_ids}"]
    security_group_ids = ["${data.terraform_remote_state.network.private_security_group_ids}"]
  }
}

resource "aws_lambda_permission" "allow_cloudwatch" {
    statement_id = "AllowExecutionFromCloudWatch"
    action = "lambda:InvokeFunction"
    function_name = "${aws_lambda_function.lambda_function.arn}"
    principal = "events.amazonaws.com"
    source_arn = "${aws_cloudwatch_event_rule.instance_termination.arn}"
}

# CloudWatch Event Rule and Event Target
resource "aws_cloudwatch_event_rule" "instance_termination" {
  depends_on = ["aws_iam_role.lambda_role"] # we need the Lambda arn to exist
  name = "Chef_Node_Cleanup_Lambda"
  description = "Trigger the chef_node_cleanup Lambda when an instance terminates"
  event_pattern = <<PATTERN
  {
    "source": [ "aws.ec2" ],
    "detail-type": [ "EC2 Instance State-change Notification" ],
    "detail": {
      "state": [ "terminated" ]
    }
  }
PATTERN
}

resource "aws_cloudwatch_event_target" "lambda" {
  depends_on = ["aws_iam_role.lambda_role"] # we need the Lambda arn to exist
  rule = "${aws_cloudwatch_event_rule.instance_termination.name}"
  target_id = "chef_node_cleanup"
  arn = "${aws_lambda_function.lambda_function.arn}"
}
