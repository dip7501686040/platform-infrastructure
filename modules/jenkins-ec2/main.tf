data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "tls_private_key" "jenkins" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "jenkins" {
  key_name   = "jenkins-ec2"
  public_key = tls_private_key.jenkins.public_key_openssh
}

resource "local_sensitive_file" "jenkins_ssh_key" {
  content         = tls_private_key.jenkins.private_key_pem
  filename        = "${path.root}/envs/state/jenkins-ec2.pem"
  file_permission = "0600"
}

# Generated so the instance never needs the interactive setup wizard or a
# fetch-from-instance initialAdminPassword dance — admin/<this> works the
# moment Jenkins is up.
resource "random_password" "jenkins_admin" {
  length  = 24
  special = false
}

resource "local_sensitive_file" "jenkins_admin_password" {
  content         = random_password.jenkins_admin.result
  filename        = "${path.root}/envs/state/jenkins-admin-password.txt"
  file_permission = "0600"
}

resource "aws_security_group" "jenkins" {
  name        = "jenkins-ec2"
  description = "Jenkins CI instance: SSH + web UI from admin_cidr only"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "Jenkins UI"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_iam_role" "jenkins" {
  name = "jenkins-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

# Push/pull to all ai-notification/* ECR repos via IMDS-vended instance
# credentials — no static AWS keys anywhere in the Jenkins pipeline. A
# custom least-privilege policy rather than the AWS-managed
# AmazonEC2ContainerRegistryPowerUser policy, which isn't in Floci's
# seeded managed-policy set (only a handful of common ones are — e.g. the
# EKS module's node role policies worked, this one didn't).
resource "aws_iam_role_policy" "jenkins_ecr" {
  name = "jenkins-ecr-push-pull"
  role = aws_iam_role.jenkins.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeRepositories",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "jenkins-ec2-profile"
  role = aws_iam_role.jenkins.name

  # Floci's IAM emulation doesn't implement TagInstanceProfile — ignore
  # tags_all drift here rather than fail every apply over a cosmetic tag.
  lifecycle {
    ignore_changes = [tags_all]
  }
}

resource "aws_instance" "jenkins" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.jenkins.id]
  iam_instance_profile        = aws_iam_instance_profile.jenkins.name
  key_name                    = aws_key_pair.jenkins.key_name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/templates/bootstrap.sh.tftpl", {
    admin_password = random_password.jenkins_admin.result
    init_security_groovy = templatefile("${path.module}/templates/init-security.groovy.tftpl", {
      admin_password       = random_password.jenkins_admin.result
      github_push_username = var.github_push_username
      github_push_token    = var.github_push_token
    })
    seed_jobs_groovy = templatefile("${path.module}/templates/seed-jobs.groovy.tftpl", {
      git_repo_url         = var.git_repo_url
      git_branch           = var.git_branch
      services_groovy_list = join(", ", [for s in var.service_names : "\"${s}\""])
    })
  })

  tags = merge(var.tags, { Name = "jenkins-ec2" })

  # Floci's EC2 emulation doesn't faithfully track several networking
  # identity attributes on refresh — it reports back generic placeholders
  # ("subnet-default-c", "sg-default") and associate_public_ip_address as
  # false regardless of the real config (Floci reachability comes from
  # Docker port publishing — see docker_container.floci's sibling
  # containers — not a real ENI/public IP/subnet). subnet_id is normally
  # ForceNew, so left unignored this forces a replace on every single
  # plan. Same category of drift as the IAM instance profile's tags_all
  # above.
  lifecycle {
    ignore_changes = [associate_public_ip_address, subnet_id, vpc_security_group_ids]
  }
}
