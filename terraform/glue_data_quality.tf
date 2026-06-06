resource "aws_glue_data_quality_ruleset" "bronze_fhvhv_quality" {
  name        = "bronze-fhvhv-quality-${var.environment}"
  description = "Quality gate for Bronze NYC FHV trip data before Silver transformation"

  ruleset = <<-DQDL
  Rules = [
    RowCount > 0,
    IsComplete "pickup_datetime",
    IsComplete "dropoff_datetime"
  ]
  DQDL

  target_table {
    database_name = aws_glue_catalog_database.demo_db.name
    table_name    = local.bronze_fhvhv_table_name
  }

  tags = {
    Name  = "bronze-fhvhv-quality-${var.environment}"
    Layer = "Bronze"
  }
}

resource "aws_glue_data_quality_ruleset" "silver_fhvhv_quality" {
  name        = "silver-fhvhv-quality-${var.environment}"
  description = "Quality gate for Silver NYC FHV trip data before Redshift loading"

  ruleset = <<-DQDL
  Rules = [
    RowCount > 0,
    IsComplete "trip_id",
    IsComplete "pickup_datetime",
    IsComplete "dropoff_datetime",
    IsComplete "pickup_date",
    IsComplete "trip_duration_minutes",
    Completeness "pu_location_id" > 0.15,
    Completeness "do_location_id" > 0.80,
    Completeness "pu_borough" > 0.15,
    Completeness "do_borough" > 0.80,
    ColumnValues "trip_duration_minutes" between 0 and 1440
  ]
  DQDL

  target_table {
    database_name = aws_glue_catalog_database.demo_db.name
    table_name    = local.silver_fhvhv_table_name
  }

  tags = {
    Name  = "silver-fhvhv-quality-${var.environment}"
    Layer = "Silver"
  }
}
