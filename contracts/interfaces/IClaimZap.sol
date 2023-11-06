// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IClaimZap {
    function claimRewards(
        address[] memory rewardContracts,
        address[] memory extraRewardContracts,
        address[] memory tokenRewardContracts,
        address[] memory tokenRewardTokens,
        uint256 depositCrvMaxAmount,
        uint256 minAmountOut,
        uint256 depositCvxMaxAmount,
        uint256 spendCvxAmount,
        uint256 options
    ) external;
}
