#!/bin/bash
# Fetches the third-party burn-mode tooling at the commits this project was developed with.
set -eu
cd "$(dirname "$0")"
clone() { [ -d "$2/.git" ] || git clone -q "$1" "$2"; git -C "$2" checkout -q "$3"; echo "$2 @ $3"; }
clone https://github.com/superna9999/pyamlboot pyaml d2857f4371bcdb7a90d885f24987e03b6d647a8a   # python USB loader (stage1.py)
clone https://github.com/khadas/utils khadas 65e3fb146f438ec2c79dce5a2b87790798ca475d           # prebuilt `update` tool (aml-flash-tool)
