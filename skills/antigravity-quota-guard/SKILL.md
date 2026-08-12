---
name: antigravity-quota-guard
description: "Comprehensive operational skill and protocol guide for Antigravity CLI Agent Hooks, local Connect RPC quota monitoring, and transient instruction execution rules. Enforces single-turn transient warning banner lifecycle, prevents prompt context retention of stale quota banners, and guides zero-overhead model quota management."
metadata:
  version: "1.0.0"
  developer: "tanaikech"
  status: active
---

# Antigravity Quota Guard & Agent Hook Operational Protocol

`antigravity-quota-guard` is the official operational skill for managing model quota awareness, local Connect RPC status queries, and agent hook lifecycle behaviors inside **Google Antigravity CLI**.

---

## ⚡ Core Operational Guidelines & Inviolable Rules

### 1. Transient Instruction Scope Protocol

* **Single-Turn Directive Execution**: When a CLI Agent Hook injects a system warning message (`ephemeralMessage`) during a low-quota state, the directive applies **FOR THE CURRENT TURN ONLY**.
* **Strict Suppression on Normal State**: When remaining quota is above the warning threshold, the hook outputs `{"injectSteps": []}`. Upon receiving `{"injectSteps": []}`, the AI Agent **MUST NOT** render or repeat any Quota Warning banner from previous conversation turns.
* **Context Retention Immunity**: The AI Agent must recognize that previous turn ephemeral warnings do not persist as perpetual prompt rules for future turns.

---

## 🔍 How Local Connect RPC Quota Monitoring Works

1. **Local HTTPS Socket Discovery**: Antigravity CLI hosts a local HTTPS server on `127.0.0.1` listening on dynamic ports for gRPC / Connect Protocol requests.
2. **Endpoint Specification**: The internal endpoint `/exa.language_server_pb.LanguageServerService/GetUserStatus` returns real-time model configuration and remaining quota fractions (`quotaInfo.remainingFraction` and `quotaInfo.resetTime`).
3. **Five-Hour Sliding Window Scope**: The local RPC endpoint monitors the active **5-Hour Limit Remaining** fraction for active model pools (GEMINI, CLAUDE, GPT).

---

## 🛡️ Dual Execution Patterns & Token Overhead

* **Pattern A: Normal State (Quota > Threshold)**
  * Returns `{"injectSteps": []}`.
  * **Zero Token Overhead**: Consumes **0 LLM API tokens**. Executes silently in <50ms completely outside the LLM execution turn.
* **Pattern B: Warning State (Quota <= Threshold)**
  * Injects a transient system message (`ephemeralMessage`) instructing the agent to display a prominent Quota Warning banner at the very top of its response for **THIS TURN ONLY**, alongside a reminder that the user can run `/usage` at any time.

---

## 💡 Slash Command vs Agent Automation Clarification

* **Manual `/usage` Command**: Developers can type `/usage` directly in the CLI terminal to open the interactive quota UI. Running `/usage` manually does **NOT** consume LLM API quota.
* **Agent Automation Limitation**: AI Agents running autonomous multi-step coding loops cannot execute slash commands programmatically. The `antigravity-cli-check-usage-plugin` hook solves this limitation by checking quota automatically outside the LLM turn.
