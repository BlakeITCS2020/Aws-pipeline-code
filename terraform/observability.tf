# Metric-only operational dashboard for the data pipeline.
locals {
  data_pipeline_glue_metric_jobs = [
    {
      name  = aws_glue_job.glue_process_raw_data.name
      label = "Bronze to Silver"
    },
    {
      name  = aws_glue_job.glue_manage_redshift_schema_job.name
      label = "Manage Redshift Schema"
    },
    {
      name  = aws_glue_job.glue_load_data_to_redshift_job.name
      label = "Load Gold to Redshift"
    },
    {
      name  = aws_glue_job.glue_quarantine_failed_data.name
      label = "Quarantine Failed Data"
    }
  ]

  data_pipeline_quality_rulesets = [
    {
      id    = "bronze_dq"
      name  = aws_glue_data_quality_ruleset.bronze_fhvhv_quality.name
      label = "Bronze"
    },
    {
      id    = "silver_dq"
      name  = aws_glue_data_quality_ruleset.silver_fhvhv_quality.name
      label = "Silver"
    }
  ]

  cloudwatch_observability_dashboard_url = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.data_pipeline_observability.dashboard_name}"
}

resource "aws_cloudwatch_dashboard" "data_pipeline_observability" {
  dashboard_name = "data-pipeline-observability-${var.environment}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = "# Nash DataOps pipeline observability\nMetric-only dashboard for Step Functions orchestration, Glue job runtime/progress, and Glue Data Quality rule outcomes."
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 2
        width  = 12
        height = 6
        properties = {
          title   = "Pipeline executions"
          view    = "timeSeries"
          region  = var.region
          period  = 300
          stacked = false
          metrics = [
            ["AWS/States", "ExecutionsStarted", "StateMachineArn", aws_sfn_state_machine.data_pipeline_state_machine.arn, { stat = "Sum", label = "Started" }],
            ["AWS/States", "ExecutionsSucceeded", "StateMachineArn", aws_sfn_state_machine.data_pipeline_state_machine.arn, { stat = "Sum", label = "Succeeded" }],
            ["AWS/States", "ExecutionsFailed", "StateMachineArn", aws_sfn_state_machine.data_pipeline_state_machine.arn, { stat = "Sum", label = "Failed" }],
            ["AWS/States", "ExecutionsTimedOut", "StateMachineArn", aws_sfn_state_machine.data_pipeline_state_machine.arn, { stat = "Sum", label = "Timed out" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 2
        width  = 12
        height = 6
        properties = {
          title   = "Pipeline execution time"
          view    = "timeSeries"
          region  = var.region
          period  = 300
          stacked = false
          metrics = [
            ["AWS/States", "ExecutionTime", "StateMachineArn", aws_sfn_state_machine.data_pipeline_state_machine.arn, { stat = "Average", label = "Average duration" }],
            [".", ".", ".", ".", { stat = "Maximum", label = "Maximum duration" }]
          ]
          yAxis = {
            left = {
              label     = "Milliseconds"
              showUnits = false
            }
          }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 8
        width  = 12
        height = 6
        properties = {
          title   = "Glue ETL elapsed time by job"
          view    = "timeSeries"
          region  = var.region
          period  = 300
          stacked = false
          metrics = [
            for job in local.data_pipeline_glue_metric_jobs :
            ["Glue", "glue.driver.aggregate.elapsedTime", "JobName", job.name, "JobRunId", "ALL", "Type", "count", { stat = "Sum", label = job.label }]
          ]
          yAxis = {
            left = {
              label     = "Milliseconds"
              showUnits = false
            }
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 8
        width  = 12
        height = 6
        properties = {
          title   = "Glue completed tasks by job"
          view    = "timeSeries"
          region  = var.region
          period  = 300
          stacked = false
          metrics = [
            for job in local.data_pipeline_glue_metric_jobs :
            ["Glue", "glue.driver.aggregate.numCompletedTasks", "JobName", job.name, "JobRunId", "ALL", "Type", "count", { stat = "Sum", label = job.label }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 14
        width  = 12
        height = 6
        properties = {
          title   = "Glue bytes read by job"
          view    = "timeSeries"
          region  = var.region
          period  = 300
          stacked = false
          metrics = [
            for job in local.data_pipeline_glue_metric_jobs :
            ["Glue", "glue.driver.aggregate.bytesRead", "JobName", job.name, "JobRunId", "ALL", "Type", "count", { stat = "Sum", label = job.label }]
          ]
          yAxis = {
            left = {
              label     = "Bytes"
              showUnits = false
            }
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 14
        width  = 12
        height = 6
        properties = {
          title   = "Data quality rule outcomes"
          view    = "timeSeries"
          region  = var.region
          period  = 300
          stacked = false
          metrics = [
            for metric in flatten([
              for ruleset in local.data_pipeline_quality_rulesets : [
                { expression = "SEARCH('{\"Glue Data Quality\",Ruleset,Table,Database,CatalogId} MetricName=\"glue.data.quality.rules.passed\" Ruleset=\"${ruleset.name}\"', 'Sum', 300)", id = "${ruleset.id}_passed", label = "${ruleset.label} passed rules", region = var.region },
                { expression = "SEARCH('{\"Glue Data Quality\",Ruleset,Table,Database,CatalogId} MetricName=\"glue.data.quality.rules.failed\" Ruleset=\"${ruleset.name}\"', 'Sum', 300)", id = "${ruleset.id}_failed", label = "${ruleset.label} failed rules", region = var.region }
              ]
            ]) : [metric]
          ]
        }
      }
    ]
  })
}
