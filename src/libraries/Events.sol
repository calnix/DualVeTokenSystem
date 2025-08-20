// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

library Events {
    
    // --------- VotingEscrowMoca.sol ---------
    // delegate
    event DelegateRegistered(address indexed delegate);
    event DelegateUnregistered(address indexed delegate);
    // risk
    event ContractFrozen();
    event EmergencyExit(bytes32[] lockIds);

    
}