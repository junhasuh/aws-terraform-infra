resource "aws_iam_user" "junha_suh" {
  name = "junha_suh"
}

resource "aws_iam_user_policy" "art_devops_black_jack" {
  name = "super_admin"
  user = aws_iam_user.junha_suh.name
  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "*"
        ],
        "Resource": [
          "*"
        ]
      }
    ]
} 
EOF
}
