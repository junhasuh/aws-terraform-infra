terraform { 
    backend "s3" { 
      bucket         = "tf101-junhajunha-apne2-tfstate" 
      key            = "terraform101/iam/terraform.tfstate" 
      region         = "ap-northeast-2"
      encrypt        = true
      dynamodb_table = "terraform-lock"
    }
}
