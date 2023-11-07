// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IBooster.sol";
import "./interfaces/IBaseRewardPool.sol";

error ZeroAmount();

contract Vault is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public constant CRVToken =
        IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
    IERC20 public constant CVXToken =
        IERC20(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    // IClaimZap public constant CLAIMZAP =
    //     IClaimZap(0x3f29cB4111CbdA8081642DA1f75B3c12DECf2516);
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
    event Withdraw(address indexed account, uint256 amount);
    event Claim(address indexed account, uint256 crvReward, uint256 cvxReward);

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
                info.cvxPending +=
                    (info.amount * (cvxPerShare - info.cvxShare)) /
                    MULTIPLIER;
                info.cvxShare = cvxPerShare;
            }
        }

        if (amount != 0) info.amount += amount;
    }

    function _getReward(uint256 _amount, bool _withdraw) internal {
        if (totalDeposit == 0) return;

        uint256 cvxBalance = CVXToken.balanceOf(address(this));
        uint256 crvBalance = CRVToken.balanceOf(address(this));

        if (_withdraw) {
            REWARDPOOL.withdrawAndUnwrap(_amount, true);
        } else {
            REWARDPOOL.getReward();
        }

        unchecked {
            cvxBalance = CVXToken.balanceOf(address(this)) - cvxBalance;
            crvBalance = CRVToken.balanceOf(address(this)) - crvBalance;
        }

        if (cvxBalance != 0)
            cvxPerShare += (cvxBalance * MULTIPLIER) / totalDeposit;

        if (crvBalance != 0)
            crvPerShare += (crvBalance * MULTIPLIER) / totalDeposit;
    }

    function _getPending(
        UserInfo memory info
    ) internal view returns (uint256 crvAmt, uint256 cvxAmt) {
        crvAmt = crvPerShare > info.crvShare
            ? info.crvPending +
                (info.amount * (crvPerShare - info.crvShare)) /
                MULTIPLIER
            : info.crvPending;

        cvxAmt = cvxPerShare > info.cvxShare
            ? info.cvxPending +
                (info.amount * (cvxPerShare - info.cvxShare)) /
                MULTIPLIER
            : info.cvxPending;
    }

    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        // get reward first
        _getReward(0, false);

        // update user info
        _updateUserInfo(amount);

        // transfer token then deposit
        lpToken.safeTransferFrom(msg.sender, address(this), amount);
        CVXBooster.deposit(lpPID, amount, true);

        // update totalDeposit
        totalDeposit += amount;

        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        UserInfo storage info = userInfo[msg.sender];
        if (amount > info.amount) amount = info.amount;

        // get reward first
        _getReward(amount, true);

        // update user info
        (uint256 crvAmt, uint256 cvxAmt) = _getPending(info);
        unchecked {
            // if withdraw all them remove user info
            if (amount == info.amount) delete userInfo[msg.sender];
            else {
                info.amount -= amount;
                info.crvShare = crvPerShare;
                info.cvxShare = cvxPerShare;
                info.crvPending = 0;
                info.cvxPending = 0;
            }
        }

        // transfer tokens to user
        if (crvAmt != 0) CRVToken.safeTransfer(msg.sender, crvAmt);
        if (cvxAmt != 0) CVXToken.safeTransfer(msg.sender, cvxAmt);
        lpToken.safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount);
    }

    function claim() external {
        // get reward first
        _getReward(0, false);

        // update user info
        UserInfo storage info = userInfo[msg.sender];
        (uint256 crvAmt, uint256 cvxAmt) = _getPending(info);
        unchecked {
            info.crvShare = crvPerShare;
            info.cvxShare = cvxPerShare;
            info.crvPending = 0;
            info.cvxPending = 0;
        }

        // transfer tokens to user
        if (crvAmt != 0) CRVToken.safeTransfer(msg.sender, crvAmt);
        if (cvxAmt != 0) CVXToken.safeTransfer(msg.sender, cvxAmt);

        emit Claim(msg.sender, crvAmt, cvxAmt);
    }

    function pendingReward(
        address account
    ) external view returns (uint256 crvReward, uint256 cvxReward) {}
}
