// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IBaseRewardPool {
    function withdrawAndUnwrap(uint256 amount, bool claim) external;

    function getReward(
        address _account,
        bool _claimExtras
    ) external returns (bool);
}
