# Every service under services/ needs its repository declared here. This is
# the only place ECR repos are created: bootstrap.sh and `make build` used to
# `aws ecr create-repository` on a miss, which left repos outside Terraform
# state that `make down` never destroyed (and that made the next apply fail
# with RepositoryAlreadyExistsException). They now run
# scripts/check-ecr-repos.sh, which fails if a service has no entry here.
#
# force_delete: destroy has to succeed while the repos still hold images,
# otherwise `make down` stops halfway with RepositoryNotEmptyException.
resource "aws_ecr_repository" "wallet_service" {
  name                 = "wallet-service"
  image_tag_mutability = "MUTABLE"

  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "order_service" {
  name                 = "order-service"
  image_tag_mutability = "MUTABLE"

  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "frontend" {
  name                 = "frontend"
  image_tag_mutability = "MUTABLE"

  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}
