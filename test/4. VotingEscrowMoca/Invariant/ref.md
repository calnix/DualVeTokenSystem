/** running

run all tests in the file
    forge test --match-path "test/4. VotingEscrowMoca/Invariant/Invariant.t.sol"

run by contract name
    forge test --match-contract VotingEscrowMocaInvariant

run all invariants
    forge test --match-contract Invariant

Run with Detailed Output (Debugging)
    forge test --match-path "test/4. VotingEscrowMoca/Invariant/Invariant.t.sol" -vvvv

Run w/ config
    forge test --match-path "test/4. VotingEscrowMoca/Invariant/Invariant.t.sol" --invariant-runs 500 --invariant-depth 50

*/