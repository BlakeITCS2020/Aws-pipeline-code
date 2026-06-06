import logging
import re
import sys

import psycopg2
from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext


logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger(__name__)


def require_identifier(value, name):
    if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", value):
        raise ValueError(f"{name} must be a simple SQL identifier, got: {value}")
    return value


def execute_statements(conn, statements):
    with conn.cursor() as cursor:
        for statement in statements:
            logger.info("Executing Redshift DDL:\n%s", statement)
            cursor.execute(statement)


def main():
    args = getResolvedOptions(
        sys.argv,
        [
            "JOB_NAME",
            "redshift_database",
            "redshift_schema",
            "redshift_table",
            "redshift_host",
            "redshift_username",
            "redshift_password",
        ],
    )

    sc = SparkContext()
    glueContext = GlueContext(sc)
    job = Job(glueContext)
    job.init(args["JOB_NAME"], args)

    schema_name = require_identifier(args["redshift_schema"], "redshift_schema")
    fact_table = require_identifier(args["redshift_table"], "redshift_table")
    staging_fact_table = require_identifier(f"staging_{fact_table}", "staging_fact_table")

    endpoint_parts = args["redshift_host"].split(":")
    host = endpoint_parts[0]
    port = int(endpoint_parts[1]) if len(endpoint_parts) > 1 else 5439

    statements = [
        f"CREATE SCHEMA IF NOT EXISTS {schema_name};",
        f"""
        CREATE TABLE IF NOT EXISTS {schema_name}.dim_zone (
            location_id INTEGER NOT NULL,
            borough VARCHAR(64),
            zone VARCHAR(128),
            service_zone VARCHAR(64),
            load_timestamp TIMESTAMP
        )
        DISTSTYLE ALL
        SORTKEY(location_id);
        """,
        f"""
        CREATE TABLE IF NOT EXISTS {schema_name}.staging_dim_zone (
            location_id INTEGER,
            borough VARCHAR(64),
            zone VARCHAR(128),
            service_zone VARCHAR(64),
            load_timestamp TIMESTAMP
        );
        """,
        f"""
        CREATE TABLE IF NOT EXISTS {schema_name}.dim_date (
            date_key INTEGER NOT NULL,
            full_date DATE,
            year SMALLINT,
            month SMALLINT,
            day SMALLINT,
            day_of_week SMALLINT,
            day_name VARCHAR(16),
            month_name VARCHAR(16),
            load_timestamp TIMESTAMP
        )
        DISTSTYLE ALL
        SORTKEY(date_key);
        """,
        f"""
        CREATE TABLE IF NOT EXISTS {schema_name}.staging_dim_date (
            date_key INTEGER,
            full_date DATE,
            year SMALLINT,
            month SMALLINT,
            day SMALLINT,
            day_of_week SMALLINT,
            day_name VARCHAR(16),
            month_name VARCHAR(16),
            load_timestamp TIMESTAMP
        );
        """,
        f"""
        CREATE TABLE IF NOT EXISTS {schema_name}.{fact_table} (
            trip_id VARCHAR(64) NOT NULL,
            dispatching_base_num VARCHAR(32),
            affiliated_base_number VARCHAR(32),
            pickup_datetime TIMESTAMP,
            dropoff_datetime TIMESTAMP,
            pickup_date DATE,
            pickup_date_key INTEGER,
            pickup_hour SMALLINT,
            pu_location_id INTEGER,
            do_location_id INTEGER,
            sr_flag INTEGER,
            trip_duration_minutes DOUBLE PRECISION,
            source_file VARCHAR(512),
            source_run_id VARCHAR(128),
            load_timestamp TIMESTAMP
        )
        DISTSTYLE KEY
        DISTKEY(pickup_date_key)
        SORTKEY(pickup_date_key, pickup_hour, pu_location_id);
        """,
        f"""
        CREATE TABLE IF NOT EXISTS {schema_name}.{staging_fact_table} (
            trip_id VARCHAR(64),
            dispatching_base_num VARCHAR(32),
            affiliated_base_number VARCHAR(32),
            pickup_datetime TIMESTAMP,
            dropoff_datetime TIMESTAMP,
            pickup_date DATE,
            pickup_date_key INTEGER,
            pickup_hour SMALLINT,
            pu_location_id INTEGER,
            do_location_id INTEGER,
            sr_flag INTEGER,
            trip_duration_minutes DOUBLE PRECISION,
            source_file VARCHAR(512),
            source_run_id VARCHAR(128),
            load_timestamp TIMESTAMP
        );
        """,
    ]

    conn = None
    try:
        logger.info("Connecting to Redshift: %s:%s", host, port)
        conn = psycopg2.connect(
            host=host,
            port=port,
            dbname=args["redshift_database"],
            user=args["redshift_username"],
            password=args["redshift_password"],
        )
        conn.autocommit = True
        execute_statements(conn, statements)
        logger.info("Redshift dimensional schema is ready.")
    finally:
        if conn:
            conn.close()
        job.commit()


if __name__ == "__main__":
    main()
