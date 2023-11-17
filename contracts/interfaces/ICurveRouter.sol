// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface ICurveRouter {
    function add_liquidity(uint256[2] memory, uint256) external payable;

    function add_liquidity(uint256[3] memory, uint256) external payable;

    function add_liquidity(uint256[4] memory, uint256) external payable;

    function remove_liquidity_one_coin(uint256, int128, uint256) external;

    function coins(uint256) external view returns (address);
}
