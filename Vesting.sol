// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import {Ownable} from "./Ownable.sol";
import {IERC20} from "./IERC20.sol";
import {ReentrancyGuard} from "./ReentrancyGuard.sol";

interface SaleContractInterface {
    function lockEndTime() external view returns (uint256);
}

contract Vesting is Ownable, ReentrancyGuard {
    uint256 public constant NUMBER_OF_EPOCHS = 31536000; // 1 year
    uint256 public constant EPOCH_DURATION = 1; // 1 second
    IERC20 private _vid3;
    SaleContractInterface private _saleContract;

    uint256 public lastClaimedEpoch;
    uint256 public totalDistributedBalance;

    constructor(
        address newOwner,
        address vid3TokenAddress,
        address saleContractAddress,
        uint256 totalBalance
    ) {
        transferOwnership(newOwner);
        _vid3 = IERC20(vid3TokenAddress);
        _saleContract = SaleContractInterface(saleContractAddress);
        totalDistributedBalance = totalBalance;
    }

    function claim() public virtual nonReentrant {
        claimInternal(owner());
    }

    function claimInternal(address to) internal {
        uint256 _balance;
        uint256 currentEpoch = getCurrentEpoch();
        if (currentEpoch > NUMBER_OF_EPOCHS + 1) {
            lastClaimedEpoch = NUMBER_OF_EPOCHS;
            _vid3.transfer(to, _vid3.balanceOf(address(this)));
            return;
        }

        if (currentEpoch > lastClaimedEpoch) {
            _balance =
                ((currentEpoch - 1 - lastClaimedEpoch) *
                    totalDistributedBalance) /
                NUMBER_OF_EPOCHS;
        }
        lastClaimedEpoch = currentEpoch - 1;
        if (_balance > 0) {
            _vid3.transfer(to, _balance);
            return;
        }
    }

    function balance() public view returns (uint256) {
        return _vid3.balanceOf(address(this));
    }

    function getCurrentEpoch() public view returns (uint256) {
        if (block.timestamp < _saleContract.lockEndTime()) return 0;
        return (block.timestamp - _saleContract.lockEndTime()) / EPOCH_DURATION + 1;
    }

    // default
    fallback() external {
        claim();
    }
}
