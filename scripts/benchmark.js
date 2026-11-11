#!/usr/bin/env node

const { execSync } = require('child_process');
const path = require('path');
const fs = require('fs');

const RATE_PER_LOC = 15; // Industry average $15/nSLOC

function runCommand(cmd) {
    try {
        return execSync(cmd, { stdio: 'pipe' }).toString();
    } catch (error) {
        if (error.stdout) return error.stdout.toString();
        throw error;
    }
}

function checkTool(name, checkCmd, installGuide) {
    try {
        execSync(checkCmd, { stdio: 'ignore' });
    } catch {
        console.error(`\x1b[31m[Error] '${name}' is not installed or not in your PATH.\x1b[0m`);
        console.error(`Please install it: ${installGuide}\n`);
        process.exit(1);
    }
}

// 1. Tool verification
checkTool('forge', 'forge --version', 'https://book.getfoundry.sh/getting-started/installation');
checkTool('scc', 'scc --version', 'macOS: brew install scc | Windows: scoop install scc or choco install scc');

// Cross-platform paths using path.join
const originalPath = path.join('src', 'original', 'UniswapV3Pool.sol');
const optimizedPath = path.join('src', 'optimized', 'OptimizedUniswapV3Pool.sol');

if (!fs.existsSync(originalPath) || !fs.existsSync(optimizedPath)) {
    console.error('\x1b[31m[Error] Target contract files not found at expected paths.\x1b[0m');
    process.exit(1);
}

console.log('\n======================================================');
console.log('       SOLIDITY SCOPE COMPRESSION BENCHMARK           ');
console.log('======================================================\n');

// 2. Parse SCC metrics via JSON format (OS-agnostic parsing)
const originalJson = JSON.parse(runCommand(`scc --format json "${originalPath}"`));
const optimizedJson = JSON.parse(runCommand(`scc --format json "${optimizedPath}"`));

const origCode = originalJson[0].Code;
const origLines = originalJson[0].Lines;
const origComplexity = originalJson[0].Complexity;

const optCode = optimizedJson[0].Code;
const optLines = optimizedJson[0].Lines;
const optComplexity = optimizedJson[0].Complexity;

const codeSaved = origCode - optCode;
const codeReduction = ((codeSaved / origCode) * 100).toFixed(2);
const moneySaved = codeSaved * RATE_PER_LOC;

// 3. Display Scoping Table
console.log(`Reference File : ${originalPath}`);
console.log(`Optimized File : ${optimizedPath}\n`);

console.table([
    {
        Metric: 'Billable nSLOC (Code)',
        Original: origCode,
        Optimized: optCode,
        Reduction: `-${codeSaved} (-${codeReduction}%)`,
        'Value Saved (@ $15/SLOC)': `$${moneySaved.toLocaleString()}`
    },
    {
        Metric: 'Total File Lines',
        Original: origLines,
        Optimized: optLines,
        Reduction: `-${origLines - optLines}`,
        'Value Saved (@ $15/SLOC)': `$${((origLines - optLines) * RATE_PER_LOC).toLocaleString()}`
    },
    {
        Metric: 'Complexity Score',
        Original: origComplexity,
        Optimized: optComplexity,
        Reduction: `-${origComplexity - optComplexity}`,
        'Value Saved (@ $15/SLOC)': 'Reduced Audit Cognitive Load'
    }
]);

// 4. Run Forge Differential Test
console.log('Running Forge Differential Verification...\n');
try {
    const forgeOutput = execSync('forge test --match-contract PoolDifferentialTest -vv', {
        stdio: 'inherit'
    });
    console.log('\n\x1b[32m✔ Differential Equivalence Verified: All state transitions match bit-for-bit.\x1b[0m\n');
} catch {
    console.error('\n\x1b[31m✘ Differential Tests Failed: State mismatch detected.\x1b[0m\n');
    process.exit(1);
}