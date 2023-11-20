// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import {ERC20} from "./ERC20.sol";

contract Vid3Token is ERC20 {
    uint256 private constant SUPPLY = 100000000 * 10 ** 18;

    constructor(address tokenDepositor) ERC20("Vid3 Token", "VID3") {
        _mint(tokenDepositor, SUPPLY);
    }
}
