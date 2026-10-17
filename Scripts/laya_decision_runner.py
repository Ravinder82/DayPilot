#!/usr/bin/env python3
"""
Laya Decision Engine Runner

Accepts a JSON payload on stdin with:
  - state: string (app name, window title, OCR text)
  - questions: dict of Laya question definitions

Outputs a JSON result on stdout with:
  - is_meaningful_work: { probability, decision }
  - is_discarded_insight: { probability, decision }
  - data_sensitivity: { score, label, probabilities }
  - work_category: { choice, probabilities }
  - latency_ms: float
  - tokens_saved_estimate: int
"""

import sys
import json
import time
import os

def main():
    # Read input from stdin
    try:
        input_data = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        print(json.dumps({"error": f"Invalid JSON input: {e}"}))
        sys.exit(1)

    state = input_data.get("state", "")
    questions = input_data.get("questions", {})

    if not state or not questions:
        print(json.dumps({"error": "Missing 'state' or 'questions' in input"}))
        sys.exit(1)

    try:
        from laya_mlx import Agent
    except ImportError:
        # Fallback: deterministic rule-based decisions
        result = fallback_decision(state, questions)
        print(json.dumps(result))
        sys.exit(0)

    try:
        agent = Agent(subfolder="typed-decisions")
        start = time.time()
        prediction = agent.predict(state, questions)
        elapsed_ms = (time.time() - start) * 1000

        answers = prediction.get("answers", {})

        # Parse is_meaningful_work (noul)
        meaningful = answers.get("is_meaningful_work", {})
        meaningful_prob = meaningful.get("noul", 0.5)
        meaningful_decision = meaningful_prob >= 0.45

        # Parse is_discarded_insight (noul)
        insight = answers.get("is_discarded_insight", {})
        insight_prob = insight.get("noul", 0.5)
        insight_decision = insight_prob >= 0.5

        # Parse data_sensitivity (score)
        sensitivity = answers.get("data_sensitivity", {})
        sensitivity_score = sensitivity.get("score", 0.0)
        sensitivity_probs = sensitivity.get("probabilities", {})
        # Use argmax of probabilities for label, not raw score
        if sensitivity_probs:
            max_idx = max(sensitivity_probs, key=lambda k: sensitivity_probs[k])
            idx_to_label = {"0": "none", "1": "common", "2": "sensitive", "3": "secrets"}
            sensitivity_label = idx_to_label.get(str(max_idx), "common")
        else:
            # Fallback: use score thresholds
            if sensitivity_score < 0.25:
                sensitivity_label = "none"
            elif sensitivity_score < 0.5:
                sensitivity_label = "common"
            elif sensitivity_score < 0.75:
                sensitivity_label = "sensitive"
            else:
                sensitivity_label = "secrets"

        # Parse work_category (choice)
        category = answers.get("work_category", {})
        work_cat = category.get("choice", "routine_admin")
        cat_probs = category.get("probabilities", {})

        # Estimate tokens saved: if we drop the frame, we save ~200 tokens
        # (OCR text + prompt overhead) that would have gone to cloud LLM
        tokens_saved = 0
        if not meaningful_decision:
            tokens_saved += 200  # dropped idle/social frame
        if sensitivity_label == "secrets":
            tokens_saved += 200  # purged sensitive frame
        if work_cat == "routine_admin":
            tokens_saved += 150  # compact counter instead of full LLM call

        result = {
            "is_meaningful_work": {
                "probability": meaningful_prob,
                "decision": meaningful_decision
            },
            "is_discarded_insight": {
                "probability": insight_prob,
                "decision": insight_decision
            },
            "data_sensitivity": {
                "score": sensitivity_score,
                "label": sensitivity_label,
                "probabilities": sensitivity_probs
            },
            "work_category": {
                "choice": work_cat,
                "probabilities": cat_probs
            },
            "latency_ms": round(elapsed_ms, 1),
            "tokens_saved_estimate": tokens_saved,
            "model": prediction.get("model", "laya-rl-agent")
        }

        print(json.dumps(result))
    except Exception as e:
        # Fallback on any error
        result = fallback_decision(state, questions)
        result["error"] = str(e)
        print(json.dumps(result))


def fallback_decision(state, questions):
    """Deterministic rule-based fallback when Laya is unavailable."""
    state_lower = state.lower()

    # is_meaningful_work: check for work-related keywords
    work_keywords = ["code", "function", "class", "def ", "import", "func ", "var ", "let ",
                     "const ", "return", "if ", "for ", "while ", "write", "draft", "research",
                     "document", "plan", "design", "implement", "fix", "bug", "test"]
    meaningful = any(kw in state_lower for kw in work_keywords)
    meaningful_prob = 0.8 if meaningful else 0.2

    # is_discarded_insight: check for transient content
    insight_keywords = ["chat", "gpt", "claude", "assistant", "prompt", "idea", "note",
                        "todo", "draft", "unsaved", "scratchpad"]
    insight = any(kw in state_lower for kw in insight_keywords)
    insight_prob = 0.7 if insight else 0.1

    # data_sensitivity: check for secrets
    secret_patterns = ["api_key", "apikey", "password", "secret", "token", "sk-", "pk-",
                       ".env", "credentials", "private_key", "BEGIN RSA", "BEGIN OPENSSH"]
    sensitive = any(p in state_lower for p in secret_patterns)
    if sensitive:
        sensitivity_label = "secrets"
        sensitivity_score = 0.9
    elif any(kw in state_lower for kw in ["email", "phone", "ssn", "address"]):
        sensitivity_label = "sensitive"
        sensitivity_score = 0.6
    else:
        sensitivity_label = "common"
        sensitivity_score = 0.3

    # work_category
    if any(kw in state_lower for kw in ["func ", "class ", "def ", "import ", "var ", "let ", "const "]):
        work_cat = "deep_coding"
    elif any(kw in state_lower for kw in ["chat", "gpt", "claude", "research", "ai "]):
        work_cat = "ai_research"
    elif any(kw in state_lower for kw in ["doc", "plan", "readme", "notes", "write"]):
        work_cat = "docs_planning"
    else:
        work_cat = "routine_admin"

    tokens_saved = 0
    if not meaningful:
        tokens_saved += 200
    if sensitivity_label == "secrets":
        tokens_saved += 200
    if work_cat == "routine_admin":
        tokens_saved += 150

    return {
        "is_meaningful_work": {
            "probability": meaningful_prob,
            "decision": meaningful
        },
        "is_discarded_insight": {
            "probability": insight_prob,
            "decision": insight
        },
        "data_sensitivity": {
            "score": sensitivity_score,
            "label": sensitivity_label,
            "probabilities": {}
        },
        "work_category": {
            "choice": work_cat,
            "probabilities": {}
        },
        "latency_ms": 0.0,
        "tokens_saved_estimate": tokens_saved,
        "model": "fallback-rules"
    }


if __name__ == "__main__":
    main()
