#!/usr/bin/env bash
# Line-coverage gate over the plugin's hand-written, VM-testable Dart.
#
#   flutter test --coverage test/print_error_catalog_test.dart
#   bash tool/check_coverage.sh [min-percent]   # default 85
#
# Excluded, and why: generated bridges (nitrogen output — covered by the
# browser/integration suites that exercise the real bridge), the spec
# declarations, the Flutter widget page (needs widget tests, not unit tests),
# and the conditional-import shims (one side is dead on any given platform).
set -euo pipefail

MIN=${1:-85}
LCOV=${LCOV_FILE:-coverage/lcov.info}

if [[ ! -f $LCOV ]]; then
  echo "::error::$LCOV not found — run: flutter test --coverage test/print_error_catalog_test.dart"
  exit 1
fi

EXCLUDE='lib/src/generated/|[.]g[.]dart$|/print_settings_page[.]dart$|/web_print_decor(_stub|_web)?[.]dart$|/nitro_printing[.]native[.]dart$'

report=$(awk -F: -v exclude="$EXCLUDE" '
  /^SF:/    { file = $2; hit = 0; total = 0; next }
  /^DA:/    { split($2, a, ","); total++; if (a[2] > 0) hit++; next }
  /^end_of_record/ {
    if (file !~ exclude && total > 0) {
      printf "%7.2f%%  %5d/%-5d  %s\n", 100 * hit / total, hit, total, file
      sumHit += hit; sumTotal += total
    }
    next
  }
  END { printf "TOTAL %d %d\n", sumHit, sumTotal }
' "$LCOV")

echo "$report" | grep -v '^TOTAL '
read -r _ hit total <<<"$(echo "$report" | grep '^TOTAL ')"

if [[ ${total:-0} -eq 0 ]]; then
  echo "::error::no measurable files in $LCOV — every file was excluded"
  exit 1
fi

pct=$(awk -v h="$hit" -v t="$total" 'BEGIN { printf "%.2f", 100 * h / t }')
echo "----"
echo "Coverage: $pct% ($hit/$total lines), minimum $MIN%"

if awk -v p="$pct" -v m="$MIN" 'BEGIN { exit !(p < m) }'; then
  echo "::error::coverage $pct% is below the required $MIN%"
  exit 1
fi
echo "Coverage gate passed."
