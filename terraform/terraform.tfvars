region             = "ap-southeast-1"
data_bucket_name   = "glue-etl-demo-data-bucket-dev"
environment        = "dev"
upload_sample_data = false


redshift_username  = local.redshift_secret.username
redshift_password  = local.redshift_secret.password

redshift_node_type = "rg.4xlarge"
redshift_database  = "dev"
redshift_schema    = "nyc_taxi"
redshift_table     = "fact_fhvhv_trips"

pipeline_schedule_expression = "cron(0 0 3 * ? *)"

tags = {
  Owner      = "DataOps-Team"
  Project    = "ETL-Demo"
  CostCenter = "DataEngineering"
}
