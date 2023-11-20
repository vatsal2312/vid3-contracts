// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title Sale contract with lock and vesting
contract TokenSaleWithLockupAndVesting is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20Metadata;

    bytes32 public constant KYC_ROLE = keccak256("KYC_ROLE");
    uint256 public constant EPOCH_DURATION = 1; // seconds
    uint256 public constant LOCK_DURATION = 365 days;
    uint256 public constant LOCK_UNSOLD_DURATION = 730 days;

    uint256 public immutable EARLY_ADAPTOR_PRICE = 400000; // 0.40$
    uint256 public immutable SALE_PRICE = 420000; // 0.42$
    uint256 public immutable NUMBER_OF_EPOCHS = 31536000; // seconds in a year
    IERC20Metadata public immutable USD_C_TOKEN;
    IERC20Metadata public immutable USD_T_TOKEN;
    IERC20Metadata public immutable VID_3_TOKEN;
    uint256 public immutable KYC_AMOUNT_REQUIRED = 15000;
    address public immutable TREASURY_ADDRESS;
    address public immutable WITHDRAW_UNSOLD_ADDRESS;
    uint256 public immutable VID_3_DECIMALS;
    uint256 public immutable SALE_START_TIME;
    uint256 public immutable PRESALE_END_TIME;
    uint256 public immutable SALE_END_TIME;
    uint256 public immutable TOTAL_TOKENS_TO_SELL;
    uint256 private lockUnsoldEndTime;
    bool private unsoldTokensWithdrawn;

    uint256 public lockEndTime;
    /// @dev How many tokens are already sold
    uint256 public totalTokensSold;

    struct Lockup {
        uint256 amount;
        uint256 totalBalance;
        uint256 totalSpent;
        bool purchaseLimitReached;
        uint256 lastClaimedEpoch;
    }

    mapping(address => Lockup) public lockedBalances;
    mapping(address => bool) public whitelisted;

    event TokensPurchased(
        address indexed buyer,
        uint256 amount,
        uint256 lockedAmount
    );
    event AddressWhitelisted(address indexed addr, bool isWhitelisted);
    event Claim(address indexed addr, uint256 amount);
    event Withdraw(
        address indexed sender,
        address indexed receiver,
        uint256 amount
    );

    error CustomError(string message);

    constructor(
        address _usdCToken,
        address _usdTToken,
        address _vid3Token,
        address _treasuryAddress,
        address _kycAddress,
        address _withdrawAddress,
        uint256 _totalTokensToSell,
        uint256 _saleStartTime,
        uint256 _presaleEndTime,
        uint256 _saleEndTime
    ) {
        USD_C_TOKEN = IERC20Metadata(_usdCToken);
        USD_T_TOKEN = IERC20Metadata(_usdTToken);
        VID_3_TOKEN = IERC20Metadata(_vid3Token);
        TREASURY_ADDRESS = _treasuryAddress;
        VID_3_DECIMALS = VID_3_TOKEN.decimals();
        TOTAL_TOKENS_TO_SELL = _totalTokensToSell;
        SALE_START_TIME = _saleStartTime;
        PRESALE_END_TIME = _presaleEndTime;
        SALE_END_TIME = _saleEndTime;
        lockEndTime = _saleEndTime + LOCK_DURATION;
        lockUnsoldEndTime = _saleEndTime + LOCK_UNSOLD_DURATION;
        WITHDRAW_UNSOLD_ADDRESS = _withdrawAddress;

        _setupRole(KYC_ROLE, _kycAddress);
    }
    /// @dev Method to whitelist or blacklist
    /// @param _addr is the address to be whitelisted
    /// @param _isWhitelisted true/false in order to whitelist or not
    function whitelistAddress(
        address _addr,
        bool _isWhitelisted
    ) external onlyRole(KYC_ROLE) {
        whitelisted[_addr] = _isWhitelisted;
        emit AddressWhitelisted(_addr, _isWhitelisted);
    }
    /// @dev Method to buy with usdc
    /// @param _amountToSpend is the amount of usdc the buyer want to spend
    /// @notice _amountToSpend need to be with decimals (e.g. 100 USD = 100000000)
    /// @notice before calling this method the buyer needs to approve contract to spend this usdt amount from his wallet
    function buyWithUsdC(uint256 _amountToSpend) external nonReentrant {
        buyTokens(_amountToSpend, USD_C_TOKEN);
    }

    /// @dev Method to buy with usdt
    /// @param _amountToSpend is the amount of usdt the buyer want to spend
    /// @notice _amountToSpend need to be with decimals (e.g. 100 USD = 100000000)
    /// @notice before calling this method the buyer needs to approve contract to spend this usdc amount from his wallet
    function buyWithUsdT(uint256 _amountToSpend) external nonReentrant {
        buyTokens(_amountToSpend, USD_T_TOKEN);
    }

    /// @dev Method to claim tokens for another address
    /// @param _addr wallet address for which the user wants to claim
    function claimFromOtherAddress(address _addr) external nonReentrant {
        claimInternal(_addr);
    }

    /// @dev Method to claim tokens for wallet who calls it
    function claim() external nonReentrant {
        claimInternal(msg.sender);
    }

    /// @dev Method to withdraw all unsold tokens
    function withdrawUnsoldTokens() external nonReentrant {
        withdrawUnsoldTokensInternal();
    }

    /// @dev Method to get how many tokens an user already bought
    function getBalance() external view returns (uint256) {
        Lockup storage lockup = lockedBalances[msg.sender];
        return lockup.amount;
    }

    /// @dev Method to get last claimed epoch an user already claimed
    function getLastClaimedEpoch() external view returns (uint256) {
        Lockup storage lockup = lockedBalances[msg.sender];
        return lockup.lastClaimedEpoch;
    }

    /// @dev Method to get current epoch
    function getCurrentEpoch() public view returns (uint256) {
        if (block.timestamp < lockEndTime) return 0;
        return (block.timestamp - lockEndTime) / EPOCH_DURATION + 1;
    }

    function buyTokens(
        uint256 _amountToSpend,
        IERC20Metadata payToken
    ) internal {
        Lockup storage lockup = lockedBalances[msg.sender];
        if (
            block.timestamp < SALE_START_TIME || block.timestamp > SALE_END_TIME
        ) {
            revert CustomError("BUY: Sale ended or started yet");
        }
        if (_amountToSpend == 0) {
            revert CustomError("BUY: Amount must be > than 0");
        }

        if (
            lockup.totalSpent + _amountToSpend >=
            (KYC_AMOUNT_REQUIRED * (10 ** payToken.decimals()))
        ) {
            if (!whitelisted[msg.sender]) {
                revert CustomError("BUY: Buyer must be whitelisted");
            }
            if (lockup.purchaseLimitReached) {
                revert CustomError("BUY: Buyer reached limit");
            }
        }
        if (TOTAL_TOKENS_TO_SELL == totalTokensSold) {
            revert CustomError("BUY: No tokens left for sale");
        }

        (uint256 _amountToBuy, uint256 _amountSpent) = calculatePurchase(
            _amountToSpend,
            block.timestamp
        );

        if (_amountToBuy == 0) {
            revert CustomError("BUY: Invalid token amount");
        }

        payToken.safeTransferFrom(msg.sender, TREASURY_ADDRESS, _amountSpent);

        lockup.amount = lockup.amount + _amountToBuy;
        lockup.totalBalance = lockup.amount;
        lockup.totalSpent = lockup.totalSpent + _amountSpent;
        lockup.purchaseLimitReached =
            lockup.totalSpent + _amountSpent >=
            (KYC_AMOUNT_REQUIRED * (10 ** payToken.decimals()));
        totalTokensSold = totalTokensSold + _amountToBuy;

        if (totalTokensSold == TOTAL_TOKENS_TO_SELL) {
            lockEndTime = block.timestamp + LOCK_DURATION;
            lockUnsoldEndTime = block.timestamp + LOCK_UNSOLD_DURATION;
        }

        emit TokensPurchased(msg.sender, _amountToBuy, lockup.amount);
    }

    function calculatePurchase(
        uint256 amountToSpend,
        uint256 timestamp
    ) internal view returns (uint256 _amountToBuy, uint256 _amountSpent) {
        if (timestamp < PRESALE_END_TIME) {
            uint256 lowerPriceAmount = (amountToSpend *
                (10 ** VID_3_DECIMALS)) / EARLY_ADAPTOR_PRICE;
            if (lowerPriceAmount + totalTokensSold > TOTAL_TOKENS_TO_SELL) {
                uint256 overflow = lowerPriceAmount +
                    totalTokensSold -
                    TOTAL_TOKENS_TO_SELL;
                _amountToBuy = lowerPriceAmount - overflow;
                _amountSpent =
                    (_amountToBuy * EARLY_ADAPTOR_PRICE) /
                    (10 ** VID_3_DECIMALS);
            } else {
                _amountToBuy = ((amountToSpend * (10 ** VID_3_DECIMALS)) /
                    EARLY_ADAPTOR_PRICE);
                _amountSpent = amountToSpend;
            }
        } else {
            uint256 higherPriceAmount = (amountToSpend *
                (10 ** VID_3_DECIMALS)) / SALE_PRICE;
            if (higherPriceAmount + totalTokensSold > TOTAL_TOKENS_TO_SELL) {
                uint256 overflow = higherPriceAmount +
                    totalTokensSold -
                    TOTAL_TOKENS_TO_SELL;
                _amountToBuy = higherPriceAmount - overflow;
                _amountSpent =
                    (_amountToBuy * SALE_PRICE) /
                    (10 ** VID_3_DECIMALS);
            } else {
                _amountToBuy = ((amountToSpend * (10 ** VID_3_DECIMALS)) /
                    SALE_PRICE);
                _amountSpent = amountToSpend;
            }
        }

        return (_amountToBuy, _amountSpent);
    }

    function claimInternal(address tokenOwner) internal {
        Lockup storage lockup = lockedBalances[tokenOwner];
        if (block.timestamp < lockEndTime) {
            revert CustomError("CLAIM: Tokens are still locked");
        }
        if (lockup.amount == 0) {
            revert CustomError("CLAIM: No tokens to release");
        }

        uint256 balance;
        uint256 currentEpoch = getCurrentEpoch();
        if (currentEpoch > NUMBER_OF_EPOCHS + 1) {
            lockup.lastClaimedEpoch = NUMBER_OF_EPOCHS;
            VID_3_TOKEN.transfer(tokenOwner, lockup.amount);
            lockup.amount = 0;
            emit Claim(tokenOwner, lockup.amount);
            return;
        }

        if (currentEpoch > lockup.lastClaimedEpoch) {
            balance =
                ((currentEpoch - 1 - lockup.lastClaimedEpoch) *
                    lockup.totalBalance) /
                NUMBER_OF_EPOCHS;
        }
        lockup.lastClaimedEpoch = currentEpoch - 1;
        if (balance > 0) {
            VID_3_TOKEN.transfer(tokenOwner, balance);
            lockup.amount = lockup.amount - balance;
            emit Claim(tokenOwner, balance);
            return;
        }
    }

    function withdrawUnsoldTokensInternal() internal {
        if (block.timestamp < lockUnsoldEndTime) {
            revert CustomError("WDR: Unsold tokens are still locked");
        }
        if (totalTokensSold == TOTAL_TOKENS_TO_SELL) {
            revert CustomError("WDR: All tokens are sold");
        }
        if (unsoldTokensWithdrawn) {
            revert CustomError("WDR: Tokens already withdrawn");
        }
        unsoldTokensWithdrawn = true;

        VID_3_TOKEN.transfer(
            WITHDRAW_UNSOLD_ADDRESS,
            TOTAL_TOKENS_TO_SELL - totalTokensSold
        );
        emit Withdraw(
            msg.sender,
            WITHDRAW_UNSOLD_ADDRESS,
            TOTAL_TOKENS_TO_SELL - totalTokensSold
        );
    }

    // default
    fallback() external {
        claimInternal(msg.sender);
    }
}
