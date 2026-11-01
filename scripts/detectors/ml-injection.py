#!/usr/bin/env python3
"""ml-injection.py - `--detector` wrapper around a local ML prompt-injection classifier.

Model : protectai/deberta-v3-base-prompt-injection-v2 (DeBERTa-v3-base, ~184M params, CPU).
        Override with COMPASS_ML_MODEL=<hf-id-or-path>.

Modes (payload on stdin):
  default      one payload = all of stdin; exit 0 = clean, 1 = flagged (score >= --threshold)
  --score      one payload per LINE; prints one injection probability per line, loads the
               model once (used by `compass-redteam-external.sh --curve`)
Exit 2 = detector unavailable (missing deps or model), with a one-line hint on stderr.

Payloads longer than the model window are split into overlapping chunks and scored by the
MAX chunk probability, so an injection buried in a long tool result is not diluted away.
"""

import argparse
import os
import sys

# Calibrated 2026-11-01 on deepset/prompt-injections --split=train: the threshold with the
# highest recall at <=1% false-positive rate. Re-derive with `compass redteam --external --curve`.
THRESHOLD = 0.858741
MODEL = os.environ.get(
    "COMPASS_ML_MODEL", "protectai/deberta-v3-base-prompt-injection-v2"
)
HINT = "ml-injection: unavailable (%s); install: uv pip install torch transformers sentencepiece protobuf"


def load():
    try:
        import torch
        from transformers import AutoModelForSequenceClassification, AutoTokenizer
    except ImportError as e:
        sys.exit(_unavailable(str(e)))
    try:
        try:  # cached copy first: no network, no HF telemetry
            tok = AutoTokenizer.from_pretrained(MODEL, local_files_only=True)
            mdl = AutoModelForSequenceClassification.from_pretrained(
                MODEL, local_files_only=True
            )
        except OSError:
            tok = AutoTokenizer.from_pretrained(MODEL)
            mdl = AutoModelForSequenceClassification.from_pretrained(MODEL)
    except Exception as e:  # noqa: BLE001 - any load failure means "unavailable"
        sys.exit(_unavailable("model %s: %s" % (MODEL, e)))
    mdl.eval()
    torch.set_grad_enabled(False)
    return torch, tok, mdl


def _unavailable(why):
    print(HINT % why.splitlines()[0][:120], file=sys.stderr)
    return 2


def score(torch, tok, mdl, text):
    enc = tok(
        text,
        truncation=True,
        max_length=512,
        stride=64,
        return_overflowing_tokens=True,
        padding=True,
        return_tensors="pt",
    )
    enc.pop("overflow_to_sample_mapping", None)
    logits = mdl(**enc).logits
    return float(torch.softmax(logits, dim=-1)[:, 1].max())


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument(
        "--score", action="store_true", help="print probabilities, one payload per line"
    )
    ap.add_argument("--threshold", type=float, default=THRESHOLD)
    a = ap.parse_args()
    torch, tok, mdl = load()
    if a.score:
        for line in sys.stdin:
            print("%.6f" % score(torch, tok, mdl, line.rstrip("\n")), flush=True)
        return 0
    return 1 if score(torch, tok, mdl, sys.stdin.read()) >= a.threshold else 0


if __name__ == "__main__":
    sys.exit(main())
