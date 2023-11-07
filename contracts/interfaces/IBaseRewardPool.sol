// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IBaseRewardPool {
    function withdrawAndUnwrap(uint256 amount, bool claim) external;

    function getReward() external returns (bool);
}
