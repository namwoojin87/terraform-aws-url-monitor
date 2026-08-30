import re
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = (
    REPOSITORY_ROOT / ".github" / "workflows" / "ci.yml",
    REPOSITORY_ROOT / ".github" / "workflows" / "deploy.yml",
)


def _workflow(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_all_workflow_actions_use_immutable_sha_pins_with_version_comments():
    for workflow in WORKFLOWS:
        uses = re.findall(
            r"^\s*- uses: [^@\s]+@([^\s#]+)(?P<comment>\s+# v[^\s]+)?$",
            _workflow(workflow),
            re.MULTILINE,
        )

        assert uses
        assert all(re.fullmatch(r"[0-9a-f]{40}", ref) for ref, _ in uses)
        assert all(comment for _, comment in uses)


def test_plan_artifact_encrypts_the_plan_and_carries_the_lambda_zip():
    deploy = _workflow(WORKFLOWS[1])
    artifact = re.search(
        r"- uses: actions/upload-artifact@[^\n]+\n        with:\n(?P<with>(?:          .*\n)+)",
        deploy,
    )

    assert 'age --encrypt -r "${{ vars.TF_PLAN_AGE_RECIPIENT }}" -o infra/tfplan.age infra/tfplan' in deploy
    assert "rm -f infra/tfplan" in deploy
    assert artifact is not None
    assert "infra/tfplan.age" in artifact.group("with")
    assert "infra/url-monitor.zip" in artifact.group("with")
    assert "infra/tfplan\n" not in artifact.group("with")


def test_production_apply_decrypts_the_artifact_without_receiving_alert_email():
    deploy = _workflow(WORKFLOWS[1])

    assert "environment: production" in deploy
    assert deploy.count("TF_VAR_alert_email: ${{ secrets.ALERT_EMAIL }}") == 1
    assert "TF_VAR_alert_email: ${{ secrets.ALERT_EMAIL }}" not in re.search(
        r"^env:\n(?P<env>(?:  .*\n)+)", deploy, re.MULTILINE
    ).group("env")
    assert re.search(
        r"- name: Create saved plan\n"
        r"        shell: bash\n"
        r"        env:\n"
        r"          TF_VAR_alert_email: \$\{\{ secrets\.ALERT_EMAIL \}\}",
        deploy,
    )
    assert "TF_PLAN_AGE_IDENTITY: ${{ secrets.TF_PLAN_AGE_IDENTITY }}" in deploy
    assert "age --decrypt -i <(printf '%s\\n' \"$TF_PLAN_AGE_IDENTITY\") -o infra/tfplan infra/tfplan.age" in deploy
    assert "terraform -chdir=infra apply -input=false tfplan" in deploy
