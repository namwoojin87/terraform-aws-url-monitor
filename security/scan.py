"""Run the full offline Terraform scan and retain evidence on failures."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=ROOT)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "security" / "reports")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    raw_path = args.output_dir / "checkov.json"
    log_path = args.output_dir / "checkov.log"
    command = [
        sys.executable, "-m", "checkov.main",
        "--config-file", str(ROOT / "security" / "checkov.yml"),
        "--directory", str(args.directory.resolve()),
    ]
    environment = os.environ.copy()
    environment.update(PYTHONUTF8="1", AWS_EC2_METADATA_DISABLED="true")
    lines = ["## Terraform security scan", ""]
    exit_code = 2
    try:
        with raw_path.open("w", encoding="utf-8") as output, log_path.open(
            "w", encoding="utf-8"
        ) as errors:
            result = subprocess.run(
                command, stdout=output, stderr=errors, env=environment, timeout=300,
            )
        lines.append(f"Checkov exit code: {result.returncode}.")
        report = json.loads(raw_path.read_text(encoding="utf-8"))
        # Checkov returns only the summary object for an empty directory.
        summary = report.get("summary", report)
        passed = summary["passed"]
        failed = summary["failed"]
        skipped = summary["skipped"]
        parsing_errors = summary["parsing_errors"]
        resources = summary.get("resource_count", 0)
        lines.extend([
            f"Checkov version: {summary.get('checkov_version', 'unknown')}.",
            f"Resources evaluated: {resources}. Passed checks: {passed}. "
            f"Failed checks: {failed}. Skipped checks: {skipped}. "
            f"Parsing errors: {parsing_errors}.",
            "",
        ])
        for category in ("failed_checks", "skipped_checks"):
            findings = report.get("results", {}).get(category, [])
            if findings:
                lines.extend(["", f"### {category.replace('_', ' ').capitalize()}", ""])
            for finding in findings:
                path = finding["file_path"].replace("\\", "/").lstrip("/")
                lines.append(
                    f"- `{finding['check_id']}` on `{finding['resource']}` "
                    f"in `{path}`: {finding['check_name']}"
                )

        # Decide only after rendering evidence; malformed findings must never announce success.
        if parsing_errors:
            lines.append("ERROR: Parsing errors prevent a complete scan.")
        elif not resources or not (passed + failed + skipped):
            lines.append("ERROR: No resources evaluated by security checks.")
        elif result.returncode not in (0, 1):
            lines.append("ERROR: Checkov did not complete normally; inspect checkov.log.")
        elif failed or skipped or result.returncode:
            exit_code = 1
            lines.append("FAILED: Findings or unapproved skipped checks remain unresolved.")
        else:
            exit_code = 0
            lines.append("PASSED: All evaluated checks passed; no checks were skipped.")
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.TimeoutExpired) as error:
        exit_code = 2
        lines.extend(["", f"ERROR: {type(error).__name__}: {error}"])

    lines.extend([
        "",
        "Full scanner output: checkov.json. Diagnostic output: checkov.log.",
        "No risk exceptions are approved or automatically applied by this gate.",
    ])
    markdown = "\n".join(lines) + "\n"
    (args.output_dir / "summary.md").write_text(markdown, encoding="utf-8")
    print(markdown)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
