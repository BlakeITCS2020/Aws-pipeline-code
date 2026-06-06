# AWS Glue and Redshift configuration for loading Gold data into the warehouse.

# Create Glue connection to Redshift
resource "aws_glue_connection" "redshift_connection" {
  name        = "redshift-connection-${var.environment}"
  description = "Connection to Redshift cluster for data loading"

  connection_properties = {
    JDBC_CONNECTION_URL = "jdbc:redshift://${aws_redshift_cluster.dataops_redshift.endpoint}/${var.redshift_database}"
    USERNAME            = var.redshift_username
    PASSWORD            = var.redshift_password
  }

  physical_connection_requirements {
    availability_zone      = aws_subnet.public_a.availability_zone
    security_group_id_list = [aws_security_group.redshift_security_group.id]
    subnet_id              = aws_subnet.public_a.id
  }

  depends_on = [aws_redshift_cluster.dataops_redshift]
}

# Upload job script to S3 at the first time for easier demo purpose and then it was managed by another repository
# resource "aws_s3_object" "glue_manage_redshift_schema_script" {
#   bucket  = aws_s3_bucket.data_bucket.id
#   key     = "scripts/glue_manage_redshift_schema.py"
#   content = file("${path.module}/helper/glue_manage_redshift_schema.py")
#   etag    = filemd5("${path.module}/helper/glue_manage_redshift_schema.py")
# }

# Upload glue load data to redshift job script to S3 at the first time for easier demo purpose and then it was managed by another repository
# resource "aws_s3_object" "glue_load_data_to_redshift_script" {
#   bucket  = aws_s3_bucket.data_bucket.id
#   key     = "scripts/glue_load_data_to_redshift.py"
#   content = file("${path.module}/helper/glue_load_data_to_redshift.py")
#   etag    = filemd5("${path.module}/helper/glue_load_data_to_redshift.py")
# }

# Create schema from catalog Glue Job
resource "aws_glue_job" "glue_manage_redshift_schema_job" {
  name              = "glue-manage-redshift-star-schema-${var.environment}"
  role_arn          = aws_iam_role.glue_role.arn
  glue_version      = "5.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  timeout           = 60

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.data_bucket.bucket}/scripts/glue_manage_redshift_schema.py"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--TempDir"                          = "s3://${aws_s3_bucket.data_bucket.bucket}/temp/"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-spark-ui"                  = "true"
    "--spark-event-logs-path"            = "s3://${aws_s3_bucket.data_bucket.bucket}/spark-logs/"
    "--redshift_database"                = var.redshift_database
    "--redshift_schema"                  = var.redshift_schema
    "--redshift_table"                   = var.redshift_table
    "--redshift_host"                    = aws_redshift_cluster.dataops_redshift.endpoint
    "--redshift_username"                = var.redshift_username
    "--redshift_password"                = var.redshift_password
    "--enable-job-insights"              = "true"
    "--enable-glue-datacatalog"          = "true"
    "--enable-metrics"                   = "true"
    "--additional-python-modules"        = "psycopg2-binary==2.9.9"
  }

  execution_property {
    max_concurrent_runs = 1
  }

  # connections = [aws_glue_connection.redshift_connection.name]

  tags = {
    Name  = "glue-manage-redshift-star-schema-${var.environment}"
    Layer = "Gold"
  }

  depends_on = [aws_s3_object.glue_artifacts]
}

# Create Redshift load Glue Job
resource "aws_glue_job" "glue_load_data_to_redshift_job" {
  name              = "glue-load-gold-to-redshift-${var.environment}"
  role_arn          = aws_iam_role.glue_role.arn
  glue_version      = "5.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  timeout           = 60

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.data_bucket.bucket}/scripts/glue_load_data_to_redshift.py"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--TempDir"                          = "s3://${aws_s3_bucket.data_bucket.bucket}/temp/"
    "--job-bookmark-option"              = "job-bookmark-enable"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-spark-ui"                  = "true"
    "--spark-event-logs-path"            = "s3://${aws_s3_bucket.data_bucket.bucket}/spark-logs/"
    "--data_bucket_name"                 = aws_s3_bucket.data_bucket.bucket
    "--redshift_host"                    = aws_redshift_cluster.dataops_redshift.endpoint
    "--redshift_username"                = var.redshift_username
    "--redshift_password"                = var.redshift_password
    "--redshift_database"                = var.redshift_database
    "--redshift_schema"                  = var.redshift_schema
    "--redshift_table"                   = var.redshift_table
    "--redshift_iam_role_arn"            = aws_iam_role.glue_role.arn
    "--run_id"                           = "manual"
    "--enable-job-insights"              = "true"
    "--enable-glue-datacatalog"          = "true"
    "--enable-metrics"                   = "true"
    "--additional-python-modules"        = "psycopg2-binary==2.9.9"
  }

  execution_property {
    max_concurrent_runs = 1
  }

  # connections = [aws_glue_connection.redshift_connection.name]

  tags = {
    Name  = "glue-load-gold-to-redshift-${var.environment}"
    Layer = "Gold"
  }

  depends_on = [aws_s3_object.glue_artifacts]
}
