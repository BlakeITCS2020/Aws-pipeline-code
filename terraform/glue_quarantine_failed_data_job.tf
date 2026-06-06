# Glue job used by the Step Functions failure branch to quarantine a failed Silver batch.
resource "aws_glue_job" "glue_quarantine_failed_data" {
  name              = "glue-quarantine-failed-data-${var.environment}"
  role_arn          = aws_iam_role.glue_role.arn
  glue_version      = "5.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  timeout           = 30

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.data_bucket.bucket}/scripts/glue_quarantine_failed_data.py"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--TempDir"                          = "s3://${aws_s3_bucket.data_bucket.bucket}/temp/"
    "--job-bookmark-option"              = "job-bookmark-disable"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-spark-ui"                  = "true"
    "--spark-event-logs-path"            = "s3://${aws_s3_bucket.data_bucket.bucket}/spark-logs/"
    "--data_bucket_name"                 = aws_s3_bucket.data_bucket.bucket
    "--run_id"                           = "manual"
    "--dq_ruleset_name"                  = aws_glue_data_quality_ruleset.silver_fhvhv_quality.name
    "--dq_result_id"                     = "manual"
    "--dq_score"                         = "0"
    "--enable-job-insights"              = "true"
    "--enable-glue-datacatalog"          = "true"
    "--enable-metrics"                   = "true"
  }

  execution_property {
    max_concurrent_runs = 1
  }

  tags = {
    Name  = "glue-quarantine-failed-data-${var.environment}"
    Layer = "Quarantine"
  }

  depends_on = [aws_s3_object.glue_artifacts]
}

resource "aws_cloudwatch_log_group" "glue_quarantine_failed_data_job_logs" {
  name              = "/aws-glue/jobs/glue-quarantine-failed-data-${var.environment}"
  retention_in_days = 14
}
