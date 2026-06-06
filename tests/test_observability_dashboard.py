from pathlib import Path
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
TERRAFORM_DIR = REPO_ROOT / "terraform"


def read_terraform_files():
    return "\n".join(path.read_text() for path in TERRAFORM_DIR.glob("*.tf"))


class ObservabilityDashboardTest(unittest.TestCase):
    def test_cloudwatch_dashboard_is_managed_by_terraform(self):
        terraform = read_terraform_files()

        self.assertIn('resource "aws_cloudwatch_dashboard" "data_pipeline_observability"', terraform)
        self.assertIn('dashboard_name = "data-pipeline-observability-${var.environment}"', terraform)
        self.assertIn("jsonencode({", terraform)

    def test_dashboard_tracks_step_functions_execution_health(self):
        terraform = read_terraform_files()

        self.assertIn('"AWS/States"', terraform)
        self.assertIn('"StateMachineArn"', terraform)
        self.assertIn("aws_sfn_state_machine.data_pipeline_state_machine.arn", terraform)

        for metric in [
            "ExecutionsStarted",
            "ExecutionsSucceeded",
            "ExecutionsFailed",
            "ExecutionsTimedOut",
            "ExecutionTime",
        ]:
            self.assertIn(f'"{metric}"', terraform)

    def test_dashboard_tracks_glue_job_runtime_and_progress_metrics(self):
        terraform = read_terraform_files()

        self.assertIn('"Glue"', terraform)
        self.assertIn('"JobName"', terraform)
        self.assertIn('"JobRunId"', terraform)
        self.assertIn('"ALL"', terraform)
        self.assertIn('"Type"', terraform)
        self.assertIn('"count"', terraform)

        for job_reference in [
            "aws_glue_job.glue_process_raw_data.name",
            "aws_glue_job.glue_manage_redshift_schema_job.name",
            "aws_glue_job.glue_load_data_to_redshift_job.name",
            "aws_glue_job.glue_quarantine_failed_data.name",
        ]:
            self.assertIn(job_reference, terraform)

        for metric in [
            "glue.driver.aggregate.elapsedTime",
            "glue.driver.aggregate.numCompletedTasks",
            "glue.driver.aggregate.bytesRead",
        ]:
            self.assertIn(f'"{metric}"', terraform)

    def test_dashboard_tracks_data_quality_rule_metrics(self):
        terraform = read_terraform_files()

        self.assertIn("Glue Data Quality", terraform)
        self.assertIn("aws_glue_data_quality_ruleset.bronze_fhvhv_quality.name", terraform)
        self.assertIn("aws_glue_data_quality_ruleset.silver_fhvhv_quality.name", terraform)
        self.assertIn('{\\"Glue Data Quality\\",Ruleset,Table,Database,CatalogId}', terraform)
        self.assertIn('Ruleset=\\"${ruleset.name}\\"', terraform)
        self.assertIn('label = "Bronze"', terraform)
        self.assertIn('label = "Silver"', terraform)
        self.assertIn("${ruleset.label} passed rules", terraform)

        for metric in [
            "glue.data.quality.rules.passed",
            "glue.data.quality.rules.failed",
        ]:
            self.assertIn(metric, terraform)

    def test_dashboard_url_is_exposed_as_output_and_documented(self):
        terraform = read_terraform_files()
        readme = (REPO_ROOT / "README.md").read_text()

        self.assertIn('output "cloudwatch_observability_dashboard_url"', terraform)
        self.assertIn("aws_cloudwatch_dashboard.data_pipeline_observability.dashboard_name", terraform)
        self.assertIn("CloudWatch observability dashboard", readme)

if __name__ == "__main__":
    unittest.main()
