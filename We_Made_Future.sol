// contracts/GLDToken.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract We_Made_Future_Token is ERC20 {
    constructor(uint256 initialSupply) ERC20("We_Made_Future", "WMF") {
        _mint(msg.sender, initialSupply);
    }
}
