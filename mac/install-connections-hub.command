#!/bin/bash
# Double-click this file in Finder. It opens Terminal and runs the installer next to it.
cd "$(dirname "$0")" || exit 1
echo
bash ./install-connections-hub.sh "$@"
echo
read -n 1 -s -r -p "Press any key to close this window..." || true
echo
