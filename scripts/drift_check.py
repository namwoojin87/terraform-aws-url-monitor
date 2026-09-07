"""Run a non-applying Terraform plan and publish only structural change details."""

import argparse
import html
import json
import os
import signal
import subprocess
from pathlib import Path


HEADER = "# Terraform drift check\n\n"
ACTIONS = {"noop", "read", "create", "update", "replace", "delete", "move", "import"}


def error_report(reason):
    return "error", HEADER + "Result: **ERROR**\n\n" + reason + (
        "\n\nNo infrastructure changes were applied. Raw diagnostics are withheld; "
        "check credentials, required inputs and state locking, or use the protected "
        "deployment plan for detailed investigation.\n"
    )


def safe_cell(value):
    return html.escape(value).replace("|", "&#124;").replace("`", "&#96;").replace("\n", " ").replace("\r", " ")


def summarize_plan(returncode, stdout):
    if returncode not in (0, 2):
        return error_report(f"Terraform plan exited with code {returncode}.")
    observed, proposed = set(), set()
    summary = None
    output_changes = False
    try:
        events = [json.loads(line) for line in stdout.splitlines() if line.strip()]
        if not events or events[0]["type"] != "version" or events[0]["ui"].split(".")[0] != "1":
            raise ValueError("Missing or unsupported UI version")
        for event in events:
            kind = event["type"]
            if kind == "diagnostic" and (event.get("@level") == "error" or event.get("diagnostic", {}).get("severity") == "error"):
                return error_report("Terraform reported a planning error.")
            if kind in ("resource_drift", "planned_change"):
                change = event["change"]
                action, address = change["action"], change["resource"]["addr"]
                if action not in ACTIONS or not isinstance(address, str) or not address:
                    raise ValueError("Invalid resource change")
                if action not in ("noop", "read"):
                    (observed if kind == "resource_drift" else proposed).add((address, action))
            elif kind == "change_summary":
                summary = event["changes"]
                if summary["operation"] != "plan" or any(type(summary[key]) is not int or summary[key] < 0 for key in ("add", "change", "remove")):
                    raise ValueError("Invalid plan summary")
            elif kind == "outputs":
                output_changes |= any(value.get("action", "noop") != "noop" for value in event["outputs"].values())
        if summary is None:
            raise ValueError("Plan did not finish")
    except (ValueError, TypeError, KeyError, AttributeError):
        return error_report("Terraform returned incomplete or unsupported structured output.")

    different = bool(returncode == 2 or observed or proposed or output_changes or any(summary[key] for key in ("add", "change", "remove")))
    status = "drift" if different else "clean"
    report = HEADER + ("Result: **CHANGES DETECTED**\n\n" if different else "Result: **CLEAN**\n\n")
    report += "Compared the live infrastructure with the checked-out Terraform configuration. No apply was run.\n"
    for title, rows in (("Observed external changes", observed), ("Proposed configuration changes", proposed)):
        if rows:
            report += f"\n## {title}\n\n| Resource address | Action |\n| --- | --- |\n"
            report += "".join(f"| {safe_cell(address)} | {action} |\n" for address, action in sorted(rows))
    if output_changes:
        report += "\nRoot output changes were detected; output names and values are withheld.\n"
    if different:
        report += "\nReview the differences. Proposed changes may also be unapplied commits, not external edits. Use the protected deployment workflow for any repair.\n"
    else:
        report += "\nNo drift or pending configuration changes were detected.\n"
    return status, report


def run_check(directory, terraform="terraform"):
    # Avoid inherited options creating plaintext plans or provider debug logs.
    environment = {key: value for key, value in os.environ.items() if not key.startswith(("TF_LOG", "TF_CLI_ARGS"))}
    try:
        process = subprocess.Popen(
            [terraform, f"-chdir={directory}", "plan", "-input=false", "-json", "-detailed-exitcode", "-lock-timeout=60s"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace", env=environment,
            **({"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == "nt" else {}),
        )
    except OSError:
        return error_report("Terraform could not start.")
    try:
        stdout, _ = process.communicate(timeout=600)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        # Give Terraform a chance to release the S3 lock before a forced stop.
        try:
            process.send_signal(signal.CTRL_BREAK_EVENT if os.name == "nt" else signal.SIGINT)
        except OSError:
            pass  # The process may already have exited.
        try:
            process.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
        return error_report("Terraform timed out or was interrupted. Check lock ownership before any manual unlock.")
    return summarize_plan(process.returncode, stdout)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", default="infra")
    parser.add_argument("--terraform", default="terraform")
    args = parser.parse_args(argv)
    status, report = run_check(args.directory, args.terraform)
    print(report, end="")
    if summary_path := os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(summary_path).open("a", encoding="utf-8") as summary:
            summary.write(report)
    if status != "clean":
        message = "Infrastructure differences detected; review the job summary." if status == "drift" else "Drift check failed; review the job summary."
        print(f"::error title=Terraform drift check::{message}")
    return {"clean": 0, "drift": 2, "error": 1}[status]


if __name__ == "__main__":
    raise SystemExit(main())
