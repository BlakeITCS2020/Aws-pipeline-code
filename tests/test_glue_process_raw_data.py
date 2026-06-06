from pathlib import Path
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "glue_process_raw_data.py"


class GlueProcessRawDataScriptTest(unittest.TestCase):
    def test_no_new_bookmarked_data_exits_before_column_casts(self):
        source = SCRIPT.read_text()

        guard = 'if not raw_trip_df.columns:'
        first_column_cast = 'raw_trip_df.withColumn("pickup_datetime"'

        self.assertIn(guard, source)
        self.assertIn("source read returned no columns", source)
        self.assertIn("spark.createDataFrame", source)
        self.assertIn("dispatching_base_num string", source)
        self.assertIn("pickup_datetime timestamp", source)
        self.assertNotIn("sys.exit(0)", source)
        self.assertLess(source.index(guard), source.index(first_column_cast))


if __name__ == "__main__":
    unittest.main()
