// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";

/**
    - Stake MOCA tokens to receive veMOCA (voting power)
    - Longer lock periods result in higher veMOCA allocation
    - veMOCA decays linearly over time, reducing voting power
    - Formula-based calculation determines veMOCA amount based on stake amount and duration
 */

contract veMOCA is ERC20, AccessControl {
    using SafeERC20 for IERC20;

    IERC20 public immutable mocaToken;
    IERC20 public immutable esMOCA;

    uint256 public constant MIN_LOCK_DURATION = 7 days;
    uint256 public constant MAX_LOCK_DURATION = 730 days; // 2 years
    uint256 public constant PRECISION_BASE = 100; // 100%: 100, 1%: 1 | no decimal places
    
    uint256 public maxEarlyRedemptionPenalty = 50; // Default 50% maximum penalty

    address public treasury;

    struct User {
        uint256 moca;             
        uint256 veMoca;          
        uint256 endTime; 
    }

    // global
    uint256 public totalLockedMOCA;
    uint256 public totalLockedEsMOCA;

    // User => Lock ID => Lock data
    mapping(address user => mapping(uint256 lockId => Lock lock)) public userLocks;
    
//-------------------------------events------------------------------------------

    // Events
    event TokensLocked(address indexed user, uint256 indexed lockId, uint256 amount, uint256 lockDuration, uint256 veMOCAAmount, bool isEsMOCA);
    event LockExtended(address indexed user, uint256 indexed lockId, uint256 newEndTime, uint256 newVeMOCAAmount);
    event TokensRedeemed(address indexed user, uint256 indexed lockId, uint256 amount, uint256 penalty);
    event MaxEarlyRedemptionPenaltyUpdated(uint256 oldPenalty, uint256 newPenalty);
    event TreasuryUpdated(address oldTreasury, address newTreasury);

//-------------------------------constructor------------------------------------------

    constructor(address mocaToken_, address esMOCA_, address owner_, address initialTreasury_) ERC20("veMOCA", "veMOCA") {
        require(mocaToken_ != address(0), "Invalid MOCA token address");
        require(esMOCA_ != address(0), "Invalid esMOCA token address");
        require(owner_ != address(0), "Invalid owner address");
        require(initialTreasury_ != address(0), "Invalid treasury address");
        
        mocaToken = IERC20(mocaToken_);
        esMOCA = IERC20(esMOCA_);
        treasury = initialTreasury_;
        
        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
    }

//-------------------------------external functions------------------------------------------


    /**
     * @notice Lock MOCA tokens to receive veMOCA
     * @param amount Amount of MOCA to lock
     * @param lockDuration Duration of the lock in seconds
     */
    function lockMOCA(uint256 amount, uint256 lockDuration) external {
        require(amount > 0, "Amount must be greater than zero");
        require(lockDuration >= MIN_LOCK_DURATION, "Lock duration too short");
        require(lockDuration <= MAX_LOCK_DURATION, "Lock duration too long");
        
        // Transfer MOCA from user to this contract
        mocaToken.safeTransferFrom(msg.sender, address(this), amount);
        
        // Calculate veMOCA amount
        uint256 veMoca = _calculateVeMoca(amount, lockDuration);
        
        // Create lock
        uint256 lockId = userLockCount[msg.sender];
        userLocks[msg.sender][lockId] = Lock({
            amount: amount,
            startTime: block.timestamp,
            endTime: block.timestamp + lockDuration,
            initialVeMOCA: veMOCAAmount
        });
        
        // Update user lock count
        userLockCount[msg.sender]++;
        
        // Update total locked MOCA
        totalLockedMOCA += amount;
        
        // Mint veMOCA to user
        _mint(msg.sender, veMOCAAmount);
        
        emit TokensLocked(msg.sender, lockId, amount, lockDuration, veMOCAAmount, false);
    }

    /**
     * @notice Lock esMOCA tokens to receive veMOCA
     * @param amount Amount of esMOCA to lock
     * @param lockDuration Duration of the lock in seconds
     */
    function lockEsMOCA(uint256 amount, uint256 lockDuration) external {
        require(amount > 0, "Amount must be greater than zero");
        require(lockDuration >= MIN_LOCK_DURATION, "Lock duration too short");
        require(lockDuration <= MAX_LOCK_DURATION, "Lock duration too long");
        
        // Transfer esMOCA from user to this contract
        esMOCA.safeTransferFrom(msg.sender, address(this), amount);
        
        // Calculate veMOCA amount (same formula as MOCA)
        uint256 veMOCAAmount = calculateVeMOCA(amount, lockDuration);
        
        // Create lock
        uint256 lockId = userLockCount[msg.sender];
        userLocks[msg.sender][lockId] = Lock({
            amount: amount,
            startTime: block.timestamp,
            endTime: block.timestamp + lockDuration,
            initialVeMOCA: veMOCAAmount
        });
        
        // Update user lock count
        userLockCount[msg.sender]++;
        
        // Update total locked esMOCA
        totalLockedEsMOCA += amount;
        
        // Mint veMOCA to user
        _mint(msg.sender, veMOCAAmount);
        
        emit TokensLocked(msg.sender, lockId, amount, lockDuration, veMOCAAmount, true);
    }


    /**
     * @notice Calculate veMOCA amount based on lock amount and duration
     * @param amount Amount of tokens to lock
     * @param lockDuration Duration of the lock in seconds
     * @return veMOCAAmount The amount of veMOCA to mint
     */
    function _calculateVeMoca(uint256 amount, uint256 lockDuration) internal pure returns (uint256) {
        // Ensure lock duration is within limits
        lockDuration = lockDuration > MAX_LOCK_DURATION ? MAX_LOCK_DURATION : lockDuration;
        lockDuration = lockDuration < MIN_LOCK_DURATION ? MIN_LOCK_DURATION : lockDuration;

        return amount * lockDuration / MAX_LOCK_DURATION;
    }

    /**
     * @notice Get current veMOCA balance for a lock considering decay
     * @param user The address of the user
     * @param lockId The ID of the lock
     * @return currentVeMOCA The current veMOCA amount after decay
     */
    function getCurrentVeMOCA(address user, uint256 lockId) public view returns (uint256 currentVeMOCA) {
        Lock memory lock = userLocks[user][lockId];
        
        // If lock doesn't exist or has expired
        if (lock.amount == 0 || block.timestamp >= lock.endTime) {
            return 0;
        }
        
        uint256 totalLockDuration = lock.endTime - lock.startTime;
        uint256 timeRemaining = lock.endTime - block.timestamp;
        
        // veMOCA decays linearly over time
        // Current veMOCA = Initial veMOCA * (timeRemaining / totalLockDuration)
        currentVeMOCA = lock.initialVeMOCA * timeRemaining / totalLockDuration;
        
        return currentVeMOCA;
    }

    /**
     * @notice Get total veMOCA balance for a user across all active locks
     * @param user The address of the user
     * @return totalVeMOCA The total current veMOCA amount
     */
    function getTotalVeMOCA(address user) public view returns (uint256 totalVeMOCA) {
        uint256 lockCount = userLockCount[user];
        
        for (uint256 i = 0; i < lockCount; i++) {
            totalVeMOCA += getCurrentVeMOCA(user, i);
        }
        
        return totalVeMOCA;
    }



    /**
     * @notice Extend lock duration
     * @param lockId ID of the lock to extend
     * @param newLockDuration New lock duration in seconds (from now)
     */
    function extendLock(uint256 lockId, uint256 newLockDuration) external {
        require(newLockDuration >= MIN_LOCK_DURATION, "Lock duration too short");
        require(newLockDuration <= MAX_LOCK_DURATION, "Lock duration too long");
        
        Lock storage lock = userLocks[msg.sender][lockId];
        
        require(lock.amount > 0, "Lock does not exist");
        require(block.timestamp < lock.endTime, "Lock has expired");
        
        uint256 newEndTime = block.timestamp + newLockDuration;
        require(newEndTime > lock.endTime, "New end time must be later than current end time");
        
        // Calculate current veMOCA before extension
        uint256 currentVeMOCA = getCurrentVeMOCA(msg.sender, lockId);
        
        // Burn current veMOCA
        _burn(msg.sender, currentVeMOCA);
        
        // Calculate new veMOCA amount
        uint256 newVeMOCAAmount = calculateVeMOCA(lock.amount, newLockDuration);
        
        // Update lock
        lock.startTime = block.timestamp;
        lock.endTime = newEndTime;
        lock.initialVeMOCA = newVeMOCAAmount;
        
        // Mint new veMOCA
        _mint(msg.sender, newVeMOCAAmount);
        
        emit LockExtended(msg.sender, lockId, newEndTime, newVeMOCAAmount);
    }

    /**
     * @notice Redeem locked tokens after lock expiry
     * @param lockId ID of the lock to redeem
     */
    function redeemExpiredLock(uint256 lockId) external {
        Lock storage lock = userLocks[msg.sender][lockId];
        
        require(lock.amount > 0, "Lock does not exist");
        require(block.timestamp >= lock.endTime, "Lock has not expired yet");
        
        uint256 amount = lock.amount;
        
        // Clear lock data
        delete userLocks[msg.sender][lockId];
        
        // Update total locked amounts
        totalLockedMOCA -= amount;
        
        // Transfer tokens back to user
        mocaToken.safeTransfer(msg.sender, amount);
        
        emit TokensRedeemed(msg.sender, lockId, amount, 0);
    }

    /**
     * @notice Early redemption with penalty
     * @param lockId ID of the lock to redeem early
     */
    function earlyRedemption(uint256 lockId) external {
        Lock storage lock = userLocks[msg.sender][lockId];
        
        require(lock.amount > 0, "Lock does not exist");
        require(block.timestamp < lock.endTime, "Lock has already expired");
        
        // Calculate penalty
        // Penalty_Pct = (Time_left / Total_Lock_Time) × Max_Penalty_Pct
        uint256 totalLockDuration = lock.endTime - lock.startTime;
        uint256 timeRemaining = lock.endTime - block.timestamp;
        uint256 penaltyPercent = (timeRemaining * maxEarlyRedemptionPenalty) / totalLockDuration;
        
        uint256 penaltyAmount = (lock.amount * penaltyPercent) / PRECISION_BASE;
        uint256 returnAmount = lock.amount - penaltyAmount;
        
        // Calculate current veMOCA
        uint256 currentVeMOCA = getCurrentVeMOCA(msg.sender, lockId);
        
        // Burn current veMOCA
        _burn(msg.sender, currentVeMOCA);
        
        // Clear lock data
        delete userLocks[msg.sender][lockId];
        
        // Update total locked amounts
        totalLockedMOCA -= lock.amount;
        
        // Transfer penalty to treasury
        mocaToken.safeTransfer(treasury, penaltyAmount);
        
        // Transfer remaining tokens to user
        mocaToken.safeTransfer(msg.sender, returnAmount);
        
        emit TokensRedeemed(msg.sender, lockId, lock.amount, penaltyAmount);
    }

//-------------------------------admin functions-----------------------------------------

    /**
     * @notice Update the maximum early redemption penalty
     * @param newPenalty New maximum penalty percentage (1-100)
     */
    function setMaxEarlyRedemptionPenalty(uint256 newPenalty) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newPenalty <= PRECISION_BASE, "Penalty cannot exceed 100%");
        
        uint256 oldPenalty = maxEarlyRedemptionPenalty;
        maxEarlyRedemptionPenalty = newPenalty;
        
        emit MaxEarlyRedemptionPenaltyUpdated(oldPenalty, newPenalty);
    }

    /**
     * @notice Update the treasury address
     * @param newTreasury New treasury address
     */
    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newTreasury != address(0), "Invalid treasury address");
        
        address oldTreasury = treasury;
        treasury = newTreasury;
        
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

//-------------------------------admin functions-----------------------------------------

    /**
     * @notice Override the transfer function to block transfers
     * @dev veMOCA is non-transferable
     */
    function transfer(address, uint256) public pure override returns (bool) {
        revert("veMOCA is non-transferable");
    }

    /**
     * @notice Override the transferFrom function to block transfers
     * @dev veMOCA is non-transferable
     */
    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert("veMOCA is non-transferable");
    }
}