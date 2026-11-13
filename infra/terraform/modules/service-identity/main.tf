# One IAM role per Kubernetes service account, bound with EKS Pod Identity.
# Each service gets only the AWS actions it uses on the resources it uses;
# there are no node-wide credentials.

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  for_each           = var.services
  name               = "${var.name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "this" {
  for_each = { for k, v in var.services : k => v if length(v.statements) > 0 }
  name     = "access"
  role     = aws_iam_role.this[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [for s in each.value.statements : {
      Effect   = "Allow"
      Action   = s.actions
      Resource = s.resources
    }]
  })
}

resource "aws_eks_pod_identity_association" "this" {
  for_each        = var.services
  cluster_name    = var.cluster_name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.this[each.key].arn
  tags            = var.tags
}
