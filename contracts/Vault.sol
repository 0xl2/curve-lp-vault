// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IGauge.sol";

error ZeroAddress;
error InvalidLPToken;

contract Vault is Ownable {
    using SafeERC20 for IERC20;

    address constant CRVToken = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant CVXToken = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;

    uint256 public totalDeposit;
    uint256 public accTokenPerShare;

    mapping(address => address) public curveGauge;
    mapping(address => UserInfo) public userInfo;
    struct UserInfo {
        uint256 amount;
        uint256 userShare;
        uint256 pendingAmt;
    }

    event UpdateLP(address indexed lp, address indexed gauge);

    function(address lp, address gauge) external onlyOwner {
        if(lp == address(0) || gauge == address(0)) revert ZeroAddress();

        curveGauge[lp] = gauge;

        emit UpdateLP(lp, gauge);
    }

    function deposit(address lp, uint256 amount) external {
        address storage gauge = curveGauge[lp];
        if(gauge == address(0)) revert InvalidLPToken();

        // transfer token first
        IERC20(lp).safeTransferFrom(msg.sender, address(this), amount);

        // approve and deposit to curve gauge
        IERC20(lp).approve(gauge, amount);
        IGauge(gauge).deposit(amount);

        // update user info

    }
}
