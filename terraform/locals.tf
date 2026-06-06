locals {
  bronze_prefix     = "bronze"
  silver_prefix     = "silver"
  gold_prefix       = "gold"
  quarantine_prefix = "quarantine"

  bronze_fhvhv_table_name = "bronze_fhvhv_trips"
  silver_fhvhv_table_name = "silver_fhvhv_trips"

  glue_artifact_source_dir = "${path.module}/../../nash-dataops-pipeline-code/scripts"
  glue_artifact_files = toset([
    "glue_load_data_to_redshift.py",
    "glue_manage_redshift_schema.py",
    "glue_process_raw_data.py",
    "glue_quarantine_failed_data.py",
    "requirements.txt",
  ])
}
