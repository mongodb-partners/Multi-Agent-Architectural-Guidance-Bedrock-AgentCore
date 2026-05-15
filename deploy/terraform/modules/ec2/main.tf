locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# =============================================================================
# AMI — Latest Amazon Linux 2023 (x86_64)
# =============================================================================

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# =============================================================================
# IAM — Instance role with all permissions the app needs
# =============================================================================

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.project_name}-ec2-role-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-ec2-role-${var.environment}"
  })
}

resource "aws_iam_role_policy" "ec2_app" {
  name = "MultiAgentAppPermissions"
  role = aws_iam_role.ec2.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "BedrockInvoke"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = "*"
      },
      {
        Sid      = "BedrockKBRetrieve"
        Effect   = "Allow"
        Action   = ["bedrock-agent-runtime:Retrieve"]
        Resource = "*"
      },
      {
        Sid      = "SageMakerInvoke"
        Effect   = "Allow"
        Action   = ["sagemaker:InvokeEndpoint"]
        Resource = "*"
      },
      {
        Sid      = "SecretsManagerRead"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = "*"
      },
      {
        Sid      = "S3Read"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
        ]
        Resource = "*"
      },
      {
        Sid    = "ECRPull"
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:GetAuthorizationToken",
        ]
        Resource = "*"
      },
      {
        Sid    = "AgentCoreMemoryAndGateway"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:CreateMemory",
          "bedrock-agentcore:GetMemory",
          "bedrock-agentcore:DeleteMemory",
          "bedrock-agentcore:CreateEvent",
          "bedrock-agentcore:GetEvent",
          "bedrock-agentcore:ListEvents",
          "bedrock-agentcore:ListSessions",
          "bedrock-agentcore:InvokeGateway",
          "bedrock-agentcore:GetGateway",
          "bedrock-agentcore:InvokeAgentRuntime",
        ]
        Resource = "*"
      }
    ]
  })
}

# SSM Session Manager — lets you shell into the instance without an SSH key pair
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_name}-ec2-profile-${var.environment}"
  role = aws_iam_role.ec2.name
}

# =============================================================================
# Security Group — API :3000, UI :8501, SSH :22
# =============================================================================

resource "aws_security_group" "ec2" {
  name        = "${var.project_name}-sg-ec2-${var.environment}"
  description = "POC EC2 - Hono API :3000, Streamlit :8501. SSM for shell (no SSH)."
  vpc_id      = var.vpc_id

  # Port 22 (SSH) intentionally omitted — use SSM Session Manager instead:
  #   aws ssm start-session --target <instance-id>
  # If you need SSH, set ec2_key_pair_name and uncomment an ingress rule.

  ingress {
    description = "Hono/Bun API"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Streamlit UI"
    from_port   = 8501
    to_port     = 8501
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound (AWS APIs + Atlas)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-sg-ec2-${var.environment}"
  })
}

# =============================================================================
# EC2 Instance — runs API (Hono/Bun :3000) and UI (Streamlit :8501) directly
# =============================================================================

resource "aws_instance" "app" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = var.public_subnet_id
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  key_name                    = var.key_pair_name != "" ? var.key_pair_name : null
  associate_public_ip_address = true

  # Use user_data_base64 (not user_data) when the value is already base64-
  # encoded. Putting an encoded value in `user_data` causes Terraform to store
  # the cleartext in state but recompute the encoded value on every plan,
  # which makes user_data appear "different" on each run and forces the
  # instance to be replaced — even when nothing in the script actually changed.
  user_data_base64 = base64encode(templatefile("${path.module}/user_data.sh", {
    project_name     = var.project_name
    aws_region       = var.aws_region
    ecr_registry     = var.ecr_registry
    ecr_api_image    = var.ecr_api_image
    ecr_ui_image     = var.ecr_ui_image
    cw_log_group_api = var.cw_log_group_api
    cw_log_group_ui  = var.cw_log_group_ui
  }))
  user_data_replace_on_change = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30 # GB — minimum required by AL2023 AMI snapshot
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-poc-${var.environment}"
  })
}

# =============================================================================
# Elastic IP — fixed public IP that survives instance stop/start
# =============================================================================

resource "aws_eip" "app" {
  domain   = "vpc"
  instance = aws_instance.app.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-eip-${var.environment}"
  })

  depends_on = [aws_instance.app]
}
