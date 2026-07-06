output "bucket_name" {
  description = "S3 bucket holding remote state. Copy into ../infra/backend.hcl and ../vault-config/backend.hcl as `bucket`."
  value       = aws_s3_bucket.state.id
}

output "dynamodb_table_name" {
  description = "DynamoDB table used for state locking. Copy into backend.hcl as `dynamodb_table`."
  value       = aws_dynamodb_table.lock.name
}
