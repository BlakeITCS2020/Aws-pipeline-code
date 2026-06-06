#!/usr/bin/env bash
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-cloud-user}"
AWS_REGION="${AWS_REGION:-us-west-1}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-630952739663}"
STATE_BUCKET="${STATE_BUCKET:-nash-dataops-tfstate-630952739663-us-west-1-dev}"
LOCK_TABLE="${LOCK_TABLE:-nash-dataops-tf-locks-dev}"

account_id="$(AWS_PROFILE="$AWS_PROFILE" aws sts get-caller-identity --query Account --output text)"
if [[ "$account_id" != "$EXPECTED_ACCOUNT_ID" ]]; then
  echo "Expected AWS account $EXPECTED_ACCOUNT_ID, got $account_id" >&2
  exit 1
fi

if AWS_PROFILE="$AWS_PROFILE" aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1; then
  echo "Terraform state bucket already exists: $STATE_BUCKET"
else
  echo "Creating Terraform state bucket: $STATE_BUCKET"
  AWS_PROFILE="$AWS_PROFILE" aws s3api create-bucket \
    --bucket "$STATE_BUCKET" \
    --region "$AWS_REGION" \
    --create-bucket-configuration "LocationConstraint=$AWS_REGION"
fi

AWS_PROFILE="$AWS_PROFILE" aws s3api put-bucket-versioning \
  --bucket "$STATE_BUCKET" \
  --versioning-configuration Status=Enabled

AWS_PROFILE="$AWS_PROFILE" aws s3api put-bucket-encryption \
  --bucket "$STATE_BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

AWS_PROFILE="$AWS_PROFILE" aws s3api put-public-access-block \
  --bucket "$STATE_BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

if AWS_PROFILE="$AWS_PROFILE" AWS_REGION="$AWS_REGION" aws dynamodb describe-table --table-name "$LOCK_TABLE" >/dev/null 2>&1; then
  echo "Terraform lock table already exists: $LOCK_TABLE"
else
  echo "Creating Terraform lock table: $LOCK_TABLE"
  AWS_PROFILE="$AWS_PROFILE" AWS_REGION="$AWS_REGION" aws dynamodb create-table \
    --table-name "$LOCK_TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST

  AWS_PROFILE="$AWS_PROFILE" AWS_REGION="$AWS_REGION" aws dynamodb wait table-exists \
    --table-name "$LOCK_TABLE"
fi

echo "Remote state backend is ready."
