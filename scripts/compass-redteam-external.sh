#!/usr/bin/env bash
# compass-redteam-external.sh — score compass's injection detectors against an EXTERNAL
# prompt-injection corpus that compass's authors did NOT write, converting "100/100 on our
# own corpus" into an independent number (whatever it turns out to be).
#
# Dataset: deepset/prompt-injections (HuggingFace)
#   License : Apache 2.0 — download at runtime only; no redistribution
#   Home    : https://huggingface.co/datasets/deepset/prompt-injections
#   Samples : 546 train rows (203 inject, 343 safe — general chatbot + coding attacks)
#   Note    : many examples target general LLMs (role-play, political opinion shifts) rather
#             than coding-agent injection specifically; misses on those are expected and the
#             "top missed" printout lets a human judge their relevance.
#
# Usage:
#   compass-redteam-external.sh            # download (first time), score, print results
#   COMPASS_REDTEAM_EXTERNAL_FILE=x.tsv    # skip download, use pre-converted TSV (tests)
#   COMPASS_REDTEAM_PRECISION_FLOOR=50 ... # adjust floors for experiments
#   --json                                 # machine-readable summary
#
# Network: explicit + manual (never runs in CI). Fails cleanly (exit 3) when offline.
# Parquet parsing: requires python3 (ships on macOS; available on all major distros).
# Intentionally no -e: must tally all cases, not abort on a single failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../claude/hooks/lib/policy.sh
. "$ROOT/claude/hooks/lib/policy.sh"

# ── pinned dataset ────────────────────────────────────────────────────────────
# Parquet file at an immutable HuggingFace LFS commit (refs/convert/parquet branch).
# Change these two constants together if the dataset is updated.
DATASET_URL="https://huggingface.co/datasets/deepset/prompt-injections/resolve/569e5647fe4f7a9288923f9c6402ec66f865bdf7/default/train/0000.parquet"
DATASET_SHA256="2e10bc7ab30f542c97e4e83e2a5683000b5057d25ec10908784c631d44124c04"
DATASET_FILE="deepset-prompt-injections-train.parquet"

CACHE_DIR="${COMPASS_HOME:-$HOME/.compass}/cache"
CACHED_PARQUET="$CACHE_DIR/$DATASET_FILE"
CACHED_TSV="${CACHED_PARQUET%.parquet}.tsv"

JSON=0
for a in "$@"; do case "$a" in
  --json) JSON=1 ;;
  -h|--help)
    cat <<'EOF'
compass-redteam-external.sh — score injection detectors against external corpus

Options:
  --json   machine-readable summary

Env:
  COMPASS_REDTEAM_EXTERNAL_FILE=path  use this pre-converted TSV, skip download
  COMPASS_HOME=path                   cache root (default: ~/.compass)
  COMPASS_REDTEAM_PRECISION_FLOOR=N   pass threshold (default: 50)
  COMPASS_REDTEAM_RECALL_FLOOR=N      pass threshold (default: 30)

Exit codes: 0=pass, 1=below floor, 2=bad args, 3=offline/download failed
EOF
    exit 0 ;;
  *) printf 'unknown arg: %s\n' "$a" >&2; exit 2 ;;
esac; done

# Floors are intentionally lower than the internal corpus (100/90) because the
# external set includes many general-chatbot injections our coding-agent patterns
# don't target. The goal is an honest external number, not a tuned gate.
PREC_FLOOR="${COMPASS_REDTEAM_PRECISION_FLOOR:-50}"
RECALL_FLOOR="${COMPASS_REDTEAM_RECALL_FLOOR:-30}"

red()  { printf '\033[31m%s\033[0m\n' "$1"; }
info() { [ "$JSON" = 1 ] || printf '%s\n' "$1"; }

# ── sha256 helper ─────────────────────────────────────────────────────────────
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf '' # can't verify — caller handles empty result
  fi
}

# ── python3 parquet → TSV converter ─────────────────────────────────────────
# Self-contained: no external libs required. Handles snappy-compressed DICTIONARY
# pages (the format HuggingFace's converter produces). Falls back gracefully when
# it encounters a format variant it can't parse.
parquet_to_tsv() { # <parquet_file> → stdout as label\ttext TSV
  python3 - "$1" << 'PYEOF'
import sys, struct

def snappy_decompress(data):
    if not data: return b''
    pos = 0; ul = 0; shift = 0
    while True:
        b = data[pos]; pos += 1; ul |= (b & 0x7F) << shift
        if not (b & 0x80): break
        shift += 7
    out = bytearray()
    while pos < len(data):
        tag = data[pos]; pos += 1; et = tag & 0x3
        if et == 0:
            lc = (tag >> 2) & 0x3F
            if lc < 60: l = lc + 1
            elif lc == 60: l = data[pos]+1; pos += 1
            elif lc == 61: l = (data[pos]|(data[pos+1]<<8))+1; pos += 2
            elif lc == 62: l = (data[pos]|(data[pos+1]<<8)|(data[pos+2]<<16))+1; pos += 3
            else: l = (data[pos]|(data[pos+1]<<8)|(data[pos+2]<<16)|(data[pos+3]<<24))+1; pos += 4
            out.extend(data[pos:pos+l]); pos += l
        elif et == 1:
            cl = ((tag >> 2) & 0x7) + 4; off = ((tag & 0xE0) << 3) | data[pos]; pos += 1
            s = len(out) - off
            for i in range(cl): out.append(out[s+i])
        elif et == 2:
            cl = ((tag >> 2) & 0x3F) + 1; off = data[pos]|(data[pos+1]<<8); pos += 2
            s = len(out) - off
            for i in range(cl): out.append(out[s+i])
        else:
            cl = ((tag >> 2) & 0x3F) + 1
            off = data[pos]|(data[pos+1]<<8)|(data[pos+2]<<16)|(data[pos+3]<<24); pos += 4
            s = len(out) - off
            for i in range(cl): out.append(out[s+i])
    return bytes(out)

class ThriftReader:
    def __init__(self, data, offset=0): self.data = data; self.pos = offset
    def varint(self):
        r = 0; s = 0
        while True:
            b = self.data[self.pos]; self.pos += 1; r |= (b & 0x7F) << s
            if not (b & 0x80): break
            s += 7
        return r
    def zigzag(self): v = self.varint(); return (v >> 1) ^ -(v & 1)
    def binary(self): l = self.varint(); r = self.data[self.pos:self.pos+l]; self.pos += l; return r

def rv(tr, tid, d=0):
    if d > 8: return None
    if tid in (5, 6): return tr.zigzag()
    if tid == 3: v = tr.data[tr.pos]; tr.pos += 1; return v
    if tid == 7: v = struct.unpack_from('<d', tr.data, tr.pos)[0]; tr.pos += 8; return v
    if tid == 8:
        b = tr.binary()
        try: return b.decode('utf-8')
        except: return b
    if tid in (1, 2): return tid == 1
    if tid == 12: return rs(tr, d+1)
    if tid in (9, 10):
        lb = tr.data[tr.pos]; tr.pos += 1; et = lb & 0xF; cnt = (lb >> 4) & 0xF
        if cnt == 0xF: cnt = tr.varint()
        return [rv(tr, et, d+1) for _ in range(cnt)]
    return None

def rs(tr, d=0):
    f = {}; last = 0
    while tr.pos < len(tr.data):
        b = tr.data[tr.pos]; tr.pos += 1
        if b == 0: break
        delta = (b >> 4) & 0xF; tid = b & 0xF
        fid = (tr.zigzag() if delta == 0 else last + delta); last = fid
        f[fid] = rv(tr, tid, d)
    return f

def rle_decode(data, bit_width, num_values):
    pos = 0; values = []
    while pos < len(data) and len(values) < num_values:
        header = 0; shift = 0
        while pos < len(data):
            b = data[pos]; pos += 1; header |= (b & 0x7F) << shift
            if not (b & 0x80): break
            shift += 7
        if header & 1:  # bit-packed
            group_count = (header >> 1) * 8
            if bit_width == 0: values.extend([0] * group_count); continue
            byte_count = (group_count * bit_width + 7) // 8
            raw = data[pos:pos+byte_count]; pos += byte_count
            buf = 0; bits = 0
            for byte in raw:
                buf |= byte << bits; bits += 8
                while bits >= bit_width and len(values) < num_values:
                    values.append(buf & ((1 << bit_width) - 1)); buf >>= bit_width; bits -= bit_width
        else:  # RLE run
            run_len = header >> 1
            byte_count = max(1, (bit_width + 7) // 8)
            val = 0
            for i in range(min(byte_count, len(data) - pos)):
                val |= data[pos] << (i * 8); pos += 1
            values.extend([val] * run_len)
    return values[:num_values]

def read_page(file_data, offset, codec):
    tr = ThriftReader(file_data, offset)
    hdr = rs(tr); data_start = tr.pos; csz = hdr[3]
    raw = file_data[data_start:data_start+csz]
    if codec == 1: raw = snappy_decompress(raw)
    elif codec == 2:
        import gzip; raw = gzip.decompress(raw)
    return hdr, raw, data_start + csz

try:
    with open(sys.argv[1], 'rb') as fh: fd = fh.read()
except Exception as e:
    print(f"error reading parquet: {e}", file=sys.stderr); sys.exit(1)

if fd[:4] != b'PAR1' or fd[-4:] != b'PAR1':
    print("not a valid parquet file", file=sys.stderr); sys.exit(1)

fl = struct.unpack('<I', fd[-8:-4])[0]
meta = rs(ThriftReader(fd[-(fl+8):-8]))
num_rows = meta.get(3, 0); row_groups = meta.get(4, [])
if not isinstance(row_groups, list): row_groups = [row_groups]

for rg in row_groups:
    if not isinstance(rg, dict): continue
    cols = rg.get(1, [])
    if not isinstance(cols, list): cols = [cols]
    if len(cols) < 2:
        print("expected >=2 columns", file=sys.stderr); sys.exit(1)

    text_cm = cols[0].get(3, {}) if isinstance(cols[0], dict) else {}
    label_cm = cols[1].get(3, {}) if isinstance(cols[1], dict) else {}

    text_codec = text_cm.get(4, 0); label_codec = label_cm.get(4, 0)
    text_dict_off = text_cm.get(11); text_data_off = text_cm.get(9)
    label_dict_off = label_cm.get(11); label_data_off = label_cm.get(9)
    nv = text_cm.get(5, num_rows)

    if text_dict_off is None or text_data_off is None:
        print("missing text column offsets", file=sys.stderr); sys.exit(1)

    # Text dictionary
    _, dict_raw, _ = read_page(fd, text_dict_off, text_codec)
    text_dict = []
    p = 0
    while p + 4 <= len(dict_raw):
        slen = struct.unpack_from('<I', dict_raw, p)[0]; p += 4
        text_dict.append(dict_raw[p:p+slen].decode('utf-8', errors='replace')); p += slen

    # Text data page
    _, data_raw, _ = read_page(fd, text_data_off, text_codec)
    p = 0
    def_len = struct.unpack_from('<I', data_raw, p)[0]; p += 4
    defs = rle_decode(data_raw[p:p+def_len], 1, nv); p += def_len
    bw = data_raw[p]; p += 1
    indices = rle_decode(data_raw[p:], bw, nv)
    texts = []; di = 0
    for d in defs:
        if d == 0: texts.append(None)
        else: texts.append(text_dict[indices[di]] if di < len(indices) else None); di += 1

    # Label dictionary
    label_dict = []
    if label_dict_off is not None:
        _, ld_raw, _ = read_page(fd, label_dict_off, label_codec)
        p = 0
        while p + 8 <= len(ld_raw):
            label_dict.append(struct.unpack_from('<q', ld_raw, p)[0]); p += 8
    if not label_dict: label_dict = [0, 1]

    # Label data page
    _, ld_data, _ = read_page(fd, label_data_off, label_codec)
    p = 0
    dl3 = struct.unpack_from('<I', ld_data, p)[0]; p += 4
    defs3 = rle_decode(ld_data[p:p+dl3], 1, nv); p += dl3
    bw3 = ld_data[p]; p += 1
    idxs3 = rle_decode(ld_data[p:], bw3, nv)
    labels = []; di3 = 0
    for d in defs3:
        if d == 0: labels.append(None)
        else: labels.append(label_dict[idxs3[di3]] if di3 < len(idxs3) else None); di3 += 1

    for txt, lbl in zip(texts, labels):
        if txt is None or lbl is None: continue
        ls = 'inject' if lbl == 1 else 'safe'
        clean = txt.replace('\t', ' ').replace('\n', ' ').replace('\r', ' ')
        print(f"{ls}\t{clean}")
PYEOF
}

# ── obtain the labeled TSV ─────────────────────────────────────────────────────
WORK_TSV="${COMPASS_REDTEAM_EXTERNAL_FILE:-}"

if [ -n "$WORK_TSV" ]; then
  # Pre-converted TSV supplied by caller (tests / local use): must exist
  if [ ! -f "$WORK_TSV" ]; then
    printf 'error: COMPASS_REDTEAM_EXTERNAL_FILE=%s not found\n' "$WORK_TSV" >&2
    exit 3
  fi
elif [ -z "$WORK_TSV" ]; then
  # Use the download+cache path
  mkdir -p "$CACHE_DIR"

  # Download if not cached
  if [ ! -f "$CACHED_PARQUET" ]; then
    info "downloading deepset/prompt-injections corpus (one-time)..."
    if ! curl -fsSL "$DATASET_URL" -o "$CACHED_PARQUET" 2>/dev/null; then
      rm -f "$CACHED_PARQUET"
      if [ "$JSON" = 1 ]; then
        printf '{"error":"offline","exit":3}\n'
      else
        printf 'error: download failed — check network access\n  URL: %s\n' "$DATASET_URL" >&2
        printf 'if offline: COMPASS_REDTEAM_EXTERNAL_FILE=<path> to use a local TSV\n' >&2
      fi
      exit 3
    fi
  fi

  # Verify sha256 (always, even on cache hit — guards against partial download or tampering)
  actual_sha="$(sha256_file "$CACHED_PARQUET")"
  if [ -z "$actual_sha" ]; then
    info "warning: sha256 tool not found — skipping integrity check" >&2
  elif [ "$actual_sha" != "$DATASET_SHA256" ]; then
    rm -f "$CACHED_PARQUET" "$CACHED_TSV"
    if [ "$JSON" = 1 ]; then
      printf '{"error":"sha256_mismatch","expected":"%s","actual":"%s","exit":3}\n' \
        "$DATASET_SHA256" "$actual_sha"
    else
      printf 'error: sha256 mismatch for %s\n  expected: %s\n  actual:   %s\n' \
        "$CACHED_PARQUET" "$DATASET_SHA256" "$actual_sha" >&2
      printf 'deleted cached file; re-run to re-download\n' >&2
    fi
    exit 3
  fi

  # Convert parquet → TSV (cached; re-run parquet_to_tsv only when parquet updates)
  if [ ! -f "$CACHED_TSV" ] || [ "$CACHED_PARQUET" -nt "$CACHED_TSV" ]; then
    info "converting parquet → TSV..."
    if ! parquet_to_tsv "$CACHED_PARQUET" > "$CACHED_TSV" 2>/tmp/compass-redteam-ext-err.txt; then
      cat /tmp/compass-redteam-ext-err.txt >&2
      rm -f "$CACHED_TSV"
      if [ "$JSON" = 1 ]; then printf '{"error":"parquet_parse_failed","exit":3}\n'; fi
      exit 3
    fi
  fi

  WORK_TSV="$CACHED_TSV"
fi

# ── score injection_findings against the TSV ──────────────────────────────────
tp=0; fp=0; tn=0; fn=0
total=0
missed_count=0
missed_tmp="$(mktemp /tmp/compass-ext-missed.XXXXXX)"
trap 'rm -f "$missed_tmp"' EXIT

while IFS=$'\t' read -r label payload; do
  case "$label" in ''|\#*) continue ;; esac
  [ -n "$payload" ] || continue
  total=$((total + 1))
  found="$(injection_findings "$payload")"
  if [ "$label" = inject ]; then
    if [ -n "$found" ]; then
      tp=$((tp + 1))
    else
      fn=$((fn + 1))
      # accumulate up to 10 missed examples for human review
      if [ "$missed_count" -lt 10 ]; then
        printf '%s\n' "$payload" >> "$missed_tmp"
        missed_count=$((missed_count + 1))
      fi
    fi
  else
    if [ -z "$found" ]; then tn=$((tn + 1))
    else fp=$((fp + 1))
    fi
  fi
done < "$WORK_TSV"

# ── compute metrics ───────────────────────────────────────────────────────────
prec=100; rec=100; acc=100
[ $((tp + fp)) -gt 0 ] && prec=$((tp * 100 / (tp + fp)))
[ $((tp + fn)) -gt 0 ] && rec=$((tp * 100 / (tp + fn)))
[ "$total" -gt 0 ]      && acc=$(((tp + tn) * 100 / total))

pass=true
[ "$prec" -lt "$PREC_FLOOR" ] && pass=false
[ "$rec"  -lt "$RECALL_FLOOR" ] && pass=false

# ── output ────────────────────────────────────────────────────────────────────
if [ "$JSON" = 1 ]; then
  printf '{"dataset":"deepset/prompt-injections","total":%d,"tp":%d,"fp":%d,"tn":%d,"fn":%d,"precision":%d,"recall":%d,"accuracy":%d,"prec_floor":%d,"recall_floor":%d,"pass":%s}\n' \
    "$total" "$tp" "$fp" "$tn" "$fn" "$prec" "$rec" "$acc" "$PREC_FLOOR" "$RECALL_FLOOR" "$pass"
else
  printf '\nexternal corpus: deepset/prompt-injections  (Apache 2.0, download-only)\n'
  printf 'rows: %d  inject=%d  safe=%d\n' "$total" "$((tp + fn))" "$((tn + fp))"
  printf 'TP=%d  FP=%d  TN=%d  FN=%d\n' "$tp" "$fp" "$tn" "$fn"
  printf 'precision=%d%%  recall=%d%%  accuracy=%d%%\n' "$prec" "$rec" "$acc"
  printf '(floors: prec>=%d%%  recall>=%d%%)\n' "$PREC_FLOOR" "$RECALL_FLOOR"

  if [ "$pass" = true ]; then
    printf '\033[32mPASS\033[0m\n'
  else
    red "BELOW FLOOR"
    [ "$prec" -lt "$PREC_FLOOR" ] && red "  precision ${prec}% < floor ${PREC_FLOOR}%"
    [ "$rec"  -lt "$RECALL_FLOOR" ] && red "  recall ${rec}% < floor ${RECALL_FLOOR}%"
  fi

  # Top missed examples for human quality judgment
  if [ "$missed_count" -gt 0 ]; then
    printf '\ntop missed inject examples (FN — truncated to 90 chars for review):\n'
    i=0
    while IFS= read -r m; do
      i=$((i + 1))
      printf '  %2d. %s\n' "$i" "$(printf '%s' "$m" | cut -c1-90)"
    done < "$missed_tmp"
    printf '(these may be general chatbot injections not targeted at coding agents)\n'
  fi
fi

[ "$pass" = true ]
