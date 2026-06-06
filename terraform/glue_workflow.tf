# Step Functions orchestration for the full Bronze -> Silver -> Gold pipeline.
resource "aws_cloudwatch_log_group" "data_pipeline_state_machine_logs" {
  name              = "/aws/states/data-pipeline-${var.environment}"
  retention_in_days = 14
}

resource "aws_iam_role" "step_functions_role" {
  name = "data-pipeline-step-functions-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "states.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "step_functions_policy" {
  name = "data-pipeline-step-functions-policy-${var.environment}"
  role = aws_iam_role.step_functions_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "glue:StartCrawler",
          "glue:GetCrawler"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "glue:StartJobRun",
          "glue:GetJobRun",
          "glue:GetJobRuns",
          "glue:BatchStopJobRun",
          "glue:GetDatabase",
          "glue:GetTable",
          "glue:GetTables",
          "glue:StartDataQualityRulesetEvaluationRun",
          "glue:GetDataQualityRulesetEvaluationRun",
          "glue:GetDataQualityResult"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.glue_role.arn
      },
      {
        Effect = "Allow"
        Action = [
          "events:DescribeRule",
          "events:PutRule",
          "events:PutTargets",
          "logs:CreateLogDelivery",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_sfn_state_machine" "data_pipeline_state_machine" {
  name     = "data-pipeline-state-machine-${var.environment}"
  role_arn = aws_iam_role.step_functions_role.arn

  logging_configuration {
    include_execution_data = true
    level                  = "ALL"
    log_destination        = "${aws_cloudwatch_log_group.data_pipeline_state_machine_logs.arn}:*"
  }

  definition = jsonencode({
    Comment = "Nash DataOps Bronze/Silver/Gold pipeline"
    StartAt = "Initialize Run Context"
    States = {
      "Initialize Run Context" = {
        Type = "Pass"
        Parameters = {
          "run_id.$" = "$$.Execution.Name"
        }
        Next = "Start Bronze Crawler"
      }

      "Start Bronze Crawler" = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:glue:startCrawler"
        Parameters = {
          Name = aws_glue_crawler.bronze_data_crawler.name
        }
        ResultPath = "$.BronzeCrawlerStart"
        Next       = "Wait For Bronze Crawler"
        Catch = [
          {
            ErrorEquals = ["Glue.CrawlerRunningException"]
            ResultPath  = "$.BronzeCrawlerAlreadyRunning"
            Next        = "Wait For Bronze Crawler"
          }
        ]
      }

      "Wait For Bronze Crawler" = {
        Type    = "Wait"
        Seconds = 30
        Next    = "Get Bronze Crawler"
      }

      "Get Bronze Crawler" = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:glue:getCrawler"
        Parameters = {
          Name = aws_glue_crawler.bronze_data_crawler.name
        }
        ResultPath = "$.BronzeCrawler"
        Next       = "Bronze Crawler Complete?"
      }

      "Bronze Crawler Complete?" = {
        Type = "Choice"
        Choices = [
          {
            And = [
              {
                Variable  = "$.BronzeCrawler.Crawler.LastCrawl.Status"
                IsPresent = true
              },
              {
                Variable     = "$.BronzeCrawler.Crawler.LastCrawl.Status"
                StringEquals = "FAILED"
              }
            ]
            Next = "Bronze Crawler Failed"
          },
          {
            Variable     = "$.BronzeCrawler.Crawler.State"
            StringEquals = "READY"
            Next         = "Start Bronze Data Quality"
          },
          {
            Variable     = "$.BronzeCrawler.Crawler.State"
            StringEquals = "RUNNING"
            Next         = "Wait For Bronze Crawler"
          }
        ]
        Default = "Wait For Bronze Crawler"
      }

      "Bronze Crawler Failed" = {
        Type  = "Fail"
        Error = "BronzeCrawlerFailed"
        Cause = "The Bronze Glue crawler failed."
      }

      "Start Bronze Data Quality" = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:glue:startDataQualityRulesetEvaluationRun"
        Parameters = {
          DataSource = {
            GlueTable = {
              DatabaseName = aws_glue_catalog_database.demo_db.name
              TableName    = local.bronze_fhvhv_table_name
            }
          }
          Role            = aws_iam_role.glue_role.arn
          NumberOfWorkers = 2
          Timeout         = 60
          RulesetNames    = [aws_glue_data_quality_ruleset.bronze_fhvhv_quality.name]
          AdditionalRunOptions = {
            CloudWatchMetricsEnabled = true
            ResultsS3Prefix          = "s3://${aws_s3_bucket.data_bucket.bucket}/${local.gold_prefix}/data-quality-results/bronze/"
          }
        }
        ResultPath = "$.BronzeDataQualityStart"
        Next       = "Wait For Bronze Data Quality"
      }

      "Wait For Bronze Data Quality" = {
        Type    = "Wait"
        Seconds = 30
        Next    = "Get Bronze Data Quality Evaluation"
      }

      "Get Bronze Data Quality Evaluation" = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:glue:getDataQualityRulesetEvaluationRun"
        Parameters = {
          "RunId.$" = "$.BronzeDataQualityStart.RunId"
        }
        ResultPath = "$.BronzeDataQualityRun"
        Next       = "Bronze Data Quality Evaluation Complete?"
      }

      "Bronze Data Quality Evaluation Complete?" = {
        Type = "Choice"
        Choices = [
          {
            Variable     = "$.BronzeDataQualityRun.Status"
            StringEquals = "SUCCEEDED"
            Next         = "Get Bronze Data Quality Result"
          },
          {
            Variable     = "$.BronzeDataQualityRun.Status"
            StringEquals = "RUNNING"
            Next         = "Wait For Bronze Data Quality"
          },
          {
            Variable     = "$.BronzeDataQualityRun.Status"
            StringEquals = "STARTING"
            Next         = "Wait For Bronze Data Quality"
          },
          {
            Variable     = "$.BronzeDataQualityRun.Status"
            StringEquals = "FAILED"
            Next         = "Bronze Data Quality Evaluation Failed"
          },
          {
            Variable     = "$.BronzeDataQualityRun.Status"
            StringEquals = "TIMEOUT"
            Next         = "Bronze Data Quality Evaluation Failed"
          }
        ]
        Default = "Wait For Bronze Data Quality"
      }

      "Bronze Data Quality Evaluation Failed" = {
        Type  = "Fail"
        Error = "BronzeDataQualityEvaluationFailed"
        Cause = "The Bronze Glue Data Quality evaluation run did not complete successfully."
      }

      "Get Bronze Data Quality Result" = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:glue:getDataQualityResult"
        Parameters = {
          "ResultId.$" = "$.BronzeDataQualityRun.ResultIds[0]"
        }
        ResultPath = "$.BronzeDataQualityResult"
        Next       = "Bronze Quality Score Passed?"
      }

      "Bronze Quality Score Passed?" = {
        Type = "Choice"
        Choices = [
          {
            Variable                 = "$.BronzeDataQualityResult.Score"
            NumericGreaterThanEquals = 1
            Next                     = "Process Bronze To Silver"
          }
        ]
        Default = "Bronze Data Quality Gate Failed"
      }

      "Bronze Data Quality Gate Failed" = {
        Type  = "Fail"
        Error = "BronzeDataQualityScoreBelowThreshold"
        Cause = "Bronze data failed the quality score threshold before Silver transformation."
      }

      "Process Bronze To Silver" = {
        Type     = "Task"
        Resource = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = {
          JobName = aws_glue_job.glue_process_raw_data.name
          Arguments = {
            "--run_id.$" = "$.run_id"
          }
        }
        ResultPath = "$.ProcessSilverJob"
        Next       = "Start Silver Crawler"
      }

      "Start Silver Crawler" = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:glue:startCrawler"
        Parameters = {
          Name = aws_glue_crawler.silver_data_crawler.name
        }
        ResultPath = "$.SilverCrawlerStart"
        Next       = "Wait For Silver Crawler"
        Catch = [
          {
            ErrorEquals = ["Glue.CrawlerRunningException"]
            ResultPath  = "$.SilverCrawlerAlreadyRunning"
            Next        = "Wait For Silver Crawler"
          }
        ]
      }

      "Wait For Silver Crawler" = {
        Type    = "Wait"
        Seconds = 30
        Next    = "Get Silver Crawler"
      }

      "Get Silver Crawler" = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:glue:getCrawler"
        Parameters = {
          Name = aws_glue_crawler.silver_data_crawler.name
        }
        ResultPath = "$.SilverCrawler"
        Next       = "Silver Crawler Complete?"
      }

      "Silver Crawler Complete?" = {
        Type = "Choice"
        Choices = [
          {
            And = [
              {
                Variable  = "$.SilverCrawler.Crawler.LastCrawl.Status"
                IsPresent = true
              },
              {
                Variable     = "$.SilverCrawler.Crawler.LastCrawl.Status"
                StringEquals = "FAILED"
              }
            ]
            Next = "Silver Crawler Failed"
          },
          {
            Variable     = "$.SilverCrawler.Crawler.State"
            StringEquals = "READY"
            Next         = "Start Silver Data Quality"
          },
          {
            Variable     = "$.SilverCrawler.Crawler.State"
            StringEquals = "RUNNING"
            Next         = "Wait For Silver Crawler"
          }
        ]
        Default = "Wait For Silver Crawler"
      }

      "Silver Crawler Failed" = {
        Type  = "Fail"
        Error = "SilverCrawlerFailed"
        Cause = "The Silver Glue crawler failed."
      }

      "Start Silver Data Quality" = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:glue:startDataQualityRulesetEvaluationRun"
        Parameters = {
          DataSource = {
            GlueTable = {
              DatabaseName = aws_glue_catalog_database.demo_db.name
              TableName    = local.silver_fhvhv_table_name
            }
          }
          Role            = aws_iam_role.glue_role.arn
          NumberOfWorkers = 2
          Timeout         = 60
          RulesetNames    = [aws_glue_data_quality_ruleset.silver_fhvhv_quality.name]
          AdditionalRunOptions = {
            CloudWatchMetricsEnabled = true
            ResultsS3Prefix          = "s3://${aws_s3_bucket.data_bucket.bucket}/${local.gold_prefix}/data-quality-results/"
          }
        }
        ResultPath = "$.DataQualityStart"
        Next       = "Wait For Data Quality"
      }

      "Wait For Data Quality" = {
        Type    = "Wait"
        Seconds = 30
        Next    = "Get Data Quality Evaluation"
      }

      "Get Data Quality Evaluation" = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:glue:getDataQualityRulesetEvaluationRun"
        Parameters = {
          "RunId.$" = "$.DataQualityStart.RunId"
        }
        ResultPath = "$.DataQualityRun"
        Next       = "Data Quality Evaluation Complete?"
      }

      "Data Quality Evaluation Complete?" = {
        Type = "Choice"
        Choices = [
          {
            Variable     = "$.DataQualityRun.Status"
            StringEquals = "SUCCEEDED"
            Next         = "Get Data Quality Result"
          },
          {
            Variable     = "$.DataQualityRun.Status"
            StringEquals = "RUNNING"
            Next         = "Wait For Data Quality"
          },
          {
            Variable     = "$.DataQualityRun.Status"
            StringEquals = "STARTING"
            Next         = "Wait For Data Quality"
          },
          {
            Variable     = "$.DataQualityRun.Status"
            StringEquals = "FAILED"
            Next         = "Data Quality Evaluation Failed"
          },
          {
            Variable     = "$.DataQualityRun.Status"
            StringEquals = "TIMEOUT"
            Next         = "Data Quality Evaluation Failed"
          }
        ]
        Default = "Wait For Data Quality"
      }

      "Data Quality Evaluation Failed" = {
        Type  = "Fail"
        Error = "DataQualityEvaluationFailed"
        Cause = "The Glue Data Quality evaluation run did not complete successfully."
      }

      "Get Data Quality Result" = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:glue:getDataQualityResult"
        Parameters = {
          "ResultId.$" = "$.DataQualityRun.ResultIds[0]"
        }
        ResultPath = "$.DataQualityResult"
        Next       = "Quality Score Passed?"
      }

      "Quality Score Passed?" = {
        Type = "Choice"
        Choices = [
          {
            Variable                 = "$.DataQualityResult.Score"
            NumericGreaterThanEquals = 1
            Next                     = "Manage Redshift Star Schema"
          }
        ]
        Default = "Quarantine Failed Silver Batch"
      }

      "Quarantine Failed Silver Batch" = {
        Type     = "Task"
        Resource = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = {
          JobName = aws_glue_job.glue_quarantine_failed_data.name
          Arguments = {
            "--run_id.$"        = "$.run_id"
            "--dq_ruleset_name" = aws_glue_data_quality_ruleset.silver_fhvhv_quality.name
            "--dq_result_id.$"  = "$.DataQualityResult.ResultId"
            "--dq_score.$"      = "States.Format('{}', $.DataQualityResult.Score)"
          }
        }
        ResultPath = "$.QuarantineJob"
        Next       = "Data Quality Gate Failed"
      }

      "Data Quality Gate Failed" = {
        Type  = "Fail"
        Error = "DataQualityScoreBelowThreshold"
        Cause = "Silver data failed the quality score threshold and was quarantined."
      }

      "Manage Redshift Star Schema" = {
        Type     = "Task"
        Resource = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = {
          JobName = aws_glue_job.glue_manage_redshift_schema_job.name
        }
        ResultPath = "$.RedshiftSchemaJob"
        Next       = "Load Gold To Redshift"
      }

      "Load Gold To Redshift" = {
        Type     = "Task"
        Resource = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = {
          JobName = aws_glue_job.glue_load_data_to_redshift_job.name
          Arguments = {
            "--run_id.$" = "$.run_id"
          }
        }
        ResultPath = "$.RedshiftLoadJob"
        Next       = "Pipeline Succeeded"
      }

      "Pipeline Succeeded" = {
        Type = "Succeed"
      }
    }
  })

  tags = {
    Name = "data-pipeline-state-machine-${var.environment}"
  }
}

resource "aws_iam_role" "eventbridge_step_functions_role" {
  name = "eventbridge-step-functions-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "eventbridge_step_functions_policy" {
  name = "eventbridge-step-functions-policy-${var.environment}"
  role = aws_iam_role.eventbridge_step_functions_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "states:StartExecution"
        Resource = aws_sfn_state_machine.data_pipeline_state_machine.arn
      }
    ]
  })
}

resource "aws_cloudwatch_event_rule" "data_pipeline_schedule" {
  name                = "data-pipeline-schedule-${var.environment}"
  description         = "Runs the Nash DataOps lakehouse pipeline on a monthly schedule"
  schedule_expression = var.pipeline_schedule_expression
}

resource "aws_cloudwatch_event_target" "data_pipeline_schedule_target" {
  rule     = aws_cloudwatch_event_rule.data_pipeline_schedule.name
  arn      = aws_sfn_state_machine.data_pipeline_state_machine.arn
  role_arn = aws_iam_role.eventbridge_step_functions_role.arn
}
