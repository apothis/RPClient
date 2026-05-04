#!/bin/bash
# Stop hook: runs the test suite when Claude tries to finish.
# - On failure: exits 2 so Claude sees the output and is forced to fix.
# - On success: exits 0 silently.
# - Honors stop_hook_active to avoid infinite loops.

set -u

INPUT=$(cat)
ACTIVE=$(printf '%s' "$INPUT" | /usr/bin/python3 -c \
    "import json,sys
try: print(json.load(sys.stdin).get('stop_hook_active', False))
except Exception: print(False)" 2>/dev/null)

if [ "$ACTIVE" = "True" ]; then
    exit 0
fi

PROJECT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT" || exit 0

# Skip if Package.swift is absent (project not yet set up for tests).
[ -f Package.swift ] || exit 0

OUTPUT=$(swift run RPClientCoreTests 2>&1)
EXIT=$?

if [ $EXIT -ne 0 ]; then
    {
        echo "Stop hook: RPClientCoreTests failed. Fix the regression (or update the tests if the behavior change was intentional) before finishing."
        echo "----- test output -----"
        echo "$OUTPUT"
    } >&2
    exit 2
fi

# Tests pass. Reminder: if this session added new logic in Sources/RPClientCore/
# (especially under Memory/, PromptBuilder, Templates*, Storage), confirm new test
# cases were added in Tests/RPClientCoreTests/. The hook can't tell whether you
# added tests, only whether the existing ones still pass.
exit 0
