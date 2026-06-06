import logging
import re
import sys

import psycopg2
from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql.functions import (
    col,
    current_timestamp,
    date_format,
    dayofmonth,
    dayofweek,
    lit,
    month,
    year,
)


logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger(__name__)


def require_identifier(value, name):
    if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", value):
        raise ValueError(f"{name} must be a simple SQL identifier, got: {value}")
    return value


def canonicalize_zone_columns(df):
    for original_name in df.columns:
        normalized = re.sub(r"[^0-9a-zA-Z]+", "_", original_name).strip("_").lower()
        df = df.withColumnRenamed(original_name, normalized)
    return df


def copy_parquet(cursor, table_name, s3_path, iam_role_arn):
    copy_sql = f"""
    COPY {table_name}
    FROM '{s3_path}'
    IAM_ROLE '{iam_role_arn}'
    FORMAT AS PARQUET;
    """
    logger.info("Running Redshift COPY into %s from %s", table_name, s3_path)
    cursor.execute(copy_sql)


def main():
    args = getResolvedOptions(
        sys.argv,
        [
            "JOB_NAME",
            "data_bucket_name",
            "redshift_database",
            "redshift_schema",
            "redshift_table",
            "redshift_host",
            "redshift_username",
            "redshift_password",
            "redshift_iam_role_arn",
            "run_id",
        ],
    )

    sc = SparkContext()
    glueContext = GlueContext(sc)
    spark = glueContext.spark_session
    job = Job(glueContext)
    job.init(args["JOB_NAME"], args)

    data_bucket = args["data_bucket_name"]
    run_id = args["run_id"]
    schema_name = require_identifier(args["redshift_schema"], "redshift_schema")
    fact_table = require_identifier(args["redshift_table"], "redshift_table")
    staging_fact_table = require_identifier(f"staging_{fact_table}", "staging_fact_table")

    silver_path = f"s3://{data_bucket}/silver/fhvhv_trips/"
    zone_lookup_path = f"s3://{data_bucket}/bronze/reference/taxi_zone_lookup.csv"
    gold_base_path = f"s3://{data_bucket}/gold/redshift/run_id={run_id}"

    logger.info("Reading Silver Parquet data from %s", silver_path)
    silver_df = spark.read.parquet(silver_path)
    if run_id != "manual":
        silver_df = silver_df.filter(col("run_id") == run_id)

    record_count = silver_df.count()
    logger.info("Preparing %s Silver records for Redshift run_id=%s", record_count, run_id)
    if record_count == 0:
        logger.info("No Silver records found for this run; skipping Redshift COPY.")
        job.commit()
        return

    fact_df = silver_df.select(
        col("trip_id").cast("string").alias("trip_id"),
        col("dispatching_base_num").cast("string").alias("dispatching_base_num"),
        col("affiliated_base_number").cast("string").alias("affiliated_base_number"),
        col("pickup_datetime").cast("timestamp").alias("pickup_datetime"),
        col("dropoff_datetime").cast("timestamp").alias("dropoff_datetime"),
        col("pickup_date").cast("date").alias("pickup_date"),
        col("pickup_date_key").cast("int").alias("pickup_date_key"),
        col("pickup_hour").cast("short").alias("pickup_hour"),
        col("pu_location_id").cast("int").alias("pu_location_id"),
        col("do_location_id").cast("int").alias("do_location_id"),
        col("sr_flag").cast("int").alias("sr_flag"),
        col("trip_duration_minutes").cast("double").alias("trip_duration_minutes"),
        col("source_file").cast("string").alias("source_file"),
        col("run_id").cast("string").alias("source_run_id"),
        col("load_timestamp").cast("timestamp").alias("load_timestamp"),
    )

    dim_date_df = (
        fact_df.select(col("pickup_date"), col("pickup_date_key"))
        .where(col("pickup_date").isNotNull() & col("pickup_date_key").isNotNull())
        .dropDuplicates(["pickup_date_key"])
        .select(
            col("pickup_date_key").cast("int").alias("date_key"),
            col("pickup_date").cast("date").alias("full_date"),
            year(col("pickup_date")).cast("short").alias("year"),
            month(col("pickup_date")).cast("short").alias("month"),
            dayofmonth(col("pickup_date")).cast("short").alias("day"),
            dayofweek(col("pickup_date")).cast("short").alias("day_of_week"),
            date_format(col("pickup_date"), "EEEE").alias("day_name"),
            date_format(col("pickup_date"), "MMMM").alias("month_name"),
            current_timestamp().alias("load_timestamp"),
        )
    )

    zones_df = canonicalize_zone_columns(spark.read.option("header", "true").csv(zone_lookup_path))
    dim_zone_df = (
        zones_df.select(
            col("locationid").cast("int").alias("location_id"),
            col("borough").cast("string").alias("borough"),
            col("zone").cast("string").alias("zone"),
            col("service_zone").cast("string").alias("service_zone"),
            current_timestamp().alias("load_timestamp"),
        )
        .where(col("location_id").isNotNull())
        .dropDuplicates(["location_id"])
    )

    fact_stage_path = f"{gold_base_path}/fact_fhvhv_trips/"
    dim_date_stage_path = f"{gold_base_path}/dim_date/"
    dim_zone_stage_path = f"{gold_base_path}/dim_zone/"

    logger.info("Writing Gold Redshift staging Parquet files under %s", gold_base_path)
    fact_df.write.mode("overwrite").parquet(fact_stage_path)
    dim_date_df.write.mode("overwrite").parquet(dim_date_stage_path)
    dim_zone_df.write.mode("overwrite").parquet(dim_zone_stage_path)

    endpoint_parts = args["redshift_host"].split(":")
    host = endpoint_parts[0]
    port = int(endpoint_parts[1]) if len(endpoint_parts) > 1 else 5439

    conn = None
    try:
        conn = psycopg2.connect(
            host=host,
            port=port,
            dbname=args["redshift_database"],
            user=args["redshift_username"],
            password=args["redshift_password"],
        )
        conn.autocommit = False

        with conn.cursor() as cursor:
            cursor.execute(f"TRUNCATE TABLE {schema_name}.staging_dim_zone;")
            cursor.execute(f"TRUNCATE TABLE {schema_name}.staging_dim_date;")
            cursor.execute(f"TRUNCATE TABLE {schema_name}.{staging_fact_table};")

            copy_parquet(
                cursor,
                f"{schema_name}.staging_dim_zone",
                dim_zone_stage_path,
                args["redshift_iam_role_arn"],
            )
            copy_parquet(
                cursor,
                f"{schema_name}.staging_dim_date",
                dim_date_stage_path,
                args["redshift_iam_role_arn"],
            )
            copy_parquet(
                cursor,
                f"{schema_name}.{staging_fact_table}",
                fact_stage_path,
                args["redshift_iam_role_arn"],
            )

            cursor.execute(
                f"""
                DELETE FROM {schema_name}.dim_zone
                USING {schema_name}.staging_dim_zone
                WHERE dim_zone.location_id = staging_dim_zone.location_id;
                """
            )
            cursor.execute(f"INSERT INTO {schema_name}.dim_zone SELECT * FROM {schema_name}.staging_dim_zone;")

            cursor.execute(
                f"""
                DELETE FROM {schema_name}.dim_date
                USING {schema_name}.staging_dim_date
                WHERE dim_date.date_key = staging_dim_date.date_key;
                """
            )
            cursor.execute(f"INSERT INTO {schema_name}.dim_date SELECT * FROM {schema_name}.staging_dim_date;")

            cursor.execute(
                f"""
                DELETE FROM {schema_name}.{fact_table}
                USING {schema_name}.{staging_fact_table}
                WHERE {fact_table}.trip_id = {staging_fact_table}.trip_id;
                """
            )
            cursor.execute(
                f"INSERT INTO {schema_name}.{fact_table} SELECT * FROM {schema_name}.{staging_fact_table};"
            )

        conn.commit()
        logger.info("Loaded %s records into %s.%s with COPY-based upsert.", record_count, schema_name, fact_table)
    except Exception:
        if conn:
            conn.rollback()
        raise
    finally:
        if conn:
            conn.close()
        job.commit()


if __name__ == "__main__":
    main()
