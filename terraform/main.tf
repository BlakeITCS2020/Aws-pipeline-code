# Main Terraform configuration file for AWS DataOps ETL Demo
# This file sets up the core infrastructure components
terraform {
  backend "s3" {
    bucket         = "glue-etl-demo-tfstate-ap-southeast-1-dev"
    key            = "aws/dataops/dev/terraform.tfstate"
    region         = "ap-southeast-1"
    dynamodb_table = "glue-etl-demo-tf-locks-dev"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = merge(
      {
        Environment = var.environment
        Project     = "DataOps-ETL-Demo"
        ManagedBy   = "Terraform"
      },
      var.tags
    )
  }
}

#-------------------- VPC Infrastructure --------------------

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "dataops_vpc" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "dataops-demo-vpc-${var.environment}"
  }
}

resource "aws_internet_gateway" "dataops_igw" {
  vpc_id = aws_vpc.dataops_vpc.id

  tags = {
    Name = "dataops-demo-igw-${var.environment}"
  }
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.dataops_vpc.id
  cidr_block              = "10.42.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "dataops-demo-public-a-${var.environment}"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.dataops_vpc.id
  cidr_block              = "10.42.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true

  tags = {
    Name = "dataops-demo-public-b-${var.environment}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.dataops_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.dataops_igw.id
  }

  tags = {
    Name = "dataops-demo-public-rt-${var.environment}"
  }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

#-------------------- S3 Infrastructure --------------------

# Create S3 bucket for data storage
resource "aws_s3_bucket" "data_bucket" {
  bucket = var.data_bucket_name

}

# Configure bucket for server-side encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "data_bucket_encryption" {
  bucket = aws_s3_bucket.data_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Optionally upload bundled sample data. The default is false because demo inputs
# are expected to be uploaded manually before running the pipeline.
resource "aws_s3_object" "fhvhv_tripdata_sample_data" {
  count = var.upload_sample_data ? 1 : 0

  bucket = aws_s3_bucket.data_bucket.id
  key    = "${local.bronze_prefix}/fhvhv_trips/2024/01/fhvhv_tripdata.parquet"
  source = "${path.module}/../data/fhvhv_trips/2024/01/fhvhv_tripdata.parquet"
  etag   = var.upload_sample_data ? filemd5("${path.module}/../data/fhvhv_trips/2024/01/fhvhv_tripdata.parquet") : null
}

resource "aws_s3_object" "fhvhv_tripdata_sample_data_2" {
  count = var.upload_sample_data ? 1 : 0

  bucket = aws_s3_bucket.data_bucket.id
  key    = "${local.bronze_prefix}/fhvhv_trips/2024/02/fhvhv_tripdata.parquet"
  source = "${path.module}/../data/fhvhv_trips/2024/02/fhvhv_tripdata.parquet"
  etag   = var.upload_sample_data ? filemd5("${path.module}/../data/fhvhv_trips/2024/02/fhvhv_tripdata.parquet") : null
}

resource "aws_s3_object" "taxi_zone_lookup_sample_data" {
  count = var.upload_sample_data ? 1 : 0

  bucket = aws_s3_bucket.data_bucket.id
  key    = "${local.bronze_prefix}/reference/taxi_zone_lookup.csv"
  source = "${path.module}/../data/taxi_zone_lookup.csv"
  etag   = var.upload_sample_data ? filemd5("${path.module}/../data/taxi_zone_lookup.csv") : null
}

# Create S3 directories for lakehouse layers and operational outputs
resource "aws_s3_object" "silver_fhvhv_directory" {
  bucket       = aws_s3_bucket.data_bucket.id
  key          = "${local.silver_prefix}/fhvhv_trips/"
  content_type = "application/x-directory"
}

resource "aws_s3_object" "gold_redshift_directory" {
  bucket       = aws_s3_bucket.data_bucket.id
  key          = "${local.gold_prefix}/redshift/"
  content_type = "application/x-directory"
}

resource "aws_s3_object" "quarantine_fhvhv_directory" {
  bucket       = aws_s3_bucket.data_bucket.id
  key          = "${local.quarantine_prefix}/fhvhv_trips/"
  content_type = "application/x-directory"
}

resource "aws_s3_object" "glue_artifacts" {
  for_each = local.glue_artifact_files

  bucket = aws_s3_bucket.data_bucket.id
  key    = "scripts/${each.value}"
  source = "${local.glue_artifact_source_dir}/${each.value}"
  etag   = filemd5("${local.glue_artifact_source_dir}/${each.value}")
}

#-------------------- IAM  --------------------
# Create IAM role for Glue Crawler
resource "aws_iam_role" "glue_crawler_role" {
  name = "glue-crawler-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "glue.amazonaws.com"
        }
      }
    ]
  })
}

# Attach policies to Glue Crawler role
resource "aws_iam_role_policy_attachment" "glue_crawler_service" {
  role       = aws_iam_role.glue_crawler_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_crawler_s3_access" {
  name = "glue-crawler-s3-access-policy-${var.environment}"
  role = aws_iam_role.glue_crawler_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Effect = "Allow"
        Resource = [
          aws_s3_bucket.data_bucket.arn,
          "${aws_s3_bucket.data_bucket.arn}/*"
        ]
      }
    ]
  })
}


# Create IAM role for Glue
resource "aws_iam_role" "glue_role" {
  name = "glue-etl-demo-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = [
            "glue.amazonaws.com",
            "redshift.amazonaws.com"
          ]
        }
      }
    ]
  })
}

# Attach policies to Glue role
resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# Add Redshift access policy for Glue
resource "aws_iam_role_policy" "glue_redshift_access" {
  name = "glue-redshift-access-policy-${var.environment}"
  role = aws_iam_role.glue_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "redshift:*",
          "redshift-data:*"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

# Add S3 access policy for Glue
resource "aws_iam_role_policy" "glue_s3_access" {
  name = "glue-s3-access-policy-${var.environment}"
  role = aws_iam_role.glue_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Effect = "Allow"
        Resource = [
          aws_s3_bucket.data_bucket.arn,
          "${aws_s3_bucket.data_bucket.arn}/*"
        ]
      }
    ]
  })
}

#-------------------- Redshift Infrastructure ----------------------


data "aws_secretsmanager_secret" "redshift" {
  name = var.redshift_secret_name
}

data "aws_secretsmanager_secret_version" "redshift" {
  secret_id = data.aws_secretsmanager_secret.redshift.id
}

locals {
  redshift_secret = jsondecode(
    data.aws_secretsmanager_secret_version.redshift.secret_string
  )
}


# Create security group for Redshift access
resource "aws_security_group" "redshift_security_group" {
  name        = "redshift-sg-${var.environment}"
  description = "Security group for Redshift access"
  vpc_id      = aws_vpc.dataops_vpc.id

  ingress {
    from_port   = 5439
    to_port     = 5439
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_redshift_subnet_group" "dataops_redshift_subnet_group" {
  name       = "dataops-redshift-subnet-group-${var.environment}"
  subnet_ids = [aws_subnet.public_a.id, aws_subnet.public_b.id]

  tags = {
    Name = "dataops-redshift-subnet-group-${var.environment}"
  }
}

resource "aws_redshift_cluster" "dataops_redshift" {
  cluster_identifier        = "dataops-demo-cluster-${var.environment}"
  node_type                 = var.redshift_node_type
  number_of_nodes           = 1
  master_username           = local.redshift_secret.username
  master_password           = local.redshift_secret.password
  iam_roles                 = [aws_iam_role.glue_role.arn]
  cluster_type              = "single-node"
  encrypted                 = true
  publicly_accessible       = true
  cluster_subnet_group_name = aws_redshift_subnet_group.dataops_redshift_subnet_group.name
  vpc_security_group_ids    = [aws_security_group.redshift_security_group.id]

  tags = {
    Name = "dataops-demo-redshift"
  }
}
