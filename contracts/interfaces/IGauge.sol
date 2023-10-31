// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface IGauge {
    function deposit(uint256 _value) external;

    function withdraw(uint256 _value) external;
}
