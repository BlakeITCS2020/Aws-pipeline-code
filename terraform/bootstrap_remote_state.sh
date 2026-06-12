#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-southeast-1}"
STATE_BUCKET="${STATE_BUCKET:-glue-etl-demo-tfstate-ap-southeast-1-dev}"
LOCK_TABLE="${LOCK_TABLE:-glue-etl-demo-tf-locks-dev}"

account_id="$(aws sts get-caller-identity --query Account --output text)"
echo "Using AWS account: $account_id"

if aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1; then
  echo "Terraform state bucket already exists: $STATE_BUCKET"
else
  echo "Creating Terraform state bucket: $STATE_BUCKET"
  aws s3api create-bucket \
    --bucket "$STATE_BUCKET" \
    --region "$AWS_REGION" \
    --create-bucket-configuration "LocationConstraint=$AWS_REGION"
fi

aws s3api put-bucket-versioning \
  --bucket "$STATE_BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$STATE_BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block \
  --bucket "$STATE_BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

if AWS_REGION="$AWS_REGION" aws dynamodb describe-table --table-name "$LOCK_TABLE" >/dev/null 2>&1; then
  echo "Terraform lock table already exists: $LOCK_TABLE"
else
  echo "Creating Terraform lock table: $LOCK_TABLE"
  AWS_REGION="$AWS_REGION" aws dynamodb create-table \
    --table-name "$LOCK_TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST

  AWS_REGION="$AWS_REGION" aws dynamodb wait table-exists \
    --table-name "$LOCK_TABLE"
fi

echo "Remote state backend is ready."
