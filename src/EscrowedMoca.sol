// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

// External: OZ
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

// libraries
import {DataTypes} from "./libraries/DataTypes.sol";
import {Constants} from "./libraries/Constants.sol";
import {Errors} from "./libraries/Errors.sol";
import {Events} from "./libraries/Events.sol";

// interfaces
import {IAccessController} from "./interfaces/IAccessController.sol";

// contracts
import {LowLevelWMoca} from "./LowLevelWMoca.sol";

/**
 * @title EscrowedMoca
 * @author Calnix [@cal_nix]
 * @notice EscrowedMoca is a non-transferable token representing the escrowed MOCA tokens.
 * @dev EscrowedMoca represents MOCA tokens held in escrow, 
 *      which can be redeemed under various options—similar to early bond redemption—with penalties applied based on the chosen redemption method.
*/

contract EscrowedMoca is ERC20, Pausable, LowLevelWMoca {
    using SafeERC20 for IERC20;

    // Contracts
    IAccessController public immutable accessController;
    address public immutable wMoca;

    uint256 public TOTAL_MOCA_PENDING_REDEMPTION;         // tracks the total MOCA balance pending redemption 

    // penalty split between voters and treasury
    uint256 public VOTERS_PENALTY_PCT;         // 2dp precision (XX.yy) | range:[1,10_000] 100%: 10_000 | 1%: 100 | 0.1%: 10 | 0.01%: 1 
    
    // penalty accrued to voters and treasury
    uint256 public ACCRUED_PENALTY_TO_VOTERS; 
    uint256 public CLAIMED_PENALTY_FROM_VOTERS;

    uint256 public ACCRUED_PENALTY_TO_TREASURY; 
    uint256 public CLAIMED_PENALTY_FROM_TREASURY;

    // gas limit for moca transfer
    uint256 public MOCA_TRANSFER_GAS_LIMIT;

    // risk
    uint256 public isFrozen;

//-------------------------------Mappings----------------------------------------------

    // redemption options | range:[1,10_000] 100%: 10_000 | 1%: 100 | 0.1%: 10 | 0.01%: 1 | 2dp precision (XX.yy)
    mapping(uint256 redemptionType => DataTypes.RedemptionOption redemptionOption) public redemptionOptions;
    
    // redemption history
    mapping(address user => mapping(uint256 redemptionTimestamp => DataTypes.Redemption redemption)) public redemptionSchedule;

    mapping(address user => uint256 totalMocaPendingRedemption) public userTotalMocaPendingRedemption;

    // addresses that can transfer esMoca to other addresses: Asset Manager to deposit to VotingController
    mapping(address addr => bool isWhitelisted) public whitelist;


//-------------------------------Constructor------------------------------------------

    constructor(address accessController_, uint256 votersPenaltyPct, address wMoca_, uint256 mocaTransferGasLimit) ERC20("esMoca", "esMOCA") {    
        
        // check: access controller is set [Treasury should be non-zero]
        accessController = IAccessController(accessController_);
        require(accessController.TREASURY() != address(0), Errors.InvalidAddress());

        // sanity check: <= 100%; can be 0 [all penalties to treasury]       
        require(votersPenaltyPct <= Constants.PRECISION_BASE, Errors.InvalidPercentage());
        VOTERS_PENALTY_PCT = votersPenaltyPct;

        // wrapped moca 
        require(wMoca_ != address(0), Errors.InvalidAddress());
        wMoca = wMoca_;

        // gas limit for moca transfer [EOA is ~2300, gnosis safe with a fallback is ~4029]
        require(mocaTransferGasLimit >= 2300, Errors.InvalidGasLimit());
        MOCA_TRANSFER_GAS_LIMIT = mocaTransferGasLimit;
    }

//-------------------------------User functions------------------------------------------

    /**
     * @notice Converts native Moca to esMoca, by transferring native Moca from the user and minting an equivalent amount of esMoca.
     * @dev Accepts native Moca via msg.value.
     */
    function escrowMoca() external payable whenNotPaused {
        uint256 amount = msg.value;
        require(amount > 0, Errors.InvalidAmount());

        // mint esMoca to user
        _mint(msg.sender, amount);

        emit Events.EscrowedMoca(msg.sender, amount);
    }


    /**
     * @notice Redeems esMoca for Moca using a specified redemption option. Transfers native Moca; if transfer fails within gas limit, wraps to wMoca and transfers the wMoca to user.
     * @dev Redemption is irreversible once initiated. Users select from available redemption options, each with distinct lock durations and penalty structures.
     * @param redemptionAmount Amount of esMoca to redeem.
     * @param redemptionOption Redemption option index. (0: Standard, 1: Early, 2: Instant)
     * @custom:requirements `redemptionOption` must be enabled and configured.
     * Emits {RedemptionScheduled} or {Redeemed} depending on lock duration.
     */
    function selectRedemptionOption(uint256 redemptionOption, uint256 redemptionAmount) external payable whenNotPaused {
        // sanity checks: amount & balance
        require(redemptionAmount > 0, Errors.InvalidAmount());
        require(balanceOf(msg.sender) >= redemptionAmount, Errors.InsufficientBalance());
        
        // invariant: should never be triggered
        require(totalSupply() >= redemptionAmount, Errors.TotalMocaEscrowedExceeded());     
        
        // get redemption option + ensure that redemption option is enabled
        DataTypes.RedemptionOption memory option = redemptionOptions[redemptionOption];
        require(option.isEnabled, Errors.RedemptionOptionAlreadyDisabled());

        // 1. Calculate moca receivable + penalty
        uint256 mocaReceivable;
        uint256 penaltyAmount;
        if(option.receivablePct == Constants.PRECISION_BASE) { 
            // redemption with no penalty [user receives 100% of the redemption amount]
            mocaReceivable = redemptionAmount;
        } else {
            // redemption with penalty [user receives a percentage of the redemption amount & pays a penalty]
            mocaReceivable = redemptionAmount * option.receivablePct / Constants.PRECISION_BASE;
            penaltyAmount = redemptionAmount - mocaReceivable;

            // sanity checks: ensure penaltyAmount & mocaReceivable are > 0 [flooring]
            require(mocaReceivable > 0, Errors.InvalidAmount()); 
            require(penaltyAmount > 0, Errors.InvalidAmount()); 

            // we block cases where either penaltyAmount or mocaReceivable is floored to 0
            // when selecting a redemption option, the user must honour its penalty, and receive a non-zero amount of moca. 
            // this prevents users from abusing the system(or getting griefed), and protects protocol from rounding/misconfiguration errors.
        }

        // 2. Burn esMoca tokens from the caller
        _burn(msg.sender, redemptionAmount);

        // 3. Book penalty amounts to globals [if >0, in case of flooring]
        if(penaltyAmount > 0) {
            
            uint256 votersPenaltyPct = VOTERS_PENALTY_PCT;
            
            // if voters penalty split is > 0, calculate penalty splits to voters and treasury
            if(votersPenaltyPct > 0) {
                
                uint256 penaltyToVoters = penaltyAmount * votersPenaltyPct / Constants.PRECISION_BASE;
                uint256 penaltyToTreasury = penaltyAmount - penaltyToVoters;
            
                // book penalty amounts to globals [if >0, in case of flooring]
                if(penaltyToTreasury > 0) ACCRUED_PENALTY_TO_TREASURY += penaltyToTreasury;
                if(penaltyToVoters > 0) ACCRUED_PENALTY_TO_VOTERS += penaltyToVoters;

                emit Events.PenaltyAccrued(penaltyToVoters, penaltyToTreasury);

            } else {
                // all penalties to treasury [0 voters penalty split]
                ACCRUED_PENALTY_TO_TREASURY += penaltyAmount;
                emit Events.PenaltyAccrued(0, penaltyAmount);
            }
        }

        // 4. Calculate redemption timestamp 
        uint256 redemptionTimestamp = block.timestamp + option.lockDuration;

        // 5. Book redemption details to storage [even instant redemptions are booked for consistent record-keeping]
        DataTypes.Redemption storage redemptionPtr = redemptionSchedule[msg.sender][redemptionTimestamp];
        redemptionPtr.mocaReceivable += mocaReceivable;
        redemptionPtr.penalty += penaltyAmount;


        // 6. Handle instant redemptions
        if(option.lockDuration == 0) { 
            
            // Book claimed amount 
            redemptionPtr.claimed += mocaReceivable;
            
            //TOTAL_MOCA_PENDING_REDEMPTION -> no need to increment since no pending redemption

            emit Events.Redeemed(msg.sender, mocaReceivable, redemptionTimestamp);

            // Transfer Moca to user [wraps if transfer fails within gas limit]
            _transferMocaAndWrapIfFailWithGasLimit(wMoca, msg.sender, mocaReceivable, MOCA_TRANSFER_GAS_LIMIT);

        } else {    // 6.1 Schedule redemption [user must claim later]

            // Increment pending counters by the mocaReceivable [global + user]
            TOTAL_MOCA_PENDING_REDEMPTION += mocaReceivable;
            userTotalMocaPendingRedemption[msg.sender] += mocaReceivable;

            emit Events.RedemptionScheduled(msg.sender, mocaReceivable, penaltyAmount, redemptionTimestamp);
        }
    }

    
    /**
     * @notice Claims the redeemed MOCA tokens after the lock period has elapsed.
     * @dev Transfers native Moca; if transfer fails within gas limit, wraps to wMoca and transfers the wMoca to user.
     *      Note: does not burn esMoca tokens - that is done during selectRedemptionOption() call.
     * @param redemptionTimestamps The timestamps at which the redemptions become available for claim.
     */
    function claimRedemptions(uint256[] calldata redemptionTimestamps) external payable whenNotPaused {
        uint256 length = redemptionTimestamps.length;
        require(length > 0, Errors.InvalidArrayLength());

        uint256 totalClaimable;
        for (uint256 i; i < length; ++i) {
            uint256 redemptionTimestamp = redemptionTimestamps[i];

            // sanity check: redemption is available
            require(block.timestamp >= redemptionTimestamp, Errors.InvalidTimestamp());

            // get redemption pointer
            DataTypes.Redemption storage redemptionPtr = redemptionSchedule[msg.sender][redemptionTimestamp];

            // check redemption eligibility: there is something to claim
            uint256 claimableAmount = redemptionPtr.mocaReceivable - redemptionPtr.claimed;
            require(claimableAmount > 0, Errors.NothingToClaim());

            // book claimed amount
            redemptionPtr.claimed += claimableAmount;

            // increment total claimable
            totalClaimable += claimableAmount;
        }
        
        // invariant: should never be triggered
        require(totalClaimable > 0, Errors.NothingToClaim());
        
        // decrement total moca pending redemption by the totalClaimable [penalties were already accounted for]
        TOTAL_MOCA_PENDING_REDEMPTION -= totalClaimable;

        emit Events.RedemptionsClaimed(msg.sender, redemptionTimestamps, totalClaimable);

        // Transfer Moca to user [wraps if transfer fails within gas limit]
        _transferMocaAndWrapIfFailWithGasLimit(wMoca, msg.sender, totalClaimable, MOCA_TRANSFER_GAS_LIMIT);
    }


//-------------------------------CronJob functions-----------------------------------------

    /**
     * @notice Escrows native Moca on behalf of multiple users.
     * @dev Transfers native Moca from the caller to the contract and mints esMoca to each user. 
     *      Note: CronJob's responsibility to ensure there are no duplicate users in the array.
     *      Expectation: this function will be called on a bi-weekly basis to distribute rewards to voters.
     *      So we use CronJob, instead of AssetManager.
     * @param users Array of user addresses to escrow for.
     * @param amounts Array of amounts to escrow for each user.
     */
    function escrowMocaOnBehalf(address[] calldata users, uint256[] calldata amounts) external payable onlyCronJob whenNotPaused {
        uint256 length = users.length;
        require(length == amounts.length, Errors.MismatchedArrayLengths());
        
        uint256 totalMocaAmount;
        for (uint256 i; i < length; ++i) {
            // get user + amount
            address user = users[i];
            uint256 amount = amounts[i];

            // sanity checks
            require(amount > 0, Errors.InvalidAmount());
            require(user != address(0), Errors.InvalidAddress());

            // mint esMoca to user
            _mint(user, amount);

            // add to total amount
            totalMocaAmount += amount;
        }

        // check: msg.value matches totalMocaAmount
        require(msg.value == totalMocaAmount, Errors.InvalidAmount());

        emit Events.StakedOnBehalf(users, amounts);
    }

//-------------------------------Asset manager functions-----------------------------------------
    
    /**
     * @notice Claims accrued penalty amounts for voters and treasury. [Penalties are accrued in Moca]
     * @dev Transfers the total claimable penalty (sum of voters and treasury) to esMoca treasury address
     *      Updates claimed penalty tracking variables to match total accrued.
     *      Note: potential tiny dust from rounding.
     */
    function claimPenalties() external payable onlyAssetManager whenNotPaused {
        // get treasury address
        address esMocaTreasury = accessController.ESCROWED_MOCA_TREASURY();
        require(esMocaTreasury != address(0), Errors.InvalidAddress());

        // check: is there anything to claim?
        uint256 totalPenaltyAccrued = ACCRUED_PENALTY_TO_VOTERS + ACCRUED_PENALTY_TO_TREASURY;
        uint256 totalClaimable = totalPenaltyAccrued - CLAIMED_PENALTY_FROM_VOTERS - CLAIMED_PENALTY_FROM_TREASURY;
        require(totalClaimable > 0, Errors.NothingToClaim());

        // book claimed penalties
        CLAIMED_PENALTY_FROM_VOTERS = ACCRUED_PENALTY_TO_VOTERS;
        CLAIMED_PENALTY_FROM_TREASURY = ACCRUED_PENALTY_TO_TREASURY;

        // transfer moca [wraps if transfer fails within gas limit]
        _transferMocaAndWrapIfFailWithGasLimit(wMoca, esMocaTreasury, totalClaimable, MOCA_TRANSFER_GAS_LIMIT);

        emit Events.PenaltyClaimed(totalClaimable);
    }


    /**
     * @notice Allows caller to release their esMoca to moca instantly.
     * @dev Only callable by EscrowedMocaAdmin.
     * @param amount The amount of esMoca to release to the admin caller.
     */
    function releaseEscrowedMoca(uint256 amount) external payable onlyAssetManager whenNotPaused {
        // sanity check: amount + balance
        require(amount > 0, Errors.InvalidAmount());
        require(balanceOf(msg.sender) >= amount, Errors.InsufficientBalance());
       
        // burn esMoca
        _burn(msg.sender, amount);

        // transfer moca [wraps if transfer fails within gas limit]
        _transferMocaAndWrapIfFailWithGasLimit(wMoca, msg.sender, amount, MOCA_TRANSFER_GAS_LIMIT);

        emit Events.EscrowedMocaReleased(msg.sender, amount);
    }


//-------------------------------Admin: update functions-------------------------------------------------


    /**
     * @notice Updates the percentage of penalty allocated to voters. [0 allowed; all penalties to treasury]
     * @dev The value must be within (0, 10_000), representing up to 100% with 2 decimal precision.
     *      Only callable by EscrowedMocaAdmin.
     * @param penaltyToVoters The new penalty percentage for voters (2dp precision, e.g., 100 = 1%).
     */
    function setVotersPenaltyPct(uint256 votersPenaltyPct) external whenNotPaused onlyEscrowedMocaAdmin {
        // 2dp precision (XX.yy) | range:[1,10_000] 100%: 10_000 | 1%: 100 | 0.1%: 10 | 0.01%: 1 
        require(votersPenaltyPct < Constants.PRECISION_BASE, Errors.InvalidPercentage());

        uint256 oldVotersPenaltyPct = VOTERS_PENALTY_PCT;
        VOTERS_PENALTY_PCT = votersPenaltyPct;

        emit Events.VotersPenaltyPctUpdated(oldVotersPenaltyPct, votersPenaltyPct);
    }


    /**
     * @notice Sets the redemption option for a given redemption type.
     * @dev The receivablePct can be 0; to allow for redemption w/o penalty
     *      Only callable by EscrowedMocaAdmin.
     * @param redemptionOption The redemption option index.
     * @param lockDuration The lock duration for the redemption option. [0 for instant redemption]
     * @param receivablePct The conversion rate for the redemption option. [> 0 for redemption w/ penalty]
     */
    function setRedemptionOption(uint256 redemptionOption, uint128 lockDuration, uint128 receivablePct) external whenNotPaused onlyEscrowedMocaAdmin {
        // range:[0,10_000] 100%: 10_000 | 1%: 100 | 0.1%: 10 | 0.01%: 1 
        require(receivablePct <= Constants.PRECISION_BASE, Errors.InvalidPercentage());
        require(receivablePct > 0, Errors.InvalidPercentage());

        // sanity check: lock duration: ~2.46 years 
        require(lockDuration <= 888 days, Errors.InvalidLockDuration());

        // storage: update redemption option
        redemptionOptions[redemptionOption] = DataTypes.RedemptionOption({
            lockDuration: lockDuration,
            receivablePct: receivablePct,
            isEnabled: true
        });

        emit Events.RedemptionOptionUpdated(redemptionOption, lockDuration, receivablePct);
    }

    /**
     * @notice Enables or disables a redemption option.
     * @dev  Only callable by EscrowedMocaAdmin.
     * @param redemptionOption Index of the redemption option to update.
     * @param enable Set to true to enable, false to disable the redemption option.
     */
    function setRedemptionOptionStatus(uint256 redemptionOption, bool enable) external whenNotPaused onlyEscrowedMocaAdmin {
        DataTypes.RedemptionOption storage optionPtr = redemptionOptions[redemptionOption];

        if (enable) {
            require(!optionPtr.isEnabled, Errors.RedemptionOptionAlreadyEnabled());
            optionPtr.isEnabled = true;
            emit Events.RedemptionOptionEnabled(redemptionOption, optionPtr.receivablePct, optionPtr.lockDuration);
            
        } else {
            require(optionPtr.isEnabled, Errors.RedemptionOptionAlreadyDisabled());
            optionPtr.isEnabled = false;
            emit Events.RedemptionOptionDisabled(redemptionOption);
        }
    }

    
    /**
     * @notice Updates the whitelist status for an address, allowing or revoking permission to transfer esMoca.
     * @dev   Whitelisted addresses can transfer esMoca to other addresses (e.g., Asset Manager to VotingController).
     *        Note: for Asset Manager to deposit esMoca to VotingController.
     * @param addr The address to update whitelist status for.
     * @param isWhitelisted True to whitelist, false to remove from whitelist.
     */
    function setWhitelistStatus(address addr, bool isWhitelisted) external whenNotPaused onlyEscrowedMocaAdmin {
        require(addr != address(0), Errors.InvalidAddress());

        // check: current status
        bool currentStatus = whitelist[addr];
        require(currentStatus != isWhitelisted, Errors.WhitelistStatusUnchanged());

        // storage: update whitelist status
        whitelist[addr] = isWhitelisted;

        emit Events.AddressWhitelisted(addr, isWhitelisted);
    }

    /**
     * @notice Sets the gas limit for moca transfer.
     * @dev Only callable by the IssuerStakingController admin.
     * @param newMocaTransferGasLimit The new gas limit for moca transfer.
     */
    function setMocaTransferGasLimit(uint256 newMocaTransferGasLimit) external whenNotPaused onlyEscrowedMocaAdmin {
        require(newMocaTransferGasLimit >= 2300, Errors.InvalidGasLimit());

        // cache old + update to new gas limit
        uint256 oldMocaTransferGasLimit = MOCA_TRANSFER_GAS_LIMIT;
        MOCA_TRANSFER_GAS_LIMIT = newMocaTransferGasLimit;

        emit Events.MocaTransferGasLimitUpdated(oldMocaTransferGasLimit, newMocaTransferGasLimit);
    }


//-------------------------------Modifiers---------------------------------------------------------------
    
    // for setting contract params
    modifier onlyEscrowedMocaAdmin() {
        require(accessController.isEscrowedMocaAdmin(msg.sender), Errors.OnlyCallableByEscrowedMocaAdmin());
        _;
    }

    // for depositing/withdrawing assets [stakeOnBehalf(), ]
    modifier onlyAssetManager() {
        require(accessController.isAssetManager(msg.sender), Errors.OnlyCallableByAssetManager());
        _;
    }

    modifier onlyCronJob() {
        require(accessController.isCronJob(msg.sender), Errors.OnlyCallableByCronJob());
        _;
    }

    // pause
    modifier onlyMonitor() {
        require(accessController.isMonitor(msg.sender), Errors.OnlyCallableByMonitor());
        _;
    }

    // for unpause + freeze 
    modifier onlyGlobalAdmin() {
        require(accessController.isGlobalAdmin(msg.sender), Errors.OnlyCallableByGlobalAdmin());
        _;
    }   
    
    // to exfil assets, when frozen
    modifier onlyEmergencyExitHandler() {
        require(accessController.isEmergencyExitHandler(msg.sender), Errors.OnlyCallableByEmergencyExitHandler());
        _;
    }


//-------------------------------Transfer ERC20 Overrides------------------------------------------------
    
    /**
     * @notice Transfers esMoca tokens to a specified address, restricted to whitelisted senders.
     * @dev Overrides ERC20 transfer. Only whitelisted addresses can initiate transfers; non-whitelisted senders are blocked.
     * @param recipient Address receiving the tokens.
     * @param amount Number of tokens to transfer.
     * @return success True if the transfer is permitted and succeeds.
     */
    function transfer(address recipient, uint256 amount) public override whenNotPaused returns (bool) {
        require(whitelist[msg.sender], Errors.OnlyCallableByWhitelistedAddress());
        return super.transfer(recipient, amount);
    }

    /**
     * @notice Transfers esMoca tokens from one address to another, restricted to whitelisted senders.
     * @dev Overrides ERC20 transferFrom. Only addresses present in the whitelist can initiate transfers; all others are blocked.
     * @param sender The address from which the tokens will be transferred from.
     * @param recipient The address to which the tokens will be transferred to.
     * @param amount The number of tokens to transfer.
     * @return success True if the transfer is permitted and succeeds.
     */
    function transferFrom(address sender, address recipient, uint256 amount) public override whenNotPaused returns (bool) {
        require(whitelist[msg.sender], Errors.OnlyCallableByWhitelistedAddress());
        return super.transferFrom(sender, recipient, amount);
    }

//-------------------------------Risk functions----------------------------------------------------------

    /**
     * @notice Pause the contract.
     * @dev Only callable by the Monitor [bot script].
     */
    function pause() external whenNotPaused onlyMonitor {
        _pause();
    }

    /**
     * @notice Unpause the contract.
     * @dev Only callable by the Global Admin [multi-sig].
     */
    function unpause() external whenPaused onlyGlobalAdmin {
        require(isFrozen == 0, Errors.IsFrozen()); 
        _unpause();
    }

    /**
     * @notice Freeze the contract.
     * @dev Only callable by the Global Admin [multi-sig].
     *      This is a kill switch function
     */
    function freeze() external whenPaused onlyGlobalAdmin {
        require(isFrozen == 0, Errors.IsFrozen());
        isFrozen = 1;
        emit Events.ContractFrozen();
    }

    /**
     * @notice Exfiltrate all esMoca held in the contract to the users.
     * @dev Intended for emergency use only when the contract is frozen.
     *      If called by a user, they should pass an array of length 1 with their own address.
     *      If called by the emergency exit handler, they should pass an array of length > 1 with the addresses of the users to exit.
     *      Note: does not clear mapping redemptionSchedule; this is a non-issue since the contract is frozen.
     * @param users Array of user addresses to exfiltrate esMoca for.
     */
    function emergencyExit(address[] calldata users) external payable {
        require(isFrozen == 1, Errors.NotFrozen());
        require(users.length > 0, Errors.InvalidArray());

        uint256 totalMocaAmount;
        for(uint256 i; i < users.length; ++i) {
            address user = users[i];

            // check: if NOT emergency exit handler, AND NOT, the user themselves: revert
            if (!accessController.isEmergencyExitHandler(msg.sender)) {
                if (msg.sender != user) {
                    revert Errors.OnlyCallableByEmergencyExitHandlerOrUser();
                }
            }

            // get user's esMoca balance
            uint256 esMocaBalance = balanceOf(user);
            uint256 userTotalPendingRedemptions = userTotalMocaPendingRedemption[user];

            // get user's total moca: balance + pending redemptions
            uint256 userTotalMoca = esMocaBalance + userTotalPendingRedemptions;
            if(userTotalMoca == 0) continue;

            // decrement esMoca balance 
            if(esMocaBalance > 0) _burn(user, esMocaBalance);

            // decrement pending redemptions [global + user]
            if(userTotalPendingRedemptions > 0) {
                delete userTotalMocaPendingRedemption[user];
                TOTAL_MOCA_PENDING_REDEMPTION -= userTotalPendingRedemptions;
            }

            // increment counter
            totalMocaAmount += userTotalMoca;

            // transfer moca [wraps if transfer fails within gas limit]
            _transferMocaAndWrapIfFailWithGasLimit(wMoca, user, userTotalMoca, MOCA_TRANSFER_GAS_LIMIT);
        }

        emit Events.EmergencyExitEscrowedMoca(users, totalMocaAmount);
    }

    /**
     * @notice Exfiltrate all accrued penalties from the contract to the esMoca treasury.
     * @dev Only callable by the Emergency Exit Handler role, when the contract is frozen.
     *      EsMoca treasury address is queried from AccessController.
     */
    function emergencyExitPenalties() external payable onlyEmergencyExitHandler {
        require(isFrozen == 1, Errors.NotFrozen());
        
        // get esMoca treasury address
        address esMocaTreasury = accessController.ESCROWED_MOCA_TREASURY();
        require(esMocaTreasury != address(0), Errors.InvalidAddress());

        // check: is there anything to claim?
        uint256 totalPenaltyAccrued = ACCRUED_PENALTY_TO_VOTERS + ACCRUED_PENALTY_TO_TREASURY;
        uint256 totalClaimable = totalPenaltyAccrued - CLAIMED_PENALTY_FROM_VOTERS - CLAIMED_PENALTY_FROM_TREASURY;
        require(totalClaimable > 0, Errors.NothingToClaim());

        // book claimed penalties
        CLAIMED_PENALTY_FROM_VOTERS = ACCRUED_PENALTY_TO_VOTERS;
        CLAIMED_PENALTY_FROM_TREASURY = ACCRUED_PENALTY_TO_TREASURY;
        
        // transfer moca [wraps if transfer fails within gas limit]
        _transferMocaAndWrapIfFailWithGasLimit(wMoca, esMocaTreasury, totalClaimable, MOCA_TRANSFER_GAS_LIMIT);

        emit Events.EmergencyExitPenalties(esMocaTreasury, totalClaimable);
    }
}