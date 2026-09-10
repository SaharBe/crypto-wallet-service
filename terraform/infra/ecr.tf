resource "aws_ecr_repository" "wallet_service" {
  name                 = "wallet-service"
  image_tag_mutability = "MUTABLE"

  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "order_service" {
  name                 = "order-service"
  image_tag_mutability = "MUTABLE"

  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "frontend" {
  name                 = "frontend"
  image_tag_mutability = "MUTABLE"

  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}