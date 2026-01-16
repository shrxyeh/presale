// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*
    TokenAirdrop.sol (updated)
  - Added subscription system (USDT payment).
  - Only subscribed users can receive swap rewards.
  - Owner (platform) calls rewardForSwap to credit subscribed users.
  - Existing features (allocations, withdraws, pausable, reentrancy, recover) intact.
*/

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Airdrop is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public rewardToken;

    // subscription payment token (e.g. USDT)
    IERC20 public usdtToken;

    // allocation (total assigned) and claimed amounts per user
    mapping(address => uint256) public referRewardAllocation;
    mapping(address => uint256) public referRewardClaimed;

    mapping(address => uint256) public swapRewardAllocation;
    mapping(address => uint256) public swapRewardClaimed;

    mapping(address => bool) public walletEligible;
    mapping(address => bool) public walletRewardClaimed;

    // subscription expiry timestamp per user (unix seconds)
    mapping(address => uint256) public subscriptionExpiry;

    uint256 public totalClaimed;
    uint256 public walletRewardAmount; // fixed reward amount for wallet reward claim

    // subscription parameters
    uint256 public subscriptionFee; // amount in USDT token decimals
    uint256 public subscriptionDuration; // seconds

    event RewardTokenSet(address indexed token);
    event USDTTokenSet(address indexed token);
    event SubscriptionParamsSet(uint256 fee, uint256 duration);
    event Subscribed(address indexed user, uint256 expiry, uint256 fee);
    event SubscriptionCancelled(address indexed user);
    
    event ReferRewardAllocation(address indexed to, uint256 added, uint256 newTotal);
    event ReferRewardAllocationBatch(uint256 count);
    event ReferRewardAllocationRemoved(address indexed to, uint256 amount); // updated by tarun
    event ReferRewardClaimed(address indexed user, uint256 amount);
    
    event SwapRewardAllocation(address indexed to, uint256 added, uint256 newTotal);
    event SwapRewardAllocationBatch(uint256 count);
    event SwapRewardAllocationRemoved(address indexed to, uint256 amount);
    event SwapRewardClaimed(address indexed user, uint256 amount); 

    event WalletRewardClaimed(address indexed user, uint256 amount);
    event WalletRewardAmountSet(uint256 amount); // Added by Tarun for 


    event EmergencyWithdraw(address indexed to, uint256 amount);
    event RecoveredERC20(address indexed token, address indexed to, uint256 amount);
    event USDTWithdrawn(address indexed to, uint256 amount);

    

    constructor(IERC20 _rewardToken) Ownable(msg.sender) ReentrancyGuard() Pausable() {
        require(address(_rewardToken) != address(0), "BigRockAirdrop: zero token");
        rewardToken = _rewardToken;
        emit RewardTokenSet(address(_rewardToken));
    }

    /* ========== USER FUNCTIONS ========== */

    function withdrawReferReward() external nonReentrant whenNotPaused {
        address user = msg.sender;
        uint256 assigned = referRewardAllocation[user];
        require(assigned > 0, "BigRockAirdrop: no allocation");

        uint256 already = referRewardClaimed[user];
        require(assigned > already, "BigRockAirdrop: already claimed");

        uint256 amount = assigned - already;
        uint256 balance = rewardToken.balanceOf(address(this));
        require(balance >= amount, "BigRockAirdrop: insufficient balance");

        // state update before external call
        referRewardClaimed[user] = referRewardClaimed[user] + amount;
        totalClaimed += amount;

        rewardToken.safeTransfer(user, amount);
        emit ReferRewardClaimed(user, amount);
    }

      function withdrawSwapReward() external nonReentrant whenNotPaused {
        address user = msg.sender;
        uint256 assigned = swapRewardAllocation[user];
        require(assigned > 0, "BigRockAirdrop: no allocation");

        uint256 already = swapRewardClaimed[user];
        require(assigned > already, "BigRockAirdrop: already claimed");

        uint256 amount = assigned - already;
        uint256 balance = rewardToken.balanceOf(address(this));
        require(balance >= amount, "BigRockAirdrop: insufficient balance");
        require(isSubscribed(user), "Subscription expired");


        // state update before external call
        swapRewardClaimed[user] = swapRewardClaimed[user] + amount;
        totalClaimed += amount;

        rewardToken.safeTransfer(user, amount);
        emit SwapRewardClaimed(user, amount);
    }

    function withdrawWalletReward() external nonReentrant whenNotPaused {
        address user = msg.sender;
        
        require(walletEligible[user], "BigRockAirdrop: wallet not eligible");
        require(!walletRewardClaimed[user], "BigRockAirdrop: wallet reward already claimed");
        require(walletRewardAmount > 0, "Wallet Reward Not Set");

        uint256 balance = rewardToken.balanceOf(address(this));
        require(balance >= walletRewardAmount, "BigRockAirdrop: insufficient balance");

        walletRewardClaimed[user] = true;
        totalClaimed += walletRewardAmount; // ADDED BY TARUN TO UPDATE TOTAL CLAIMED AMOUNT

        rewardToken.safeTransfer(user, walletRewardAmount);
        emit WalletRewardClaimed(user, walletRewardAmount);
    }

    /* ========== SUBSCRIPTION ========== */

    /// @notice Subscribe by paying subscriptionFee in usdtToken. Must approve first.
    function subscribe() external nonReentrant whenNotPaused {
        require(address(usdtToken) != address(0), "BigRockAirdrop: usdt not set");
        require(subscriptionFee > 0 && subscriptionDuration > 0, "BigRockAirdrop: sub params not set");

        address user = msg.sender;
        // transfer USDT
        usdtToken.safeTransferFrom(user, address(this), subscriptionFee);

        // extend existing subscription or set new
        uint256 newExpiry = block.timestamp + subscriptionDuration;
        if (subscriptionExpiry[user] > block.timestamp) {
            // extend from current expiry for convenience
            newExpiry = subscriptionExpiry[user] + subscriptionDuration;
        }
        subscriptionExpiry[user] = newExpiry;

        emit Subscribed(user, newExpiry, subscriptionFee);
    }

    /// @notice Owner can cancel a user's subscription (set to expired) [BY TARUN : WE NEED TO ADD THIS NON REFUNDABLE POLICY IN TERMS & CONDISTIONS]
    function cancelSubscription(address user) external onlyOwner {
        require(user != address(0), "BigRockAirdrop: zero addr");
        subscriptionExpiry[user] = 0;
        emit SubscriptionCancelled(user);
    }

    /// @notice Check if user is currently subscribed
    function isSubscribed(address user) public view returns (bool) {
        return subscriptionExpiry[user] > block.timestamp;
    }


    /* ========== OWNER FUNCTIONS ========== */

    function setRewardToken(IERC20 _token) external onlyOwner {
        require(address(_token) != address(0), "BigRockAirdrop: zero token");
        rewardToken = _token;
        emit RewardTokenSet(address(_token));
    }

    function setUSDTToken(IERC20 _usdt) external onlyOwner {
        require(address(_usdt) != address(0), "BigRockAirdrop: zero token");
        usdtToken = _usdt;
        emit USDTTokenSet(address(_usdt));
    }

    /// @notice Set subscription fee (in usdt token units) and duration (seconds)
    function setSubscriptionParams(uint256 _fee, uint256 _duration) external onlyOwner {
        require(_duration > 0, "BigRockAirdrop: zero duration");
        require(_fee > 0, "BigRockAirdrop: zero fee"); // Added by Tarun for safety

        subscriptionFee = _fee;
        subscriptionDuration = _duration;
        emit SubscriptionParamsSet(_fee, _duration);
    }

    function setWalletRewardAmount(uint256 amount) external onlyOwner {
        walletRewardAmount = amount;
        emit WalletRewardAmountSet(amount); // added by tarun

    }

    /**
     * @notice Increase allocation for _to by _amount.
     * This adds to the previous allocation (does not overwrite).
     */
    function setReferRewardAllocation(address _to, uint256 _amount) external onlyOwner whenNotPaused {
        require(_to != address(0), "BigRockAirdrop: zero addr");
        require(_amount > 0, "BigRockAirdrop: zero amount");
        require(rewardToken.balanceOf(address(this)) >= _amount, "insufficient balance"); // added by tarun

referRewardAllocation[_to] = referRewardAllocation[_to] + _amount; // safe under Solidity ^0.8 (checked)
        emit ReferRewardAllocation(_to, _amount, referRewardAllocation[_to]);
    }
    
    function setSwapRewardAllocation(address _to, uint256 _amount) external onlyOwner whenNotPaused {
        require(_to != address(0), "BigRockAirdrop: zero address");
        require(_amount > 0, "BigRockAirdrop: zero amount");
        require(isSubscribed(_to), "BigRockAirdrop: user not subscribed");

        require(rewardToken.balanceOf(address(this)) >= _amount, "insufficient balance"); // added by tarun

        swapRewardAllocation[_to] = swapRewardAllocation[_to] + _amount; // safe under Solidity ^0.8 (checked)
        emit SwapRewardAllocation(_to, _amount, swapRewardAllocation[_to]);
    }

    /**
     * @notice Increase allocations in batch. Each _amounts[i] is added to _tos[i].
     */
    function setReferRewardAllocationBatch(address[] calldata _tos, uint256[] calldata _amounts) external onlyOwner whenNotPaused {
        require(_tos.length == _amounts.length, "BigRockAirdrop: length mismatch");
        uint256 len = _tos.length;
        for (uint256 i = 0; i < len; ++i) {
            address to = _tos[i];
            uint256 amount = _amounts[i];
            require(to != address(0), "BigRockAirdrop: zero addr in batch");
            require(amount > 0, "BigRockAirdrop: zero amount in batch");
            referRewardAllocation[to] = referRewardAllocation[to] + amount;
            emit ReferRewardAllocation(to, amount, referRewardAllocation[to]);
        }
        emit ReferRewardAllocationBatch(len);
    }

     function setSwapRewardAllocationBatch(address[] calldata _tos, uint256[] calldata _amounts) external onlyOwner whenNotPaused {
        require(_tos.length == _amounts.length, "BigRockAirdrop: length mismatch");
        uint256 len = _tos.length;
        for (uint256 i = 0; i < len; ++i) {
            address to = _tos[i];
            uint256 amount = _amounts[i];
            require(to != address(0), "BigRockAirdrop: zero addr in batch");
            require(amount > 0, "BigRockAirdrop: zero amount in batch");
            require(isSubscribed(to), "BigRockAirdrop: user not subscribed");
            
            swapRewardAllocation[to] = swapRewardAllocation[to] + amount;
            emit SwapRewardAllocation(to, amount, swapRewardAllocation[to]);
        }
        emit SwapRewardAllocationBatch(len);
    }

    function removeRewardAllocation(address _to, uint256 amount) external onlyOwner whenNotPaused {
        require(_to != address(0), "BigRockAirdrop: zero addr");
        require(amount > 0 , "BigRockAirdrop: zero amount");
        require(referRewardAllocation[_to] >= amount, "BigRockAirdrop: amount exceeds allocation");
        
        referRewardAllocation[_to] = referRewardAllocation[_to] - amount;
        emit ReferRewardAllocationRemoved(_to,amount);
        }

    function removeSwapAllocation(address _to, uint256 amount) external onlyOwner whenNotPaused {
        require(_to != address(0), "Airdrop: zero addr");
        require(amount > 0 , "Airdrop: zero amount");
        require(swapRewardAllocation[_to] >= amount, "Airdrop: amount exceeds allocation");

        swapRewardAllocation[_to] = swapRewardAllocation[_to] - amount;
        emit SwapRewardAllocationRemoved(_to,amount);
    }
    
    function setWalletEligible(address user, bool status) external onlyOwner {
    walletEligible[user] = status;
}


    function setWalletEligibleBatch(
        address[] calldata users,
        bool[] calldata statuses
    ) external onlyOwner {

    require(users.length == statuses.length, "BigRockAirdrop: length mismatch");

    uint256 len = users.length;

      for (uint256 i = 0; i < len; ++i) {
        address user = users[i];
        require(user != address(0), "BigRockAirdrop: zero address");
        walletEligible[user] = statuses[i];
    }
}


    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

/**
     * @dev Emergency withdraw all reward tokens to _to. Only when paused.
     * Does not change user allocations.
     */
    function emergencyWithdraw(address _to) external onlyOwner whenPaused {
        require(_to != address(0), "BigRockAirdrop: zero addr");
        uint256 bal = rewardToken.balanceOf(address(this));
        require(bal > 0, "BigRockAirdrop: no funds");
        rewardToken.safeTransfer(_to, bal);
        emit EmergencyWithdraw(_to, bal);
    }

    function withdrawUSDT(address to, uint256 amount) external onlyOwner {
    require(address(usdtToken) != address(0), "USDT not set");
    require(to != address(0), "Zero address");

    uint256 balance = usdtToken.balanceOf(address(this));
    require(balance >= amount, "Insufficient USDT balance");

    usdtToken.safeTransfer(to, amount);
    emit USDTWithdrawn(to, amount);

}

    function recoverERC20(IERC20 token, address to, uint256 amount) external onlyOwner {
        require(address(token) != address(0), "BigRockAirdrop: zero token");
        require(to != address(0), "BigRockAirdrop: zero to");
        token.safeTransfer(to, amount);
        emit RecoveredERC20(address(token), to, amount);
    }


     /* ========== VIEW ========== */

    function contractBalance() external view returns (uint256) {
        return rewardToken.balanceOf(address(this));
    }

    function usdtBalance() external view returns (uint256) {
    if (address(usdtToken) == address(0)) {
        return 0;
    }
    return usdtToken.balanceOf(address(this));
}


    function getUserRewardState(address user)
    external
    view
    returns (
        bool walletClaimable,
        uint256 referPending,
        uint256 swapPending
    )
{
    walletClaimable =
        walletEligible[user] &&
        !walletRewardClaimed[user] &&
        walletRewardAmount > 0;

    referPending =
        referRewardAllocation[user] -
        referRewardClaimed[user];

    swapPending =
        isSubscribed(user)
            ? swapRewardAllocation[user] - swapRewardClaimed[user]
            : 0;
}

function getUserClaimableAmounts(address user)
    external
    view
    returns (
        uint256 walletAmount,
        uint256 referAmount,
        uint256 swapAmount
    )
{
    walletAmount =
        walletEligible[user] &&
        !walletRewardClaimed[user]
            ? walletRewardAmount
            : 0;

    referAmount =
        referRewardAllocation[user] -
        referRewardClaimed[user];

    swapAmount =
        isSubscribed(user)
            ? swapRewardAllocation[user] - swapRewardClaimed[user]
            : 0;
}

function getUserStatus(address user)
    external
    view
    returns (
        bool subscribed,
        bool walletEligible_,
        bool walletClaimed,
        uint256 subscriptionExpiry_
    )
{
    subscribed = subscriptionExpiry[user] > block.timestamp;
    walletEligible_ = walletEligible[user];
    walletClaimed = walletRewardClaimed[user];
    subscriptionExpiry_ = subscriptionExpiry[user];
}

function getAdminBalances()
    external
    view
    returns (
        uint256 rewardTokenBalance,
        uint256 usdtTokenBalance
    )
{
    rewardTokenBalance = rewardToken.balanceOf(address(this));
    usdtTokenBalance =
        address(usdtToken) == address(0)
            ? 0
            : usdtToken.balanceOf(address(this));
}

function getSubscriptionInfo(address user)
    external
    view
    returns (
        bool active,
        uint256 expiry,
        uint256 fee,
        uint256 duration
    )
{
    active = subscriptionExpiry[user] > block.timestamp;
    expiry = subscriptionExpiry[user];
    fee = subscriptionFee;
    duration = subscriptionDuration;
}



}

