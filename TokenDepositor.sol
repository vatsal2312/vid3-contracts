// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import {ERC20} from "./ERC20.sol";

error CustomError(string message);

contract TokenDepositor {
    function execute(
        ERC20 token,
        address[] memory addresses,
        uint256[] memory supplies
    ) public {
        if (addresses.length != supplies.length)
            revert CustomError("length of addresses is different");

        for (uint256 i = 0; i < addresses.length; i++) {
            token.transfer(address(addresses[i]), supplies[i]);
        }

        selfdestruct(payable(msg.sender));
    }
}
