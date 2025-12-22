# Foundry Invariant Testing & Fuzzing Guide

## Overview

Invariant testing (also called property-based testing or fuzzing) is a powerful testing technique that automatically generates random inputs to verify that certain properties of your smart contract always hold true, no matter what sequence of operations is performed.

## What are Invariants?

Invariants are properties that should **always be true** regardless of how the contract is used. They represent the core business logic guarantees of your system.

### Example Invariants for DSC Protocol

1. **Collateral Value Invariant**: The total value of collateral deposited in the protocol must always be greater than or equal to the total supply of DSC tokens minted.

    ```
    Total Collateral Value (USD) >= Total DSC Supply
    ```

2. **Getter Functions Invariant**: All view/getter functions should never revert (evergreen invariant).
    ```
    All external view functions should execute successfully without reverting
    ```

## Configuration Setup

### foundry.toml Configuration

```toml
[invariant]
runs = 128
depth = 128
fail_ob_revert = false
```

**Parameter Explanations:**

-   **runs = 128**: Number of separate fuzzing campaigns to execute. Each run generates a new random sequence of function calls. Higher values provide more thorough testing but take longer.

-   **depth = 128**: Maximum number of consecutive function calls per fuzzing run. This controls the complexity of the call sequence. A depth of 128 means up to 128 chained operations in a single test.

-   **fail_ob_revert = false**: When set to false, test failures caused by contract reverts don't stop the fuzzing campaign. The fuzzer continues attempting different sequences even after encountering reverted transactions, allowing it to discover edge cases that wouldn't be caught with normal transaction execution.

## Implementation Example: DSC Protocol

### Test Contract Structure

```solidity
import {StdInvariant} from "forge-std/StdInvariant.sol";

contract OpenInvariantsTest is StdInvariant, Test {
    DSCEngine dscEngine;
    DSC dsc;

    function setUp() external {
        // Deploy contracts and set up initial state
        targetContract(address(dscEngine));
    }

    function invariant_functionName() public view {
        // Assert property that should always hold true
    }
}
```

### Key Components

**1. Inherit from StdInvariant**

```solidity
contract OpenInvariantsTest is StdInvariant, Test
```

This provides the fuzzing framework and utilities.

**2. Set Target Contract**

```solidity
function setUp() external {
    targetContract(address(dscEngine));
}
```

Tells Foundry which contract to fuzz by randomly calling its public/external functions.

**3. Define Invariant Functions**
Invariant functions must:

-   Start with prefix `invariant_`
-   Be public or external
-   Contain assertions that must always be true
-   Not modify state (view functions preferred)

### Real Example: DSC Protocol Invariant

```solidity
function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
    uint256 totalSupply = dsc.totalSupply();
    uint256 totalwETHDeposited = IERC20(wETH).balanceOf(address(dscEngine));
    uint256 totalwBTCDeposited = IERC20(wBTC).balanceOf(address(dscEngine));

    uint256 wETHValue = dscEngine.getUsdValue(wETH, totalwETHDeposited);
    uint256 wBTCValue = dscEngine.getUsdValue(wBTC, totalwBTCDeposited);

    assert(wETHValue + wBTCValue >= totalSupply);
}
```

**How It Works:**

1. Foundry randomly calls DSCEngine's functions 128 times (runs) with up to 128 operations each (depth)
2. After each fuzzing campaign, the invariant function is called
3. If the assertion fails, Foundry displays the sequence of operations that broke the invariant
4. If all assertions pass across all runs, the invariant is verified

## Running Invariant Tests

```bash
# Run all invariant tests
forge test --match-contract OpenInvariantsTest

# Run with verbose output to see fuzzing details
forge test --match-contract OpenInvariantsTest -vvv

# Run with specific number of runs (override foundry.toml)
forge test --match-contract OpenInvariantsTest --invariant-runs 256
```

## Benefits of Invariant Testing

-   **Automated Edge Case Discovery**: Finds scenarios you might not think to test manually
-   **Comprehensive Coverage**: Tests complex interaction sequences automatically
-   **Regression Prevention**: Catches unexpected behavior when modifying code
-   **Business Logic Validation**: Verifies core protocol guarantees hold under all conditions
-   **Security**: Helps identify vulnerability patterns in contract state management

## Best Practices

1. **Design Clear Invariants**: Invariants should represent critical business properties, not implementation details

2. **Keep Invariants Simple**: Each invariant should test one specific property to make debugging easier

3. **Use Appropriate Assertions**: Ensure assertions accurately reflect your invariant

4. **Increase Runs for Critical Systems**: For high-value protocols, use higher `runs` values (256-1000+)

5. **Combine with Unit Tests**: Use unit tests for specific scenarios and invariants for general properties

6. **Log State Changes**: Use `console.log()` to understand what the fuzzer is doing and identify patterns in failures

## Common Pitfalls

-   **Invariants That Are Too Strict**: May fail on valid edge cases
-   **Non-Deterministic Behavior**: Randomness in contract logic can cause intermittent failures
-   **Ignoring Revert Cases**: Setting `fail_ob_revert = true` might hide important bugs
-   **Insufficient Runs**: Too few runs may miss rare edge cases

## Conclusion

Invariant testing is a critical tool for ensuring smart contract security and correctness. By defining clear properties that should always hold true and letting Foundry's fuzzer discover edge cases, you can significantly increase confidence in your protocol's robustness.
