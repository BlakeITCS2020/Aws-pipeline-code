from pathlib import Path
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
TERRAFORM_DIR = REPO_ROOT / "terraform"


def read_terraform_files():
    return "\n".join(path.read_text() for path in TERRAFORM_DIR.glob("*.tf"))


class BronzeDataQualityGateTest(unittest.TestCase):
    def test_bronze_ruleset_targets_bronze_catalog_table(self):
        terraform = read_terraform_files()

        self.assertIn('resource "aws_glue_data_quality_ruleset" "bronze_fhvhv_quality"', terraform)
        self.assertIn('name        = "bronze-fhvhv-quality-${var.environment}"', terraform)
        self.assertIn("table_name    = local.bronze_fhvhv_table_name", terraform)
        self.assertIn('Layer = "Bronze"', terraform)

        for rule in [
            "RowCount > 0",
            'IsComplete "pickup_datetime"',
            'IsComplete "dropoff_datetime"',
        ]:
            self.assertIn(rule, terraform)

        self.assertNotIn('Completeness "pulocationid"', terraform)
        self.assertNotIn('Completeness "dolocationid"', terraform)

    def test_state_machine_runs_bronze_quality_before_bronze_to_silver_job(self):
        workflow = (TERRAFORM_DIR / "glue_workflow.tf").read_text()

        self.assertIn('Next         = "Start Bronze Data Quality"', workflow)
        self.assertIn('"Start Bronze Data Quality" = {', workflow)
        self.assertIn("local.bronze_fhvhv_table_name", workflow)
        self.assertIn("aws_glue_data_quality_ruleset.bronze_fhvhv_quality.name", workflow)
        self.assertIn('ResultPath = "$.BronzeDataQualityStart"', workflow)
        self.assertIn('"Bronze Quality Score Passed?" = {', workflow)
        self.assertIn('Variable                 = "$.BronzeDataQualityResult.Score"', workflow)
        self.assertIn('Next                     = "Process Bronze To Silver"', workflow)
        self.assertIn('"Bronze Data Quality Gate Failed" = {', workflow)

        bronze_gate = workflow.index('"Start Bronze Data Quality" = {')
        process_job = workflow.index('"Process Bronze To Silver" = {')
        self.assertLess(bronze_gate, process_job)

    def test_bronze_ruleset_is_exposed_and_observable(self):
        terraform = read_terraform_files()

        self.assertIn('output "bronze_data_quality_ruleset_name"', terraform)
        self.assertIn("aws_glue_data_quality_ruleset.bronze_fhvhv_quality.name", terraform)
        self.assertIn("data_pipeline_quality_rulesets", terraform)
        self.assertIn('id    = "bronze_dq"', terraform)
        self.assertIn('label = "Bronze"', terraform)


if __name__ == "__main__":
    unittest.main()
