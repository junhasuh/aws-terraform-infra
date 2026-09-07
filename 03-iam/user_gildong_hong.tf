resource "aws_iam_user" "gildonghong" {
  name = "gildong.hong"
}

resource "aws_iam_user_policy" "art_devops_black" {
  name = "super_admin"
  user = aws_iam_user.gildonghong.name
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
