#!/usr/bin/env python3
"""
Antigravity CLI Quota Warning Hook (PreInvocation & PostInvocation)
Monitors remaining model quota fractions via local language server RPC.
Detects currently active model from stdin payload (or CLI args) and checks
Quota for the active model family (GEMINI / CLAUDE / GPT).
Injects ephemeral warning messages with agent instructions so the warning
is prominently displayed to the user in the generated response, including
a reminder that the user can run /usage to inspect full quota status.
Setting QUOTA_THRESHOLD (or threshold parameter) to -1 disables the check entirely.
Zero LLM token consumption, fast, standard-library-only execution.
"""

import argparse
import json
import os
import re
import ssl
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone


def find_agy_ports() -> list[int]:
    """Find listening HTTPS ports for the agy process on 127.0.0.1"""
    ports = []

    # Try ss command
    try:
        output = subprocess.check_output(
            ["ss", "-tulpn"], stderr=subprocess.DEVNULL, text=True
        )
        for line in output.splitlines():
            if "agy" in line and "127.0.0.1" in line:
                match = re.search(r"127\.0\.0\.1:(\d+)", line)
                if match:
                    ports.append(int(match.group(1)))
    except Exception:
        pass

    # Try netstat if ss yielded nothing
    if not ports:
        try:
            output = subprocess.check_output(
                ["netstat", "-tulpn"], stderr=subprocess.DEVNULL, text=True
            )
            for line in output.splitlines():
                if "agy" in line and "127.0.0.1" in line:
                    match = re.search(r"127\.0\.0\.1:(\d+)", line)
                    if match:
                        ports.append(int(match.group(1)))
        except Exception:
            pass

    return list(dict.fromkeys(ports))


def fetch_user_status(port: int, timeout: float = 2.0) -> dict:
    """Fetch user status from Antigravity Connect RPC API"""
    url = f"https://127.0.0.1:{port}/exa.language_server_pb.LanguageServerService/GetUserStatus"
    headers = {
        "Content-Type": "application/json",
        "Connect-Protocol-Version": "1",
        "User-Agent": "antigravity",
    }
    payload = json.dumps(
        {
            "metadata": {
                "ideName": "antigravity",
                "extensionName": "antigravity",
                "locale": "en",
            }
        }
    ).encode("utf-8")

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    req = urllib.request.Request(
        url, data=payload, headers=headers, method="POST"
    )
    with urllib.request.urlopen(req, context=ctx, timeout=timeout) as resp:
        if resp.status == 200:
            return json.loads(resp.read().decode("utf-8"))
    return {}


def format_duration(seconds: float) -> str:
    """Format seconds into 'Xh Ym' or 'Ym'"""
    if seconds <= 0:
        return "now"
    total_minutes = int(round(seconds / 60))
    hours = total_minutes // 60
    minutes = total_minutes % 60
    if hours > 0:
        return f"{hours}h {minutes:02d}m"
    return f"{minutes}m"


def load_config_threshold(script_dir: str) -> float:
    """Load threshold from config.json if present, or env var QUOTA_THRESHOLD, default to 20.0"""
    env_threshold = os.environ.get("QUOTA_THRESHOLD")
    if env_threshold:
        try:
            return float(env_threshold)
        except ValueError:
            pass

    config_path = os.path.join(script_dir, "..", "config.json")
    if os.path.exists(config_path):
        try:
            with open(config_path, "r", encoding="utf-8") as f:
                cfg = json.load(f)
                if "threshold" in cfg:
                    return float(cfg["threshold"])
        except Exception:
            pass

    return 20.0


def identify_family(model_identifier: str) -> str:
    """Identify model family (GEMINI, CLAUDE, GPT, or OTHER)"""
    name = (model_identifier or "").lower()
    if "gemini" in name:
        return "GEMINI"
    elif "claude" in name:
        return "CLAUDE"
    elif "gpt" in name:
        return "GPT"
    return "OTHER"


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    default_threshold = load_config_threshold(script_dir)

    parser = argparse.ArgumentParser(
        description="Antigravity Active Model Quota Check Hook"
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=default_threshold,
        help="Quota warning threshold in percentage (e.g. 20 for 20%%, or -1 to disable)",
    )
    parser.add_argument(
        "--model",
        type=str,
        default="",
        help="Override active model name manually",
    )
    args, _ = parser.parse_known_args()

    # If threshold is negative (e.g. -1), quota check is completely disabled
    if args.threshold < 0:
        print(json.dumps({"injectSteps": []}))
        sys.exit(0)

    # Read context JSON payload from stdin (passed by Antigravity CLI lifecycle hook)
    stdin_data = {}
    try:
        if not sys.stdin.isatty():
            input_text = sys.stdin.read()
            if input_text.strip():
                stdin_data = json.loads(input_text)
    except Exception:
        pass

    raw_active_model = args.model or stdin_data.get("modelName") or ""
    active_family = identify_family(raw_active_model)

    ports = find_agy_ports()
    if not ports:
        print(json.dumps({"injectSteps": []}))
        sys.exit(0)

    user_status_data = None
    for port in ports:
        try:
            data = fetch_user_status(port)
            if data and "userStatus" in data:
                user_status_data = data
                break
        except Exception:
            continue

    if not user_status_data:
        print(json.dumps({"injectSteps": []}))
        sys.exit(0)

    user_status = user_status_data.get("userStatus", {})
    cascade_data = user_status.get("cascadeModelConfigData", {})
    models = cascade_data.get("clientModelConfigs", [])

    # Group model quotas by family
    family_quotas = {}
    now = datetime.now(timezone.utc)

    for m in models:
        label = m.get("label") or m.get("modelId") or "Unknown"
        model_id = m.get("modelId") or ""
        quota_info = m.get("quotaInfo")

        if not quota_info:
            continue

        fam = identify_family(f"{label} {model_id}")
        if fam not in family_quotas:
            rem_frac = quota_info.get("remainingFraction", 1.0)
            rem_pct = rem_frac * 100.0
            reset_raw = quota_info.get("resetTime", "")
            refresh_str = "soon"
            if reset_raw:
                try:
                    reset_dt = datetime.fromisoformat(reset_raw.replace("Z", "+00:00"))
                    diff_sec = (reset_dt - now).total_seconds()
                    refresh_str = f"in {format_duration(diff_sec)}"
                except Exception:
                    pass

            family_quotas[fam] = {
                "remainingPct": rem_pct,
                "refreshStr": refresh_str,
                "sampleLabel": label,
            }

    warnings = []
    family_order = ["GEMINI", "CLAUDE", "GPT", "OTHER"]
    if active_family in family_order:
        family_order.remove(active_family)
        family_order.insert(0, active_family)

    for fam in family_order:
        if fam not in family_quotas:
            continue
        q = family_quotas[fam]
        pct = q["remainingPct"]

        if pct <= args.threshold:
            is_active = (fam == active_family) or (active_family == "OTHER" and raw_active_model == "")
            tag = " [ACTIVE MODEL]" if is_active else ""
            warnings.append(
                f" - {fam} Models{tag}: {pct:.1f}% remaining (Refreshes {q['refreshStr']})"
            )

    output = {"injectSteps": []}
    if warnings:
        active_info_str = f" (Active: {raw_active_model})" if raw_active_model else ""
        warn_msg = (
            f"⚠️ [SYSTEM QUOTA WARNING] Model quota is below threshold ({args.threshold:.0f}%){active_info_str}:\n"
            + "\n".join(warnings)
            + "\n\n[MANDATORY INSTRUCTION FOR AGENT]: The model quota has dropped below the threshold. "
            + "You MUST display a prominent Quota Warning banner at the very top of your response for THIS TURN ONLY! "
            + "Do NOT display a warning banner on subsequent turns unless another quota warning is explicitly injected. "
            + "In the warning banner, you MUST also inform the user that they can run the '/usage' command at any time to inspect detailed quota status."
        )
        output["injectSteps"].append({"ephemeralMessage": warn_msg})

    print(json.dumps(output, ensure_ascii=False))


if __name__ == "__main__":
    main()
