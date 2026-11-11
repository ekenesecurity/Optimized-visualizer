# EVM Scope Compression Benchmark: Uniswap v3 Pool

Commercial smart contract audit firms quote scoping proposals based on **Normalized Source Lines of Code (nSLOC)**—the raw executable code lines measured by tools like `cloc` or `scc` (excluding comments and whitespace). The standard industry pricing model is simple:

$$\text{Audit Cost} = \text{Auditor Rate (\$15–\$25/nSLOC)} \times \text{Total Scope (nSLOC)}$$

When teams write Solidity, they optimize for features, readability, and gas efficiency. They rarely optimize for **scoping architecture**. Over time, duplicated internal helpers, boilerplate memory structs, and redundant state readers accumulate across files. Auditors do not discount these lines; they charge for every single one.

This repository demonstrates how systematically refactoring redundant patterns cuts billable audit lines without changing contract logic, runtime behavior, or storage layouts.

---

## The Case Study: `UniswapV3Pool.sol`

We chose `UniswapV3Pool.sol` as the benchmark because it is widely regarded as one of the most thoroughly engineered and audited contracts in the ecosystem.

Applying targeted structural deduplication to this file yields the following measured metrics via `scc`:

| Metric | Original (`UniswapV3Pool.sol`) | Optimized (`OptimizedUniswapV3Pool.sol`) | Delta | Audit Savings (@ $15/nSLOC) |
| --- | --- | --- | --- | --- |
| **Executable nSLOC** | **649** | **510** | **-139 lines (-21.4%)** | **$2,085 saved** |
| **Gross Lines** | 874 | 609 | -265 lines (-30.3%) | — |
| **Cyclomatic Complexity** | 96 | 83 | -13 (-13.5%) | Lower audit friction |

Cutting **139 billable lines** from a single core contract saves over **$2,000** on that file alone. Across a typical 4,000–6,000 line DeFi codebase, the same 15%–25% reduction removes thousands of dollars in scoping bloat before you sign an audit agreement.

---

## What Was Refactored (Zero Logic Changes)

None of the mathematical formulas, external ABIs, or state transitions were modified. The reduction comes strictly from removing internal repetition:

* **Unified Token Balance Queries (-8 nSLOC):** Replaced separate `balance0()` and `balance1()` staticcall routines with a single internal `_balance(address token)` helper.
* **Internal Sign Resolution in `_modifyPosition` (-22 nSLOC):** Removed the intermediate memory struct `ModifyPositionParams` and moved positive/negative delta resolution inside `_modifyPosition`, eliminating repetitive sign-casting in `mint()` and `burn()`.
* **Consolidated Tick Storage Reads (-18 nSLOC):** Extracted identical multi-variable storage unpacking and initialization assertions in `snapshotCumulativesInside` into a single helper.
* **Flattened Control Flow (-14 nSLOC):** Replaced deeply nested `if/else if/else` ladders with early returns on boundary conditions.
* **Deduplicated Tick Transitions (-14 nSLOC):** Unified lower-tick and upper-tick updates and bitmap flips into a single internal method.
* **Reusable Protocol Fee Math (-12 nSLOC):** Consolidated duplicated fee division, truncation, and accumulator logic across flash loans and protocol fee collections.

---

## Parity Guarantee: Foundry Differential Testing

To prove that the optimized file behaves identically to the original in all conditions, `test/differential/PoolDifferential.t.sol` executes side-by-side differential tests:

1. **State Transitions & Return Values:** Runs identical operations (`mint`, `swap`, `burn`, `collect`, `flash`) on both contracts and asserts matching outputs at every step.
2. **Callback Compatibility:** Both contracts trigger standard mint, swap, and flash callbacks with exact parameter parity.
3. **Storage Slot Verification (`vm.load`):** Inspects raw EVM storage slots after execution to guarantee bit-for-bit parity:
* **Slot 0:** `Slot0` struct (`sqrtPriceX96`, `tick`, `observationIndex`, `unlocked`)
* **Slot 1:** `feeGrowthGlobal0X128`
* **Slot 2:** `feeGrowthGlobal1X128`
* **Slot 3:** `protocolFees`
* **Slot 4:** `liquidity`



---

## How to Verify Locally

You can verify the line counts and differential parity on your machine in under two minutes.

### Prerequisites

* [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`)
* [scc](https://github.com/boyter/scc) (`brew install scc` on macOS, or download binary)
* [Node.js](https://nodejs.org/) (v16+)

### Verification Steps

```bash
# 1. Clone the repository
git clone https://github.com/YOUR_ORG/evm-sloc-compression-demo.git
cd evm-sloc-compression-demo

# 2. Run the cross-platform benchmark script
npm run benchmark

```

The script will automatically parse the exact line counts using `scc`, calculate the net savings table, and run `forge test` against both pools.

### Running Forge Tests Directly

To run only the parity verification test suite without the benchmark script:

```bash
forge test --match-contract PoolDifferentialTest -vv

```

---

## Verifying in Browser (No Local Setup)

If you don't have Foundry installed:

1. Click on the **[suspicious link removed]** tab at the top of this repository.
2. Select the latest run under **Scope Compression Benchmark & Differential Parity**.
3. Open the **Summary** page to view the live comparison table and test pass outputs generated directly on Ubuntu CI runners.