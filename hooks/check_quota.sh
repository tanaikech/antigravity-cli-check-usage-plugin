#!/usr/bin/env bash
# Pure Bash Fallback implementation for antigravity-cli-check-usage-plugin
# Used when Python is not installed on the system.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.json"

# Read stdin JSON payload into a variable
STDIN_DATA=""
if [ ! -t 0 ]; then
  STDIN_DATA=$(cat)
fi

# Load threshold: command arg > env var > config.json > default (20.0)
THRESHOLD=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --threshold)
      THRESHOLD="$2"
      shift 2
      ;;
    --model)
      OVERRIDE_MODEL="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [ -z "$THRESHOLD" ] && [ -n "$QUOTA_THRESHOLD" ]; then
  THRESHOLD="$QUOTA_THRESHOLD"
fi

if [ -z "$THRESHOLD" ] && [ -f "$CONFIG_FILE" ]; then
  THRESHOLD=$(jq -r '.threshold // empty' "$CONFIG_FILE" 2>/dev/null || true)
fi

if [ -z "$THRESHOLD" ]; then
  THRESHOLD="20.0"
fi

# Check if threshold is disabled (< 0)
IS_DISABLED=$(awk "BEGIN {print ($THRESHOLD < 0) ? 1 : 0}")
if [ "$IS_DISABLED" -eq 1 ]; then
  echo '{"injectSteps": []}'
  exit 0
fi

# Extract active model from stdin or override
ACTIVE_MODEL=""
if [ -n "$OVERRIDE_MODEL" ]; then
  ACTIVE_MODEL="$OVERRIDE_MODEL"
elif [ -n "$STDIN_DATA" ]; then
  ACTIVE_MODEL=$(echo "$STDIN_DATA" | jq -r '.modelName // empty' 2>/dev/null || true)
fi

# Identify model family (GEMINI, CLAUDE, GPT)
identify_family() {
  local name
  name=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  if [[ "$name" == *"gemini"* ]]; then
    echo "GEMINI"
  elif [[ "$name" == *"claude"* ]]; then
    echo "CLAUDE"
  elif [[ "$name" == *"gpt"* ]]; then
    echo "GPT"
  else
    echo "OTHER"
  fi
}

ACTIVE_FAMILY=$(identify_family "$ACTIVE_MODEL")

# Discover listening ports
PORTS=()
if command -v ss >/dev/null 2>&1; then
  while read -r p; do
    [ -n "$p" ] && PORTS+=("$p")
  done < <(ss -tulpn 2>/dev/null | grep agy | grep -oP '127\.0\.0\.1:\K[0-9]+' | sort -u)
fi

if [ ${#PORTS[@]} -eq 0 ] && command -v netstat >/dev/null 2>&1; then
  while read -r p; do
    [ -n "$p" ] && PORTS+=("$p")
  done < <(netstat -tulpn 2>/dev/null | grep agy | grep -oP '127\.0\.0\.1:\K[0-9]+' | sort -u)
fi

if [ ${#PORTS[@]} -eq 0 ]; then
  echo '{"injectSteps": []}'
  exit 0
fi

# Probe GetUserStatus
RESPONSE=""
for PORT in "${PORTS[@]}"; do
  RES=$(curl -k -s -X POST "https://127.0.0.1:${PORT}/exa.language_server_pb.LanguageServerService/GetUserStatus" \
    -H "Content-Type: application/json" \
    -H "Connect-Protocol-Version: 1" \
    -d '{"metadata":{"ideName":"antigravity","extensionName":"antigravity","locale":"en"}}' 2>/dev/null || true)
  if echo "$RES" | grep -q "userStatus"; then
    RESPONSE="$RES"
    break
  fi
done

if [ -z "$RESPONSE" ]; then
  echo '{"injectSteps": []}'
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo '{"injectSteps": []}'
  exit 0
fi

# Extract models and find remaining fraction per family
SUMMARY=$(echo "$RESPONSE" | jq -r '
  .userStatus.cascadeModelConfigData.clientModelConfigs[]? |
  {
    label: (.label // .modelId // "Unknown"),
    id: (.modelId // ""),
    frac: .quotaInfo.remainingFraction,
    reset: .quotaInfo.resetTime
  } | select(.frac != null) |
  "\(.label)|\(.id)|\(.frac)|\(.reset)"
')

if [ -z "$SUMMARY" ]; me
  echo '{"injectSteps": []}'
  exit 0
fi

NOW_SEC=$(date +%s)

declare -A FAM_FRAC
declare -A FAM_RESET

while IFS='|' read -r label model_id frac reset; do
  [ -z "$label" ] && continue
  
  fam=$(identify_family "$label $model_id")
  if [ -z "${FAM_FRAC[$fam]}" ]; then
    FAM_FRAC[$fam]="$frac"
    FAM_RESET[$fam]="$reset"
  fi
done <<< "$SUMMARY"

# Check threshold for each family
FAMILIES=("GEMINI" "CLAUDE" "GPT")
if [ "$ACTIVE_FAMILY" != "OTHER" ] && [ -n "$ACTIVE_FAMILY" ]; then
  FAMILIES=("$ACTIVE_FAMILY" "GEMINI" "CLAUDE" "GPT")
fi

WARNING_LINES=()
SEEN_FAMILIES=""
for fam in "${FAMILIES[@]}"; do
  [[ "$SEEN_FAMILIES" == *":$fam:"* ]] && continue
  SEEN_FAMILIES="${SEEN_FAMILIES}:${fam}:"

  frac="${FAM_FRAC[$fam]}"
  [ -z "$frac" ] && continue

  pct=$(awk "BEGIN {printf \"%.1f\", $frac * 100}")
  is_below=$(awk "BEGIN {print ($pct <= $THRESHOLD) ? 1 : 0}")

  if [ "$is_below" -eq 1 ]; then
    reset_raw="${FAM_RESET[$fam]}"
    refresh_str="soon"
    if [ -n "$reset_raw" ] && command -v date >/dev/null 2>&1; then
      reset_clean=$(echo "$reset_raw" | sed 's/\.[0-9]*Z/Z/' | sed 's/Z/+0000/')
      reset_sec=$(date -d "$reset_clean" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S%z" "$reset_clean" +%s 2>/dev/null || echo 0)
      if [ "$reset_sec" -gt "$NOW_SEC" ]; then
        diff_sec=$((reset_sec - NOW_SEC))
        hours=$((diff_sec / 3600))
        mins=$(((diff_sec % 3600) / 60))
        if [ "$hours" -gt 0 ]; then
          refresh_str="in ${hours}h $(printf "%02d" $mins)m"
        else
          refresh_str="in ${mins}m"
        fi
      fi
    fi

    tag=""
    if [ "$fam" == "$ACTIVE_FAMILY" ]; then
      tag=" [ACTIVE MODEL]"
    fi

    WARNING_LINES+=(" - ${fam} Models${tag}: ${pct}% remaining (Refreshes ${refresh_str})")
  fi
done

if [ ${#WARNING_LINES[@]} -gt 0 ]; then
  ACTIVE_INFO=""
  if [ -n "$ACTIVE_MODEL" ]; then
    ACTIVE_INFO=" (Active: ${ACTIVE_MODEL})"
  fi

  THRESHOLD_INT=$(awk "BEGIN {printf \"%d\", $THRESHOLD}")

  HEADER="⚠️ [SYSTEM QUOTA WARNING] Model quota is below threshold (${THRESHOLD_INT}%)${ACTIVE_INFO}:"
  BODY=$(printf "%s\n" "${WARNING_LINES[@]}")
  FOOTER="[MANDATORY INSTRUCTION FOR AGENT]: The model quota has dropped below the threshold. You MUST display a prominent Quota Warning banner at the very top of your response for THIS TURN ONLY! Do NOT display a warning banner on subsequent turns unless another quota warning is explicitly injected. In the warning banner, you MUST also inform the user that they can run the '/usage' command at any time to inspect detailed quota status."

  FULL_MSG="${HEADER}
${BODY}

${FOOTER}"

  jq -n --arg msg "$FULL_MSG" '{"injectSteps": [{"ephemeralMessage": $msg}]}'
else
  echo '{"injectSteps": []}'
fi
