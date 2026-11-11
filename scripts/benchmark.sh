#!/usr/bin/env bash
set -u

ORIG="src/original/UniswapV3Pool.sol"
OPT="src/optimized/OptimizedUniswapV3Pool.sol"

if ! command -v scc >/dev/null 2>&1; then
  echo "Missing required dependency: scc"
  exit 1
fi

if ! command -v forge >/dev/null 2>&1; then
  echo "Missing required dependency: forge"
  exit 1
fi

scc_output=$(scc --by-file --no-cocomo "$ORIG" "$OPT")
printf '%s\n\n' "$scc_output"

orig_code=$(printf '%s\n' "$scc_output" | awk '/~original\/UniswapV3Pool\.sol/ {print $5}')
opt_code=$(printf '%s\n' "$scc_output" | awk '/~OptimizedUniswapV3Pool\.sol/ {print $5}')

if [[ -z "$orig_code" || -z "$opt_code" ]]; then
  echo "Unable to parse nSLOC values from scc output."
  exit 1
fi

orig_code=${orig_code//,/}
opt_code=${opt_code//,/}

reduction_pct=$(python3 - "$orig_code" "$opt_code" <<'PY'
import sys
orig = int(sys.argv[1])
opt = int(sys.argv[2])
print(f"{((orig - opt) / orig) * 100:.2f}")
PY
)

savings=$(python3 - "$orig_code" "$opt_code" <<'PY'
import sys
orig = int(sys.argv[1])
opt = int(sys.argv[2])
print(f"{(orig - opt) * 15:.2f}")
PY
)

echo "Original nSLOC: $orig_code"
echo "Optimized nSLOC: $opt_code"
echo "Line reduction: ${reduction_pct}%"
echo "Estimated audit savings: \$${savings}"

echo "\nRunning differential verification..."
if forge test --match-contract PoolDifferentialTest -vv; then
  echo "Differential equivalence: PASS"
else
  echo "Differential equivalence: FAIL"
  exit 1
fi
