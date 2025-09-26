# Solidity Precision Loss Mitigation: Complete Reference Guide

**NOTE: THIS IS ONLY WORTH IT FOR LOW PRECISION TOKENS. LIKE USDC, 6dp.**
**FOR STANDARD 18DP TOKENS, IGNORE.**

## Table of Contents
1. [Introduction](#introduction)
2. [Understanding Precision Loss](#understanding-precision-loss)
3. [Core Patterns](#core-patterns)
4. [Decision Framework](#decision-framework)
5. [Implementation Templates](#implementation-templates)
6. [Testing Strategies](#testing-strategies)
7. [Best Practices](#best-practices)
8. [Common Use Cases](#common-use-cases)

## Introduction

Precision loss in Solidity arithmetic is a systemic issue affecting any contract performing multiplication followed by division. This document provides comprehensive strategies for mitigating precision loss while maintaining gas efficiency and code clarity.

**When to Use This Guide:**
- Calculating percentages, fees, or ratios
- Token conversions and swaps
- Reward distributions
- Financial calculations
- Any `(a * b) / c` operations

## Understanding Precision Loss

### The Fundamental Problem

Solidity uses integer arithmetic exclusively. When performing `(a * b) / c`, the division truncates fractional parts:

```solidity
// Example: 1000 * 333 / 10000 = 333300 / 10000 = 33 (should be 33.33)
uint256 result = 1000 * 333 / 10000; // result = 33, lost 0.33
```

### Impact Scenarios

1. **Small Amount Calculations**: High percentage loss
2. **Repeated Operations**: Cumulative error accumulation
3. **High-Precision Requirements**: Financial accuracy critical
4. **Fee Calculations**: User trust and fairness issues
5. **Token Conversions**: Exchange rate precision loss

### Mathematical Analysis

For operation `(a * b) / c`:
- **Maximum error**: `c - 1` units
- **Relative error**: `(c - 1) / (a * b / c)`
- **Error frequency**: Every operation where `(a * b) % c != 0`

## Core Patterns

### Pattern 1: Round-to-Nearest

**Use Case**: Fair rounding for general calculations

```solidity
function mulDivRoundNearest(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
    uint256 product = a * b;
    uint256 result = product / c;
    uint256 remainder = product % c;
    
    // Round up if remainder >= 50% of divisor
    if (remainder >= c / 2) {
        result += 1;
    }
    
    return result;
}
```

### Pattern 2: Round-Up (Ceiling)

**Use Case**: Fee calculations favoring protocol, penalty calculations

```solidity
function mulDivRoundUp(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
    uint256 product = a * b;
    uint256 result = product / c;
    
    // Round up if there's any remainder
    if (product % c != 0) {
        result += 1;
    }
    
    return result;
}
```

### Pattern 3: Round-Down (Floor)

**Use Case**: User-favorable calculations, conservative estimates

```solidity
function mulDivRoundDown(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
    // Standard Solidity division already rounds down
    return (a * b) / c;
}
```

### Pattern 4: High-Precision Intermediate

**Use Case**: High-value transactions, precision-critical calculations

```solidity
function mulDivHighPrecision(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
    require(a <= type(uint256).max / 1e18, "Overflow risk");
    require(b <= type(uint256).max / 1e18, "Overflow risk");
    
    uint256 highPrecisionResult = (a * 1e18 * b) / (c * 1e18);
    return highPrecisionResult;
}
```

### Pattern 5: Precision Verification

**Use Case**: Critical calculations requiring accuracy validation

```solidity
function mulDivVerified(
    uint256 a, 
    uint256 b, 
    uint256 c, 
    uint256 maxErrorPct
) internal pure returns (uint256) {
    uint256 result = (a * b) / c;
    
    // Verify precision by reverse calculation
    uint256 backCalculated = (result * c) / b;
    uint256 error = a > backCalculated ? a - backCalculated : backCalculated - a;
    uint256 maxError = (a * maxErrorPct) / 10000; // maxErrorPct in basis points
    
    require(error <= maxError, "Precision loss exceeds tolerance");
    return result;
}
```

## Decision Framework

### Step 1: Assess Requirements

Critical Factors:
├── Transaction Frequency (High → Optimize Gas)
├── Value Magnitude (High → Maximize Precision)
├── User Impact (High → Round Favorably)
├── Regulatory Requirements (Strict → Verify Precision)
└── Technical Constraints (Simple → Basic Patterns)


### Step 2: Choose Pattern

| Requirement | Recommended Pattern | Gas Cost | Precision |
|-------------|-------------------|----------|-----------|
| **General Purpose** | Round-to-Nearest | Low | Good |
| **Fee Collection** | Round-Up | Low | Favors Protocol |
| **User Rewards** | Round-Down | Minimal | Favors Users |
| **High-Value Operations** | High-Precision | High | Maximum |
| **Audit Requirements** | Precision Verification | Very High | Validated |

### Step 3: Implementation Checklist

- [ ] Overflow protection implemented
- [ ] Rounding direction documented
- [ ] Edge cases tested
- [ ] Gas costs measured
- [ ] Business logic alignment verified

## Implementation Templates

### Template 1: Basic Precision Library

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library PrecisionMath {
    uint256 constant PRECISION_LOSS_THRESHOLD = 100; // 1% in basis points
    
    /**
     * @dev Multiplies a by b and divides by c with specified rounding
     * @param a First multiplicand
     * @param b Second multiplicand  
     * @param c Divisor
     * @param roundUp If true, rounds up; otherwise rounds to nearest
     */
    function mulDiv(
        uint256 a, 
        uint256 b, 
        uint256 c, 
        bool roundUp
    ) internal pure returns (uint256) {
        require(c != 0, "Division by zero");
        
        uint256 product = a * b;
        uint256 result = product / c;
        uint256 remainder = product % c;
        
        if (remainder > 0) {
            if (roundUp || remainder >= c / 2) {
                result += 1;
            }
        }
        
        return result;
    }
    
    /**
     * @dev Safe multiplication with overflow check
     */
    function safeMul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 c = a * b;
        require(c / a == b, "Multiplication overflow");
        return c;
    }
    
    /**
     * @dev Calculate precision loss percentage in basis points
     */
    function calculatePrecisionLoss(
        uint256 original,
        uint256 calculated
    ) internal pure returns (uint256) {
        if (original == 0) return 0;
        
        uint256 loss = original > calculated ? 
            original - calculated : 
            calculated - original;
            
        return (loss * 10000) / original; // Return in basis points
    }
}
```

### Template 2: Percentage Calculator

```solidity
library PercentageMath {
    uint256 constant PERCENTAGE_BASE = 10000; // 100.00%
    
    /**
     * @dev Calculate percentage of amount
     * @param amount Base amount
     * @param percentage Percentage in basis points (100 = 1%)
     * @param favorUser If true, rounds down; if false, rounds up
     */
    function calculatePercentage(
        uint256 amount,
        uint256 percentage,
        bool favorUser
    ) internal pure returns (uint256) {
        require(percentage <= PERCENTAGE_BASE, "Invalid percentage");
        
        uint256 product = amount * percentage;
        uint256 result = product / PERCENTAGE_BASE;
        uint256 remainder = product % PERCENTAGE_BASE;
        
        // Apply rounding based on favorUser flag
        if (remainder > 0 && !favorUser) {
            result += 1;
        }
        
        return result;
    }
    
    /**
     * @dev Split amount into multiple percentages
     * @param amount Total amount to split
     * @param percentages Array of percentages (must sum to PERCENTAGE_BASE)
     * @param favorUser Rounding direction for user benefit
     */
    function splitByPercentages(
        uint256 amount,
        uint256[] memory percentages,
        bool favorUser
    ) internal pure returns (uint256[] memory) {
        uint256 totalPercentage = 0;
        for (uint256 i = 0; i < percentages.length; i++) {
            totalPercentage += percentages[i];
        }
        require(totalPercentage == PERCENTAGE_BASE, "Percentages must sum to 100%");
        
        uint256[] memory results = new uint256[](percentages.length);
        uint256 allocated = 0;
        
        // Calculate all but last percentage
        for (uint256 i = 0; i < percentages.length - 1; i++) {
            results[i] = calculatePercentage(amount, percentages[i], favorUser);
            allocated += results[i];
        }
        
        // Last percentage gets remainder to ensure total accuracy
        results[percentages.length - 1] = amount - allocated;
        
        return results;
    }
}
```

### Template 3: Token Conversion

```solidity
library TokenConversion {
    /**
     * @dev Convert between tokens with different decimals
     * @param amount Amount in source token decimals
     * @param sourceDecimals Decimals of source token
     * @param targetDecimals Decimals of target token
     * @param rate Exchange rate (target per source) in 18 decimals
     */
    function convertTokens(
        uint256 amount,
        uint8 sourceDecimals,
        uint8 targetDecimals,
        uint256 rate
    ) internal pure returns (uint256) {
        // Normalize to 18 decimals for calculation
        uint256 normalizedAmount;
        if (sourceDecimals <= 18) {
            normalizedAmount = amount * (10 ** (18 - sourceDecimals));
        } else {
            normalizedAmount = amount / (10 ** (sourceDecimals - 18));
        }
        
        // Apply exchange rate
        uint256 convertedAmount = (normalizedAmount * rate) / 1e18;
        
        // Convert to target decimals
        if (targetDecimals <= 18) {
            return convertedAmount / (10 ** (18 - targetDecimals));
        } else {
            return convertedAmount * (10 ** (targetDecimals - 18));
        }
    }
}
```

## Testing Strategies

### Unit Test Template

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

contract PrecisionMathTest is Test {
    using PrecisionMath for uint256;
    
    function testPrecisionLoss() public {
        // Test edge cases where precision loss is significant
        uint256 amount = 1000;
        uint256 percentage = 333; // 3.33%
        uint256 base = 10000;
        
        uint256 result = PrecisionMath.mulDiv(amount, percentage, base, false);
        uint256 expected = 33; // Should be 33.3, truncated to 33
        
        assertEq(result, expected);
        
        // Verify precision loss is within acceptable bounds
        uint256 precisionLoss = PrecisionMath.calculatePrecisionLoss(
            (amount * percentage) / base,
            result
        );
        
        assertLt(precisionLoss, 100); // Less than 1% error
    }
    
    function testRoundingStrategies() public {
        uint256 amount = 1000;
        uint256 percentage = 333; // 3.33%
        uint256 base = 10000;
        
        uint256 roundDown = PrecisionMath.mulDiv(amount, percentage, base, false);
        uint256 roundUp = PrecisionMath.mulDiv(amount, percentage, base, true);
        
        assertEq(roundDown, 33);
        assertEq(roundUp, 34);
        assertTrue(roundUp > roundDown);
    }
    
    function testOverflowProtection() public {
        uint256 maxUint = type(uint256).max;
        
        vm.expectRevert("Multiplication overflow");
        PrecisionMath.safeMul(maxUint, 2);
    }
    
    function fuzzTestPrecision(
        uint256 amount,
        uint256 percentage
    ) public {
        // Bound inputs to reasonable ranges
        amount = bound(amount, 1, type(uint128).max);
        percentage = bound(percentage, 1, 10000);
        
        uint256 result = PrecisionMath.mulDiv(amount, percentage, 10000, false);
        
        // Verify result is reasonable
        assertTrue(result <= amount);
        
        // Verify precision loss is bounded
        uint256 expected = (amount * percentage) / 10000;
        uint256 precisionLoss = expected > result ? expected - result : result - expected;
        assertTrue(precisionLoss <= 1); // At most 1 unit error
    }
}
```

### Integration Test Scenarios

```solidity
contract IntegrationTest is Test {
    function testCumulativePrecisionLoss() public {
        uint256 initialAmount = 1000000; // 1M tokens
        uint256 amount = initialAmount;
        
        // Simulate 100 fee deductions of 0.33%
        for (uint256 i = 0; i < 100; i++) {
            uint256 fee = PrecisionMath.mulDiv(amount, 33, 10000, true); // Round up fees
            amount -= fee;
        }
        
        // Calculate expected amount with precise math
        uint256 remaining = (initialAmount * (9967 ** 100)) / (10000 ** 100);
        
        // Verify cumulative error is acceptable
        uint256 error = remaining > amount ? remaining - amount : amount - remaining;
        uint256 errorPct = (error * 10000) / initialAmount;
        
        assertLt(errorPct, 10); // Less than 0.1% cumulative error
    }
}
```

## Best Practices

### 1. Documentation Standards

```solidity
/**
 * @notice Calculate fee with precision-aware rounding
 * @dev Uses round-up strategy to ensure protocol never loses fees due to precision
 * @param amount Base amount for fee calculation
 * @param feeBps Fee percentage in basis points (1 = 0.01%)
 * @return feeAmount Calculated fee, rounded up to nearest unit
 */
function calculateFee(uint256 amount, uint256 feeBps) external pure returns (uint256 feeAmount) {
    return PrecisionMath.mulDiv(amount, feeBps, 10000, true);
}
```

### 2. Error Handling

```solidity
// Custom errors for precision issues
error PrecisionLossExceedsThreshold(uint256 actual, uint256 threshold);
error InvalidPrecisionParameters(uint256 value, uint256 max);

// Implementation with proper error handling
function safePrecisionCalculation(
    uint256 a, 
    uint256 b, 
    uint256 c
) internal pure returns (uint256) {
    if (c == 0) revert InvalidPrecisionParameters(c, 1);
    if (a > type(uint256).max / b) revert InvalidPrecisionParameters(a * b, type(uint256).max);
    
    uint256 result = (a * b) / c;
    uint256 precisionLoss = ((a * b) % c * 10000) / (a * b);
    
    if (precisionLoss > 100) { // 1% threshold
        revert PrecisionLossExceedsThreshold(precisionLoss, 100);
    }
    
    return result;
}
```

### 3. Gas Optimization

```solidity
// Optimize for common cases
function optimizedMulDiv(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
    // Fast path for exact divisions
    unchecked {
        uint256 product = a * b;
        if (product % c == 0) {
            return product / c;
        }
    }
    
    // Precision-aware path for remainders
    return PrecisionMath.mulDiv(a, b, c, false);
}
```

### 4. Business Logic Alignment

```solidity
// Clear rounding policies based on business needs
contract TradingFees {
    // Always round fees up (favors protocol)
    function calculateTradingFee(uint256 tradeAmount) external pure returns (uint256) {
        return PrecisionMath.mulDiv(tradeAmount, 30, 10000, true); // 0.3% rounded up
    }
    
    // Always round rewards down (conservative distribution)
    function calculateReward(uint256 stakeAmount) external pure returns (uint256) {
        return PrecisionMath.mulDiv(stakeAmount, 500, 10000, false); // 5% rounded down
    }
}
```

## Common Use Cases

### Fee Calculations
- **Protocol fees**: Round up to ensure revenue
- **User refunds**: Round down to prevent overpayment
- **Gas fee estimates**: Round up for safety buffer

### Token Operations
- **Staking rewards**: Round down for conservative distribution
- **Penalty calculations**: Round up for deterrent effect
- **Exchange rates**: Use high precision for accuracy

### Financial Calculations
- **Interest accrual**: High precision with verification
- **Debt calculations**: Round up for borrower obligations
- **Collateral ratios**: Round down for safety margins

### Voting and Governance
- **Vote weight calculations**: Round to nearest for fairness
- **Quorum calculations**: Round up for security
- **Delegation ratios**: High precision for accurate representation

## Migration Guide

### From Basic Division to Precision-Aware

**Before:**
```solidity
uint256 fee = amount * feePct / 10000;
```

**After:**
```solidity
uint256 fee = PrecisionMath.mulDiv(amount, feePct, 10000, true);
```

### Deployment Considerations

1. **Library Deployment**: Deploy precision library separately for reuse
2. **Gas Analysis**: Measure gas impact before production deployment
3. **Audit Requirements**: Include precision loss testing in security audits
4. **Documentation**: Update all calculation documentation with precision policies

## Conclusion

Precision loss mitigation is crucial for financial smart contracts. This reference guide provides the tools and knowledge to implement appropriate precision handling strategies based on specific requirements and constraints.

**Key Takeaways:**
- Always consider precision impact in financial calculations
- Choose rounding strategies based on business logic
- Test extensively with edge cases and cumulative operations
- Document precision policies clearly
- Balance precision with gas efficiency

**Remember**: Precision is not just a technical concern—it's a user trust and regulatory compliance issue that requires careful consideration in all financial smart contracts.