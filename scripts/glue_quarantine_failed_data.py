import sys

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql.functions import current_timestamp, lit


args = getResolvedOptions(
    sys.argv,
    [
        "JOB_NAME",
        "data_bucket_name",
        "run_id",
        "dq_ruleset_name",
        "dq_result_id",
        "dq_score",
    ],
)

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args["JOB_NAME"], args)

data_bucket = args["data_bucket_name"]
run_id = args["run_id"]

silver_path = f"s3://{data_bucket}/silver/fhvhv_trips/"
quarantine_path = f"s3://{data_bucket}/quarantine/fhvhv_trips/run_id={run_id}/"

print(f"Loading Silver data from: {silver_path}")
silver_df = spark.read.parquet(silver_path)

if run_id != "manual":
    silver_df = silver_df.filter(silver_df.run_id == run_id)

quarantine_df = (
    silver_df.withColumn("quarantined_at", current_timestamp())
    .withColumn("dq_ruleset_name", lit(args["dq_ruleset_name"]))
    .withColumn("dq_result_id", lit(args["dq_result_id"]))
    .withColumn("dq_score", lit(args["dq_score"]))
)

quarantine_count = quarantine_df.count()
print(f"Quarantining {quarantine_count} Silver records for run_id={run_id}")
print(f"Writing quarantine records to: {quarantine_path}")

quarantine_df.write.mode("overwrite").parquet(quarantine_path)

job.commit()
print("Quarantine job completed.")
