# PaymentsController Overview





## deductBalance Optimizations

The `deductBalance` function is the most frequently called function in the PaymentsController, executed on every credential verification. 
Given its high usage, we've implemented a hybrid storage-memory optimization pattern that reduces gas consumption by approximately 40% while maintaining code clarity and security.

**The Hybrid Approach**
We employ a dual-reference pattern that optimizes for both read and write operations:

```solidity
// Storage pointer for write operations
DataTypes.Schema storage schemaStorage = _schemas[schemaId];

// Memory copy for read operations  
DataTypes.Schema memory schema = schemaStorage;
```

**This pattern allows us to:**

1. Read efficiently: Access struct fields from memory (3 gas) instead of storage (100 gas)
2. Write selectively: Update storage only when necessary using the storage pointer
3. Maintain consistency: Keep a clear separation between read and write operations

### Design Rationale

**Why Hybrid Instead of Pure Memory?**
- Conditional Updates: Fee updates only occur when conditions are met
- Atomic Operations: Storage updates must be atomic for consistency
- Memory Limitations: Full memory copy would be wasteful for conditional writes

**Why Not Pure Storage?**
- Read Frequency: Schema fields are read 8-10 times per execution
- Calculation Needs: Multiple fields needed for fee calculations
- Cost Multiplication: Each storage read adds 100 gas

### Gas Savings Breakdown

| **Optimization Technique**| **Gas Saved**  | **Impact**                              |
|---------------------------|----------------|-----------------------------------------|
| Schema memory caching     | ~800 gas       | Eliminates 8 storage reads              |
| Verifier data caching     | ~200 gas       | Eliminates 2 storage reads              |
| Batch storage updates     | ~100 gas       | Reduces storage operation overhead      |
| Unchecked arithmetic      | ~80 gas        | Safe counters don't need overflow checks|
| **Total Savings**         | **~1,180 gas** | **~40% reduction**                      |