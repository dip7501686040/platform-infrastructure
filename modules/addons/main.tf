locals {
  # oidc_provider_url is null when enable_irsa_addons is false (see modules/eks) —
  # avoid replace() on null even though nothing below references this in that case.
  oidc_provider = var.enable_irsa_addons ? replace(var.oidc_provider_url, "https://", "") : ""
}

# ---------------------------------------------------------------------------
# EBS CSI driver — required for the in-cluster Postgres/RabbitMQ/Redis
# StatefulSets (k8s) to get persistent volumes via the gp3 StorageClass.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ebs_csi_assume" {
  count = var.enable_irsa_addons ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  count = var.enable_irsa_addons ? 1 : 0

  name               = "${var.cluster_name}-ebs-csi-driver"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume[0].json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  count = var.enable_irsa_addons ? 1 : 0

  role       = aws_iam_role.ebs_csi[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  count = var.enable_irsa_addons ? 1 : 0

  cluster_name             = var.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi[0].arn

  tags = var.tags
}

# ---------------------------------------------------------------------------
# AWS Load Balancer Controller — IAM role only. The controller itself is
# installed via Helm (k8s), not Terraform, once the cluster exists;
# this just provisions the IRSA role its service account assumes.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "lb_controller_assume" {
  count = var.enable_irsa_addons ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "lb_controller" {
  count = var.enable_irsa_addons ? 1 : 0

  name               = "${var.cluster_name}-aws-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.lb_controller_assume[0].json

  tags = var.tags
}

# Official policy from kubernetes-sigs/aws-load-balancer-controller
# (docs/install/iam_policy.json) — grants exactly what the controller needs
# to manage ALBs/NLBs on behalf of Ingress/Service resources.
resource "aws_iam_role_policy" "lb_controller" {
  count = var.enable_irsa_addons ? 1 : 0

  name   = "${var.cluster_name}-aws-load-balancer-controller-policy"
  role   = aws_iam_role.lb_controller[0].id
  policy = file("${path.module}/policies/aws-load-balancer-controller-policy.json")
}
