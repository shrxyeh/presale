
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


contract BigrockPresale is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    IERC20 public immutable token; // BIGROCK
    IERC20 public immutable usdt;

    uint256 public constant TOTAL_LOTS = 2000;
    uint256 public constant MONTH = 30 days;
    uint256 public constant PRESALE_CAP = 2500000000;
    uint256 public constant TOKENS_PER_LOT = 1250000;

    uint256 public tokenPrice;
    uint256 public totalLotsSold;
    uint256 public LOT_PRICE_USDT; // BSC USDT 

    uint256 public launchTimestamp; 
    uint256 public claimEnableTime;

    bool public launchTimestampSet;

    struct UserInfo {
        uint256 lotsBought;
        uint256 totalTokens;
        uint256 claimedTokens;
    }

    mapping(address => UserInfo) public users;

    event TokensPurchased(address indexed user, uint256 lots, uint256 tokens);
    event TokensClaimed(address indexed user, uint256 amount);
    event PresalePriceUpdated(uint256 newPrice);
    event LaunchTimestampSet(uint256 timestamp);
    event ClaimEnableTimeSet(uint256 timestamp);
    event USDTWithdrawn(uint256 amount);
    event EmergencyWithdraw(address indexed to, uint256 amount);
    

    constructor(
        address _token,
        address _usdt,
        uint256 _initialTokenPrice
    ) Ownable(msg.sender) {
        token = IERC20(_token);
        usdt = IERC20(_usdt);
        tokenPrice = _initialTokenPrice;
        updateLotPrice(_initialTokenPrice);
    }

    function updateLotPrice(uint256 _newPrice) internal  {
        LOT_PRICE_USDT = _newPrice * TOKENS_PER_LOT;
    }
    

    /* ===================== BUY ===================== */

    function buyLots(uint256 lots) external nonReentrant whenNotPaused {
        require(lots > 0, "Invalid lots");
        require(totalLotsSold + lots <= TOTAL_LOTS, "Presale sold out");
        require((totalLotsSold + lots) * TOKENS_PER_LOT <= PRESALE_CAP,"Presale cap exceeded");


        uint256 cost = LOT_PRICE_USDT * lots;
        usdt.safeTransferFrom(msg.sender, address(this), cost);

        uint256 tokensToAllocate = TOKENS_PER_LOT * lots;

        UserInfo storage user = users[msg.sender];
        user.lotsBought += lots;
        user.totalTokens += tokensToAllocate*1e18;

        totalLotsSold += lots;

        emit TokensPurchased(msg.sender, lots, tokensToAllocate*1e18);
    }

    /* ===================== CLAIM ===================== */

    function claimTokens() external nonReentrant {
        require(launchTimestampSet, "Launch not set");
        require(block.timestamp >= claimEnableTime, "Claims not enabled");

        uint256 claimable = getClaimable(msg.sender);
        require(claimable > 0, "Nothing to claim");

        users[msg.sender].claimedTokens += claimable;
        token.safeTransfer(msg.sender, claimable);

        emit TokensClaimed(msg.sender, claimable);
    }

    function getClaimable(address userAddr) public view returns (uint256) {
        UserInfo memory user = users[userAddr];
        if (user.totalTokens == 0) return 0;

        uint256 unlocked;

        if (block.timestamp < launchTimestamp + MONTH) {
            unlocked = (user.totalTokens * 10) / 100;
        } else {
            uint256 vestedTime = block.timestamp - (launchTimestamp + MONTH);
            if (vestedTime >= 12 * MONTH) {
                unlocked = user.totalTokens;
            } else {
                uint256 vested = (user.totalTokens * 90 * vestedTime) / (100 * 12 * MONTH);
                unlocked = (user.totalTokens * 10) / 100 + vested;
            }
        }

        if (unlocked <= user.claimedTokens) return 0;
        return unlocked - user.claimedTokens;
    }

    /* ===================== ADMIN ===================== */

    function setPresalePrice(uint256 newPrice) external onlyOwner {
        require(newPrice > 0, "Invalid price");
        tokenPrice = newPrice;
        updateLotPrice(newPrice);
        emit PresalePriceUpdated(newPrice);
    }

    function setLaunchTimestamp(uint256 _launchTimestamp) external onlyOwner {
        require(!launchTimestampSet, "Launch already set");
        require(totalLotsSold == TOTAL_LOTS, "Presale not completed");
        launchTimestamp = _launchTimestamp;
        launchTimestampSet = true;

        emit LaunchTimestampSet(_launchTimestamp);
    }

    function setClaimEnableTime(uint256 _time) external onlyOwner {
        require(launchTimestampSet, "Launch not set");
        require(_time <= launchTimestamp, "Invalid claim time");

        claimEnableTime = _time;
        emit ClaimEnableTimeSet(_time);
    }

    function withdrawAllUSDT() external onlyOwner {
        uint256 balance = usdt.balanceOf(address(this));
        require(balance > 0, "No USDT to withdraw");
        usdt.safeTransfer(owner(), balance);
        emit USDTWithdrawn(balance);
    }

    function emergencyWithdrawAllTokens(address to)
    external
    onlyOwner
    whenPaused
{
    require(to != address(0), "Invalid address");

    uint256 balance = token.balanceOf(address(this));
    require(balance > 0, "No tokens to withdraw");

    token.safeTransfer(to, balance);
}

function updateLaunchTimestamp(uint256 newLaunchTimestamp)
    external
    onlyOwner
{
    require(launchTimestampSet, "Launch not set");
    require(block.timestamp < launchTimestamp, "Launch already started");
    require(newLaunchTimestamp > block.timestamp, "Invalid launch time");

    launchTimestamp = newLaunchTimestamp;

    emit LaunchTimestampSet(newLaunchTimestamp);
}

function updateClaimEnableTime(uint256 newClaimEnableTime)
    external
    onlyOwner
{
    require(launchTimestampSet, "Launch not set");
    require(block.timestamp < launchTimestamp, "Launch already started");
    require(newClaimEnableTime <= launchTimestamp, "Invalid claim time");

    claimEnableTime = newClaimEnableTime;

    emit ClaimEnableTimeSet(newClaimEnableTime);
}




    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // View Function
    function getPresaleStats()
    external
    view
    returns (
        uint256 lotPriceUsdt,
        uint256 totalSold,
        bool isPaused,
        uint256 _tokenPrice,
        uint256 tokensPerLot,
        uint256 _launchTimestamp,
        uint256 _claimEnableTime
    )
{
    return (
        LOT_PRICE_USDT,
        totalLotsSold,
        paused(),
        tokenPrice,
        TOKENS_PER_LOT,
        launchTimestamp,
        claimEnableTime
    );
}

function getUserPresaleInfo(address user)
    external
    view
    returns (
        uint256 lotsBought,
        uint256 totalTokens,
        uint256 claimedTokens,
        uint256 claimable
    )
{
    UserInfo memory u = users[user];

    return (
        u.lotsBought,
        u.totalTokens,
        u.claimedTokens,
        getClaimable(user)
    );
}
}
