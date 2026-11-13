output "role_arn" {
  description = "Use with aws-actions/configure-aws-credentials (role-to-assume)."
  value       = aws_iam_role.push.arn
}
