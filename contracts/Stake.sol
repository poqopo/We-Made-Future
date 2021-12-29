// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IStake.sol";
import "./interfaces/IWe_Made_Future.sol";

contract Stake is IStake, Ownable {

  /// @notice We_Made_Future token
  IWe_Made_Future public We_Made_Future;

  constructor(
    IWe_Made_Future _We_Made_Future
  ) public {
    We_Made_Future = _We_Made_Future;
  }

  /// @notice Safe We_Made_Future transfer function, just in case if rounding error causes pool to not have enough We_Made_Futures.
  /// @param _to The address to transfer We_Made_Future to
  /// @param _amount The amount to transfer to
  function safeWe_Made_FutureTransfer(address _to, uint256 _amount) external override onlyOwner {
    uint256 We_Made_FutureBal = We_Made_Future.balanceOf(address(this));
    if (_amount > We_Made_FutureBal) {
      We_Made_Future.transfer(_to, We_Made_FutureBal);
    } else {
      We_Made_Future.transfer(_to, _amount);
    }
  }
}