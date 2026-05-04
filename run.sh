#!/bin/bash
# Dev launcher: runs the binary directly to bypass Launch Services'
# Local Network privacy enforcement (which re-prompts every rebuild
# under ad-hoc signing). For "real" launches via Finder, sign with a
# stable cert (see build.sh notes).
set -e
exec ./RPClient.app/Contents/MacOS/RPClient
