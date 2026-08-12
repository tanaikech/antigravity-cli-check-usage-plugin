# antigravity-cli-check-usage-plugin

Zero-overhead Antigravity CLI Agent Hook plugin for real-time model quota monitoring & proactive low-quota threshold warnings.

## Overview

Developers using **Google Antigravity CLI** frequently encounter mid-session task failures when API quota hits 0% (`⚠ Individual quota reached. Resets in 1h00m00s.`). Attempting to switch billing accounts in v1.1.12 results in signature mismatch errors (`⚠ Invalid thought signature.`), leaving developers unable to continue until the quota resets.

While the CLI provides a `/usage` slash command, AI agents cannot trigger slash commands programmatically. Asking an LLM to inspect quota via tools or prompts creates a paradox: **using LLM context tokens to check quota consumes the very quota you are trying to preserve.**

This plugin solves the problem by inspecting Antigravity CLI's internal local Connect RPC endpoint (`/exa.language_server_pb.LanguageServerService/GetUserStatus`) inside `PreInvocation` and `PostInvocation` lifecycle hooks (built upon research from [skainguyen1412/antigravity-usage](https://github.com/skainguyen1412/antigravity-usage)).

- **Zero LLM Token Overhead**: Operates entirely outside the LLM context during normal execution. Consumes **0 model tokens** when quota is above threshold.
- **Dual Runtime Support (Python + Pure Bash Fallback)**: Automatically runs via Python 3 if available; seamlessly falls back to pure Bash (`curl` + `jq`) on systems without Python installed.
- **Local Connect RPC Query**: Intercepts internal status on `127.0.0.1` using local sockets and Connect RPC.
- **Active Model Detection**: Automatically identifies the active model family (GEMINI, CLAUDE, GPT) from hook context and tags `[ACTIVE MODEL]` on the relevant quota pool.
- **Proactive Warning Banners**: Injects a transient system instruction (`ephemeralMessage`) when quota drops below the threshold, prompting the agent to present a visible warning banner and remind the user to run `/usage`.
- **Easy Disabling**: Set `QUOTA_THRESHOLD=-1` to completely bypass quota checking when not needed.

---

## Installation

Install directly via the Antigravity CLI:

```bash
agy plugin install https://github.com/tanaikech/antigravity-cli-check-usage-plugin
```

---

## Updating / Reinstalling

To update the plugin to the latest version:

1. Check installed plugins:
   ```bash
   agy plugin list
   ```
2. Uninstall the existing plugin:
   ```bash
   agy plugin uninstall antigravity-cli-check-usage-plugin
   ```
3. Reinstall from remote repository:
   ```bash
   agy plugin install https://github.com/tanaikech/antigravity-cli-check-usage-plugin
   ```

---

## Configuration & Disabling

The default warning threshold is **20.0%**. You can customize or disable the threshold via three methods:

1. **Environment Variable (Recommended)**:
   - Set custom threshold (e.g., 25%):
     ```bash
     export QUOTA_THRESHOLD=25.0
     ```
   - **Disable Quota Check Completely**:
     ```bash
     export QUOTA_THRESHOLD=-1
     ```

2. **Config File**: Edit `config.json` in the plugin directory:
   ```json
   {
     "threshold": 20.0
   }
   ```

3. **Hook Argument**: Edit `hooks.json` to pass `--threshold`:
   ```json
   "command": "bash hooks/entrypoint.sh --threshold 20.0"
   ```

---

## How It Works

1. Upon agent invocation (`PreInvocation` and `PostInvocation`), `hooks/entrypoint.sh` executes locally.
2. It detects runtime availability: uses Python 3 if installed, or falls back to pure Bash (`hooks/check_quota.sh`) if Python is absent.
3. If `QUOTA_THRESHOLD` is set to `-1` (or any negative number), the script exits immediately with `{}` (disabled mode).
4. Otherwise, it scans `127.0.0.1` listening ports for `agy` and queries `https://127.0.0.1:{PORT}/exa.language_server_pb.LanguageServerService/GetUserStatus`.
5. If remaining quota fraction for any model family is at or below the threshold:
   - **Pattern A (Quota > Threshold)**: Returns `{"injectSteps": []}` (Silent, 0 token overhead).
   - **Pattern B (Quota <= Threshold)**: Returns `{"injectSteps": [{"ephemeralMessage": "..."}]}` with mandatory agent instructions to render a prominent Quota Warning banner with a reminder to run `/usage`.

---

## Acknowledgments & References

- [skainguyen1412/antigravity-usage](https://github.com/skainguyen1412/antigravity-usage) for reverse-engineering the internal Connect RPC `GetUserStatus` endpoint on local `127.0.0.1` ports.

---

## License

MIT License
