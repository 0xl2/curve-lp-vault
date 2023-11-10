// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/ICVX.sol";
import "./interfaces/IBooster.sol";
import "./interfaces/IBaseRewardPool.sol";

import "hardhat/console.sol";

error ZeroAmount();

contract Vault {
    using SafeERC20 for ICVX;
    using SafeERC20 for IERC20;

    IERC20 public constant CRVToken =
        IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
    ICVX public constant CVXToken =
        ICVX(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    // IClaimZap public constant CLAIMZAP =
    //     IClaimZap(0x3f29cB4111CbdA8081642DA1f75B3c12DECf2516);
    IBooster public constant CVXBooster =
        IBooster(0xF403C135812408BFbE8713b5A23a04b3D48AAE31);
    IBaseRewardPool public immutable REWARDPOOL;

    IERC20 public lpToken;
    uint public immutable lpPID;

    uint public totalDeposit;
    uint public crvPerShare;
    uint public cvxPerShare;

    uint internal constant MULTIPLIER = 1e18;

    mapping(address => UserInfo) public userInfo;
    struct UserInfo {
        uint amount;
        uint crvShare;
        uint cvxShare;
        uint crvPending;
        uint cvxPending;
    }

    event Deposit(address indexed account, uint amount);
    event Withdraw(address indexed account, uint amount);
    event Claim(address indexed account, uint crvReward, uint cvxReward);

    constructor(address _lpToken, uint _lpPid) {
        lpToken = IERC20(_lpToken);
        lpPID = _lpPid;

        lpToken.safeApprove(address(CVXBooster), type(uint).max);

        REWARDPOOL = IBaseRewardPool(CVXBooster.poolInfo(_lpPid).crvRewards);
    }

    function _updateUserInfo(uint amount) internal {
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

    function _getReward(uint _amount, bool _withdraw) internal {
        if (totalDeposit == 0) return;

        uint cvxBalance = CVXToken.balanceOf(address(this));
        uint crvBalance = CRVToken.balanceOf(address(this));

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
    ) internal view returns (uint crvAmt, uint cvxAmt) {
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

    function deposit(uint amount) external {
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

    function withdraw(uint amount) external {
        if (amount == 0) revert ZeroAmount();

        UserInfo storage info = userInfo[msg.sender];
        if (amount > info.amount) amount = info.amount;

        // get reward first
        _getReward(amount, true);

        // update user info
        (uint crvAmt, uint cvxAmt) = _getPending(info);
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
        (uint crvAmt, uint cvxAmt) = _getPending(info);
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

    function _getCVXReward(uint _amount) private view returns (uint) {
        uint supply = CVXToken.totalSupply();
        if (supply == 0) {
            return _amount;
        }

        uint reductionPerCliff = CVXToken.reductionPerCliff();
        uint totalCliffs = CVXToken.totalCliffs();
        uint maxSupply = CVXToken.maxSupply();

        uint cliff = supply / reductionPerCliff;
        if (cliff < totalCliffs) {
            uint reduction = totalCliffs - cliff;
            _amount = (_amount * reduction) / totalCliffs;

            //supply cap check
            uint amtTillMax = maxSupply - supply;
            if (_amount > amtTillMax) {
                _amount = amtTillMax;
            }
        }

        return _amount;
    }

    function pendingReward(
        address account
    ) external view returns (uint crvReward, uint cvxReward) {
        if (totalDeposit == 0) return (0, 0);

        crvReward = REWARDPOOL.earned(address(this));
        cvxReward = _getCVXReward(crvReward);

        uint _crvPerShare = crvReward == 0
            ? crvPerShare
            : crvPerShare + ((crvReward * MULTIPLIER) / totalDeposit);
        uint _cvxPerShare = cvxReward == 0
            ? cvxPerShare
            : cvxPerShare + ((cvxReward * MULTIPLIER) / totalDeposit);

        UserInfo memory info = userInfo[account];
        crvReward =
            info.crvPending +
            (info.amount * (_crvPerShare - info.crvShare)) /
            MULTIPLIER;

        cvxReward =
            info.cvxPending +
            (info.amount * (_cvxPerShare - info.cvxShare)) /
            MULTIPLIER;
    }
}
