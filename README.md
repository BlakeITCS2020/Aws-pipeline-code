# Nash DataOps Pipeline Code

This repository contains AWS Glue job scripts for the NYC FHV lakehouse pipeline.

## Scripts

- `scripts/glue_process_raw_data.py`: Reads Bronze trip data from the Glue Catalog, standardizes columns, enriches with taxi zone metadata, adds time fields and `trip_id`, and appends Silver Parquet partitioned by year, month, and `run_id`.
- `scripts/glue_quarantine_failed_data.py`: Copies a failed Silver batch to `quarantine/fhvhv_trips/run_id=<run_id>/` after the Glue Data Quality gate fails.
- `scripts/glue_manage_redshift_schema.py`: Creates the Redshift analytics model: `dim_zone`, `dim_date`, `fact_fhvhv_trips`, and staging tables.
- `scripts/glue_load_data_to_redshift.py`: Builds Gold Parquet staging files and loads Redshift using `COPY`, then performs idempotent delete/insert upserts.

## Pipeline Contract

The infrastructure repo runs the scripts through Step Functions:

1. Crawl Bronze S3 data.
2. Run `glue_process_raw_data.py`.
3. Crawl Silver Parquet data.
4. Run AWS Glue Data Quality rules against the Silver table.
5. If quality fails, run `glue_quarantine_failed_data.py` and stop.
6. If quality passes, run `glue_manage_redshift_schema.py`.
7. Run `glue_load_data_to_redshift.py`.

## Important Arguments

`glue_process_raw_data.py`:

- `data_bucket_name`
- `database_name`
- `fhvhv_table_name`
- `run_id`

`glue_quarantine_failed_data.py`:

- `data_bucket_name`
- `run_id`
- `dq_ruleset_name`
- `dq_result_id`
- `dq_score`

`glue_manage_redshift_schema.py`:

- `redshift_database`
- `redshift_schema`
- `redshift_table`
- `redshift_host`
- `redshift_username`
- `redshift_password`

`glue_load_data_to_redshift.py`:

- `data_bucket_name`
- `redshift_database`
- `redshift_schema`
- `redshift_table`
- `redshift_host`
- `redshift_username`
- `redshift_password`
- `redshift_iam_role_arn`
- `run_id`

## CI/CD

For the current dev setup, Terraform can still upload everything in `scripts/`
to S3 through `aws_s3_object.glue_artifacts`.

The restored GitHub Actions workflow at `.github/workflows/s3-deploy.yml`
supports automated script deployment for the current Step Functions flow:

- On push to `develop`, `master`, or `main`, it compiles the Glue scripts,
  checks the expected script files exist, and syncs `scripts/` to
  `s3://<DATAOPS_BUCKET>/scripts/`, then starts the Step Functions state
  machine.
- Branches `develop` and other non-prod branches use the GitHub environment
  named `develop`; `master` and `main` use `prod`.
- On manual `workflow_dispatch`, it starts the Step Functions state machine by
  default after uploading scripts. Uncheck `trigger_pipeline` if you only want
  to deploy the scripts.

Required repository or environment secrets:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_REGION`
- `DATAOPS_BUCKET`
- `DATAOPS_STATE_MACHINE_ARN`

The workflow starts the pipeline with `aws stepfunctions start-execution`; it no
longer calls the old Glue Workflow API.
