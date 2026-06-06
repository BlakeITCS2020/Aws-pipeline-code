output "data_bucket_name" {
  description = "S3 bucket used for Bronze, Silver, Gold, quarantine, scripts, and logs"
  value       = aws_s3_bucket.data_bucket.bucket
}

output "step_functions_state_machine_arn" {
  description = "ARN for the Step Functions data pipeline entry point"
  value       = aws_sfn_state_machine.data_pipeline_state_machine.arn
}

output "bronze_data_quality_ruleset_name" {
  description = "Glue Data Quality ruleset used as the Bronze-to-Silver input gate"
  value       = aws_glue_data_quality_ruleset.bronze_fhvhv_quality.name
}

output "silver_data_quality_ruleset_name" {
  description = "Glue Data Quality ruleset used as the Silver-to-Gold gate"
  value       = aws_glue_data_quality_ruleset.silver_fhvhv_quality.name
}

output "redshift_fact_table" {
  description = "Primary Redshift fact table loaded by the pipeline"
  value       = "${var.redshift_schema}.${var.redshift_table}"
}

output "redshift_cluster_identifier" {
  description = "Provisioned Redshift cluster identifier"
  value       = aws_redshift_cluster.dataops_redshift.cluster_identifier
}

output "redshift_host" {
  description = "Public Redshift host for local BI tools"
  value       = split(":", aws_redshift_cluster.dataops_redshift.endpoint)[0]
}

output "redshift_port" {
  description = "Public Redshift port for local BI tools"
  value       = aws_redshift_cluster.dataops_redshift.port
}

output "redshift_database" {
  description = "Redshift database name"
  value       = var.redshift_database
}

output "redshift_schema" {
  description = "Redshift schema containing the presentation model"
  value       = var.redshift_schema
}

output "cloudwatch_observability_dashboard_url" {
  description = "AWS Console URL for the metric-only CloudWatch observability dashboard"
  value       = local.cloudwatch_observability_dashboard_url
}
