import re
import sys

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql.functions import (
    col,
    concat_ws,
    current_timestamp,
    date_format,
    dayofmonth,
    hour,
    input_file_name,
    lit,
    month,
    regexp_replace,
    sha2,
    to_date,
    to_timestamp,
    unix_timestamp,
    year,
)


def canonical_name(name):
    normalized = re.sub(r"[^0-9a-zA-Z]+", "_", name).strip("_").lower()
    aliases = {
        "pulocationid": "pu_location_id",
        "pu_location_id": "pu_location_id",
        "dolocationid": "do_location_id",
        "do_location_id": "do_location_id",
        "dropoff_datetime": "dropoff_datetime",
        "drop_off_datetime": "dropoff_datetime",
    }
    return aliases.get(normalized, normalized)


def normalize_columns(df):
    for original_name in df.columns:
        canonical = canonical_name(original_name)
        if original_name != canonical:
            df = df.withColumnRenamed(original_name, canonical)
    return df


args = getResolvedOptions(
    sys.argv,
    [
        "JOB_NAME",
        "data_bucket_name",
        "database_name",
        "fhvhv_table_name",
        "run_id",
    ],
)

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args["JOB_NAME"], args)

data_bucket = args["data_bucket_name"]
database_name = args["database_name"]
table_name = args["fhvhv_table_name"]
run_id = args["run_id"]

bronze_prefix = "bronze/"
silver_prefix = "silver/"

taxi_zones_path = f"s3://{data_bucket}/{bronze_prefix}reference/taxi_zone_lookup.csv"
silver_output_path = f"s3://{data_bucket}/{silver_prefix}fhvhv_trips/"

print(f"Loading Bronze trips from Glue Catalog table: {database_name}.{table_name}")
raw_trip_dyf = glueContext.create_dynamic_frame.from_catalog(
    database=database_name,
    table_name=table_name,
    transformation_ctx="bronze_trip_dyf",
)
raw_trip_df = normalize_columns(raw_trip_dyf.toDF())

if not raw_trip_df.columns:
    print("No new Bronze records were available for this run; source read returned no columns.")
    raw_trip_df = spark.createDataFrame(
        [],
        """
        dispatching_base_num string,
        pickup_datetime timestamp,
        dropoff_datetime timestamp,
        pu_location_id int,
        do_location_id int,
        sr_flag int,
        affiliated_base_number string
        """,
    )

print(f"Loading Bronze taxi zone lookup data from: {taxi_zones_path}")
zones_df = normalize_columns(spark.read.option("header", "true").csv(taxi_zones_path))
zones_df = zones_df.select(
    col("locationid").cast("int").alias("location_id"),
    col("borough"),
    col("zone"),
    col("service_zone"),
)

typed_trip_df = (
    raw_trip_df.withColumn("pickup_datetime", to_timestamp(col("pickup_datetime")))
    .withColumn("dropoff_datetime", to_timestamp(col("dropoff_datetime")))
    .withColumn("pu_location_id", col("pu_location_id").cast("int"))
    .withColumn("do_location_id", col("do_location_id").cast("int"))
    .withColumn("sr_flag", col("sr_flag").cast("int"))
    .withColumn("source_file", input_file_name())
)

pu_zones_df = zones_df.select(
    col("location_id").alias("pu_location_id"),
    col("borough").alias("pu_borough"),
    col("zone").alias("pu_zone"),
    col("service_zone").alias("pu_service_zone"),
)
do_zones_df = zones_df.select(
    col("location_id").alias("do_location_id"),
    col("borough").alias("do_borough"),
    col("zone").alias("do_zone"),
    col("service_zone").alias("do_service_zone"),
)

enriched_df = typed_trip_df.join(pu_zones_df, "pu_location_id", "left").join(
    do_zones_df, "do_location_id", "left"
)

pre_quality_count = enriched_df.count()
missing_zone_count = enriched_df.filter(
    col("pu_borough").isNull() | col("do_borough").isNull()
).count()
print(f"Bronze records read: {pre_quality_count}")
print(f"Records with unresolved taxi zone metadata: {missing_zone_count}")

silver_df = (
    enriched_df.withColumn("pickup_date", to_date(col("pickup_datetime")))
    .withColumn("pickup_year", year(col("pickup_date")).cast("int"))
    .withColumn("pickup_month", month(col("pickup_date")).cast("int"))
    .withColumn("pickup_day", dayofmonth(col("pickup_date")).cast("int"))
    .withColumn("pickup_hour", hour(col("pickup_datetime")).cast("int"))
    .withColumn("pickup_date_key", date_format(col("pickup_date"), "yyyyMMdd").cast("int"))
    .withColumn(
        "trip_duration_minutes",
        (
            unix_timestamp(col("dropoff_datetime"))
            - unix_timestamp(col("pickup_datetime"))
        )
        / 60.0,
    )
    .withColumn("run_id", lit(run_id))
    .withColumn("load_timestamp", current_timestamp())
)

silver_df = silver_df.withColumn(
    "trip_id",
    sha2(
        concat_ws(
            "||",
            col("dispatching_base_num"),
            col("pickup_datetime").cast("string"),
            col("dropoff_datetime").cast("string"),
            col("pu_location_id").cast("string"),
            col("do_location_id").cast("string"),
            col("affiliated_base_number"),
            col("source_file"),
        ),
        256,
    ),
)

silver_df = silver_df.withColumn(
    "pu_borough_sanitized", regexp_replace(col("pu_borough"), r"[^a-zA-Z0-9 ]", "_")
).withColumn("pu_zone_sanitized", regexp_replace(col("pu_zone"), r"[^a-zA-Z0-9 ]", "_"))

silver_df = silver_df.filter(
    col("pickup_year").isNotNull()
    & col("pickup_month").isNotNull()
    & col("run_id").isNotNull()
    & (col("trip_duration_minutes") >= 0)
    & (col("trip_duration_minutes") < 1440)
)

final_count = silver_df.count()
print(f"Silver records to append for run_id={run_id}: {final_count}")

if final_count > 0:
    print(f"Writing Silver Parquet data to: {silver_output_path}")
    silver_df.write.mode("append").partitionBy(
        "pickup_year", "pickup_month", "run_id"
    ).parquet(silver_output_path)
else:
    print("No new Bronze records were available for this run; Silver write skipped.")

job.commit()
print("Silver transformation job completed successfully.")
