from pathlib import Path


def test_alert_key_has_explicit_destroy_guard():
    source = (
        Path(__file__).resolve().parents[1] / "bootstrap" / "alerts-encryption.tf"
    ).read_text(encoding="utf-8")
    assert "prevent_destroy = true" in source
