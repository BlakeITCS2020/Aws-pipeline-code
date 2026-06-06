variable "region" {
  description = "AWS region to deploy resources"
  default     = "us-west-1"
  type        = string
}

variable "data_bucket_name" {
  description = "S3 bucket name for storing data and scripts"
  type        = string
}

variable "upload_sample_data" {
  description = "Whether Terraform should upload the bundled sample trip and taxi zone files. Keep false when data is uploaded manually."
  type        = bool
  default     = false
}

variable "environment" {
  description = "Environment tag (e.g., dev, staging, prod)"
  default     = "dev"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

# Redshift credentials
variable "redshift_username" {
  description = "Redshift master username"
  type        = string
}

variable "redshift_password" {
  description = "Redshift master password"
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.redshift_password) >= 8
    error_message = "Redshift password must be at least 8 characters long."
  }
}

# Redshift configuration
variable "redshift_database" {
  description = "Redshift database name"
  type        = string
  default     = "dev"
}

variable "redshift_schema" {
  description = "Redshift schema name for taxi data"
  type        = string
  default     = "nyc_taxi"
}

variable "redshift_table" {
  description = "Redshift fact table name for FHVHV trip data"
  type        = string
  default     = "fact_fhvhv_trips"
}

variable "redshift_node_type" {
  description = "Provisioned Redshift node type for the public demo cluster"
  type        = string
  default     = "ra3.large"
}

variable "pipeline_schedule_expression" {
  description = "EventBridge schedule expression for running the Step Functions data pipeline"
  type        = string
  default     = "cron(0 0 3 * ? *)"
}

# Adding common tags variable for consistent resource tagging
variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
