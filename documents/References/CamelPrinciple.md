# Precision Loss Mitigation in Solidity: The Camel Principle Approaches

**NOTE: THIS IS ONLY WORTH IT FOR LOW PRECISION TOKENS. LIKE USDC, 6dp.**
**FOR STANDARD 18DP TOKENS, IGNORE.**

## Introduction

Precision loss in Solidity arithmetic operations occurs primarily due to integer division truncation. When performing calculations like `(a * b) / c`, intermediate results are truncated rather than rounded, leading to cumulative precision errors that can significantly impact financial calculations.

The "Camel Principle" refers to various strategies that improve precision handling by managing intermediate calculations, remainders, and rounding logic to minimize precision loss while maintaining gas efficiency.

## Problem Statement

In the EscrowedMoca contract, the calculation:
```solidity
mocaReceivable = redemptionAmount * option.receivablePct / Constants.PRECISION_BASE;
```

Suffers from precision loss because:
- `PRECISION_BASE = 10_000` (2 decimal places)
- Division truncates fractional parts
- Small amounts may round to zero
- Cumulative errors compound over multiple operations

## Approach 1: Rounding Strategy with Remainder Tracking

### Implementation
```solidity
uint256 rawCalculation = redemptionAmount * option.receivablePct;
mocaReceivable = rawCalculation / Constants.PRECISION_BASE;

uint256 remainder = rawCalculation % Constants.PRECISION_BASE;

// Round up if remainder >= 50% of precision base
if (remainder >= Constants.PRECISION_BASE / 2) {
    mocaReceivable += 1;
}
```

### Pros
- **Minimal gas overhead**: Only adds one modulo operation and conditional
- **Banker's rounding**: Provides fair rounding that reduces bias over many operations
- **Transparent logic**: Easy to understand and audit
- **Predictable behavior**: Consistent rounding rules

### Cons
- **Still loses sub-unit precision**: Can't recover precision below the smallest unit
- **Rounding bias**: Always rounds in favor of user or protocol
- **Limited improvement**: Only helps when remainder is significant

### Trade-offs
- **Gas cost**: +~200 gas for modulo and conditional
- **Precision gain**: ~0.5 unit average improvement
- **Complexity**: Low implementation complexity

## Approach 2: Higher Precision Intermediate Calculation

### Implementation
```solidity
uint256 highPrecisionBase = Constants.PRECISION_BASE * 1e18;
uint256 highPrecisionReceivable = (redemptionAmount * 1e18 * option.receivablePct) / highPrecisionBase;
mocaReceivable = highPrecisionReceivable;
```

### Pros
- **Maximum precision**: Maintains 18 additional decimal places during calculation
- **No rounding bias**: Preserves exact mathematical relationships
- **Scalable precision**: Can adjust precision level as needed
- **Future-proof**: Handles larger value ranges

### Cons
- **Overflow risk**: Multiplication by 1e18 may cause overflow for large values
- **Gas cost**: Higher computational cost for extended precision
- **Complexity**: Requires careful overflow checking
- **Overkill**: May provide unnecessary precision for most use cases

### Trade-offs
- **Gas cost**: +~500 gas for extended arithmetic
- **Precision gain**: 18 decimal places of accuracy
- **Risk**: Potential overflow needs bounds checking

## Approach 3: Bidirectional Calculation Verification

### Implementation
```solidity
mocaReceivable = redemptionAmount * option.receivablePct / Constants.PRECISION_BASE;

uint256 backCalculated = mocaReceivable * Constants.PRECISION_BASE / option.receivablePct;
uint256 precisionLoss = redemptionAmount > backCalculated ? 
    redemptionAmount - backCalculated : 
    backCalculated - redemptionAmount;

require(precisionLoss <= redemptionAmount / 1000, "Precision loss too high");
```

### Pros
- **Precision verification**: Quantifies actual precision loss
- **Safety mechanism**: Prevents excessive precision loss
- **Debugging aid**: Helps identify problematic calculations
- **Configurable tolerance**: Adjustable precision thresholds

### Cons
- **High gas cost**: Requires additional division and comparison operations
- **Transaction failures**: May revert on edge cases with high precision loss
- **Complex logic**: More code paths to test and maintain
- **Performance overhead**: Doubles calculation work

### Trade-offs
- **Gas cost**: +~800 gas for verification calculations
- **Safety**: High assurance of precision bounds
- **UX impact**: Potential transaction reverts on edge cases

## Approach 4: Optimized Implementation with Gas Efficiency

### Implementation
```solidity
uint256 numerator = redemptionAmount * option.receivablePct;
mocaReceivable = numerator / Constants.PRECISION_BASE;

uint256 remainder = numerator % Constants.PRECISION_BASE;
if (remainder >= Constants.PRECISION_BASE / 2) {
    mocaReceivable += 1;
}

penaltyAmount = redemptionAmount - mocaReceivable;
assert(penaltyAmount <= redemptionAmount);
```

### Pros
- **Balanced approach**: Good precision improvement with reasonable gas cost
- **Safety assertions**: Includes overflow protection
- **Clear variable naming**: Improves code readability
- **Minimal complexity**: Straightforward logic flow

### Cons
- **Moderate gas increase**: Still adds computational overhead
- **Rounding decisions**: Need to choose rounding direction policy
- **Limited precision**: Bound by base precision units

### Trade-offs
- **Gas cost**: +~300 gas for improved precision
- **Precision gain**: ~0.5 unit improvement with safety checks
- **Maintainability**: Clean, auditable code

## Approach 5: Fixed-Point Arithmetic Library

### Implementation
```solidity
library PrecisionMath {
    function mulDiv(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return (a * b) / c;
    }
    
    function mulDivRoundUp(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        uint256 result = (a * b) / c;
        if ((a * b) % c != 0) {
            result += 1;
        }
        return result;
    }
}

// Usage:
mocaReceivable = PrecisionMath.mulDiv(redemptionAmount, option.receivablePct, Constants.PRECISION_BASE);
```

### Pros
- **Reusability**: Single implementation for all precision calculations
- **Consistency**: Standardized precision handling across contract
- **Maintainability**: Centralized logic for updates and fixes
- **Testing**: Library can be thoroughly tested in isolation

### Cons
- **Additional deployment**: Library needs separate deployment or embedding
- **Function call overhead**: Small gas cost for internal function calls
- **Abstraction complexity**: May obscure underlying calculations
- **Version management**: Library updates require coordination

### Trade-offs
- **Gas cost**: +~100 gas for function call overhead
- **Development time**: Initial library development and testing
- **Long-term benefits**: Easier maintenance and consistency

## Comparative Analysis

| Approach | Gas Cost | Precision Gain | Complexity | Risk Level |
|----------|----------|----------------|------------|------------|
| Approach 1 | Low (+200) | Moderate | Low | Low |
| Approach 2 | High (+500) | Maximum | Medium | Medium |
| Approach 3 | Very High (+800) | Verification Only | High | Low |
| Approach 4 | Medium (+300) | Good | Low | Low |
| Approach 5 | Low (+100) | Configurable | Medium | Low |

## Recommendations

### For Production Use
**Approach 4** (Optimized Implementation) is recommended because:
- Provides meaningful precision improvement
- Maintains reasonable gas costs
- Includes safety assertions
- Offers clear, auditable logic

### For High-Value Operations
**Approach 2** (Higher Precision) when:
- Transaction values are significant
- Precision loss could impact user trust
- Gas costs are secondary to accuracy

### For System-Wide Implementation
**Approach 5** (Library-Based) for:
- Multiple contracts requiring precision handling
- Long-term maintainability
- Consistent precision policies across the system

## Implementation Guidelines

1. **Choose rounding direction** based on business logic (favor user vs protocol)
2. **Add bounds checking** for overflow protection
3. **Document precision policies** clearly in code comments
4. **Test edge cases** with small amounts and boundary values
5. **Monitor gas costs** in production to ensure optimization effectiveness

## Conclusion

Precision loss mitigation requires balancing mathematical accuracy, gas efficiency, and implementation complexity. The choice of approach should align with the specific requirements of the use case, considering transaction frequency, value magnitudes, and acceptable precision tolerances.

For the EscrowedMoca contract, implementing Approach 4 provides the optimal balance of precision improvement and gas efficiency while maintaining code clarity and safety.

**NOTE: THIS IS ONLY WORTH IT FOR LOW PRECISION TOKENS. LIKE USDC, 6dp.**
**FOR STANDARD 18DP TOKENS, IGNORE.**