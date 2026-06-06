# Glue Data Catalog for the Bronze and Silver lakehouse layers.
resource "aws_glue_catalog_database" "demo_db" {
  name        = "etl_demo_db_${var.environment}"
  description = "Database for the Nash DataOps lakehouse demo in ${var.environment}"
}

resource "aws_glue_crawler" "bronze_data_crawler" {
  name          = "bronze-data-crawler-${var.environment}"
  role          = aws_iam_role.glue_crawler_role.arn
  database_name = aws_glue_catalog_database.demo_db.name
  table_prefix  = "bronze_"

  s3_target {
    path       = "s3://${aws_s3_bucket.data_bucket.bucket}/${local.bronze_prefix}/fhvhv_trips/"
    exclusions = ["*.csv"]
  }

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "UPDATE_IN_DATABASE"
  }

  configuration = jsonencode({
    Version = 1.0,
    CrawlerOutput = {
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
    }
  })

  tags = {
    Name  = "bronze-data-crawler-${var.environment}"
    Layer = "Bronze"
  }
}

resource "aws_glue_crawler" "silver_data_crawler" {
  name          = "silver-data-crawler-${var.environment}"
  role          = aws_iam_role.glue_crawler_role.arn
  database_name = aws_glue_catalog_database.demo_db.name
  table_prefix  = "silver_"

  s3_target {
    path = "s3://${aws_s3_bucket.data_bucket.bucket}/${local.silver_prefix}/fhvhv_trips/"
  }

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "UPDATE_IN_DATABASE"
  }

  configuration = jsonencode({
    Version = 1.0,
    CrawlerOutput = {
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
    }
  })

  tags = {
    Name  = "silver-data-crawler-${var.environment}"
    Layer = "Silver"
  }
}
