// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IBooster.sol";
import "./interfaces/IClaimZap.sol";
import "./interfaces/IBaseRewardPool.sol";

error ZeroAmount();

contract Vault is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public constant CRVToken =
        IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
    IERC20 public constant CVXToken =
        IERC20(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    IClaimZap public constant CLAIMZAP =
        IClaimZap(0x3f29cB4111CbdA8081642DA1f75B3c12DECf2516);
    IBooster public constant CVXBooster =
        IBooster(0xF403C135812408BFbE8713b5A23a04b3D48AAE31);
    IBaseRewardPool public immutable REWARDPOOL;

    IERC20 public lpToken;
    uint256 public immutable lpPID;

    uint256 public totalDeposit;
    uint256 public crvPerShare;
    uint256 public cvxPerShare;

    uint256 internal constant MULTIPLIER = 1e18;

    mapping(address => UserInfo) public userInfo;
    struct UserInfo {
        uint256 amount;
        uint256 crvShare;
        uint256 cvxShare;
        uint256 crvPending;
        uint256 cvxPending;
    }

    event Deposit(address indexed account, uint256 amount);

    constructor(address _lpToken, uint256 _lpPid) {
        lpToken = IERC20(_lpToken);
        lpPID = _lpPid;

        lpToken.approve(address(CVXBooster), type(uint256).max);

        REWARDPOOL = IBaseRewardPool(CVXBooster.poolInfo(_lpPid).crvRewards);
    }

    function _updateUserInfo(uint256 amount) internal {
        UserInfo storage info = userInfo[msg.sender];
        unchecked {
            if (crvPerShare > info.crvShare) {
                info.crvPending +=
                    (info.amount * (crvPerShare - info.crvShare)) /
                    MULTIPLIER;
                info.crvShare = crvPerShare;
            }

            if (cvxPerShare > info.cvxShare) {
                info.cvxShare +=
                    (info.amount * (cvxPerShare - info.cvxShare)) /
                    MULTIPLIER;
                info.cvxShare = cvxPerShare;
            }
        }

        if (amount != 0) info.amount += amount;
    }

    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        // transfer token first
        lpToken.safeTransferFrom(msg.sender, address(this), amount);

        // deposit to convex
        CVXBooster.deposit(lpPID, amount, true);

        // update user info
        _updateUserInfo(amount);

        // update totalDeposit
        totalDeposit += amount;

        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        UserInfo storage info = userInfo[msg.sender];
        if (amount > info.amount) amount = info.amount;

        //
    }
}
