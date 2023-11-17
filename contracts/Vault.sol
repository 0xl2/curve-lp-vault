// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/ICVX.sol";
import "./interfaces/IBooster.sol";
import "./interfaces/ICurveRouter.sol";
import "./interfaces/IBaseRewardPool.sol";
import "./interfaces/IUniswapV3Router.sol";

error ZeroAmount();
error InvalidToken();

contract CurveLPVault is Ownable {
    using SafeERC20 for ICVX;
    using SafeERC20 for IERC20;

    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    IERC20 public constant CRVToken = IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
    ICVX public constant CVXToken = ICVX(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    IBooster public constant CVXBooster = IBooster(0xF403C135812408BFbE8713b5A23a04b3D48AAE31);
    IUniswapV3Router public constant UNIROUTER = IUniswapV3Router(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    IBaseRewardPool public immutable REWARDPOOL;

    IERC20 public lpToken;
    address public immutable firstUnderlying;
    uint public immutable lpPID;

    uint public totalDeposit;
    uint public crvPerShare;
    uint public cvxPerShare;

    uint internal constant MULTIPLIER = 1e18;

    mapping(address => bool) public depositTokens;
    mapping(address => UserInfo) public userInfo;
    struct UserInfo {
        uint amount;
        uint crvShare;
        uint cvxShare;
        uint crvPending;
        uint cvxPending;
    }

    Curve public CURVEINFO;
    struct Curve {
        ICurveRouter router;
        uint lpCnt;
    }

    event Deposit(address indexed account, address token, uint amount);
    event Withdraw(address indexed account, uint amount);
    event Claim(address indexed account, uint crvReward, uint cvxReward);

    constructor(address _lpToken, uint _lpPid, Curve memory _curveInfo) {
        lpToken = IERC20(_lpToken);
        lpPID = _lpPid;

        CURVEINFO = _curveInfo;

        firstUnderlying = CURVEINFO.router.coins(0);

        lpToken.safeApprove(address(CVXBooster), type(uint).max);

        REWARDPOOL = IBaseRewardPool(CVXBooster.poolInfo(_lpPid).crvRewards);
    }

    function setDepositTokens(address[] calldata tokens, bool flag) external onlyOwner {
        unchecked {
            for (uint i; i < tokens.length; ++i) {
                depositTokens[tokens[i]] = flag;
            }
        }
    }

    function _updateUserInfo(uint amount) internal {
        UserInfo storage info = userInfo[msg.sender];
        unchecked {
            if (crvPerShare > info.crvShare) {
                info.crvPending += (info.amount * (crvPerShare - info.crvShare)) / MULTIPLIER;
                info.crvShare = crvPerShare;
            }

            if (cvxPerShare > info.cvxShare) {
                info.cvxPending += (info.amount * (cvxPerShare - info.cvxShare)) / MULTIPLIER;
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

        if (cvxBalance != 0) cvxPerShare += (cvxBalance * MULTIPLIER) / totalDeposit;

        if (crvBalance != 0) crvPerShare += (crvBalance * MULTIPLIER) / totalDeposit;
    }

    function _getPending(UserInfo memory info) internal view returns (uint crvAmt, uint cvxAmt) {
        crvAmt = crvPerShare > info.crvShare
            ? info.crvPending + (info.amount * (crvPerShare - info.crvShare)) / MULTIPLIER
            : info.crvPending;

        cvxAmt = cvxPerShare > info.cvxShare
            ? info.cvxPending + (info.amount * (cvxPerShare - info.cvxShare)) / MULTIPLIER
            : info.cvxPending;
    }

    function _getCurveLP(uint _amountIn, bool _isETH) internal returns (uint amountOut) {
        amountOut = lpToken.balanceOf(address(this));

        if (!_isETH) IERC20(firstUnderlying).approve(address(CURVEINFO.router), _amountIn);
        if (CURVEINFO.lpCnt == 2) {
            uint[2] memory amounts;
            amounts[0] = _amountIn;

            CURVEINFO.router.add_liquidity{value: _isETH ? _amountIn : 0}(amounts, 0);
        } else if (CURVEINFO.lpCnt == 3) {
            uint[3] memory amounts;
            amounts[0] = _amountIn;

            CURVEINFO.router.add_liquidity{value: _isETH ? _amountIn : 0}(amounts, 0);
        } else if (CURVEINFO.lpCnt == 4) {
            uint[4] memory amounts;
            amounts[0] = _amountIn;

            CURVEINFO.router.add_liquidity{value: _isETH ? _amountIn : 0}(amounts, 0);
        }

        unchecked {
            amountOut = lpToken.balanceOf(address(this)) - amountOut;
        }
    }

    function _removeCurveLP(uint _amountIn, bool _isEth) internal returns (uint amountOut) {
        amountOut = _isEth ? address(this).balance : IERC20(firstUnderlying).balanceOf(address(this));

        lpToken.approve(address(CURVEINFO.router), _amountIn);
        CURVEINFO.router.remove_liquidity_one_coin(_amountIn, 0, 0);

        unchecked {
            amountOut = _isEth
                ? address(this).balance - amountOut
                : IERC20(firstUnderlying).balanceOf(address(this)) - amountOut;
        }
    }

    function _doSwap(address depositToken, uint amount, bool isETH) internal returns (uint amountOut) {
        if (!isETH) IERC20(depositToken).approve(address(UNIROUTER), amount);
        amountOut = UNIROUTER.exactInputSingle{value: isETH ? amount : 0}(
            IUniswapV3Router.ExactInputSingleParams(
                isETH ? WETH : depositToken,
                firstUnderlying,
                3000,
                payable(address(this)),
                block.timestamp + 2 hours,
                amount,
                0,
                0
            )
        );
    }

    function _withdrawSwap(
        uint tokenAmt,
        uint24 fee,
        IERC20 fromToken,
        address toToken
    ) internal returns (uint amountOut) {
        fromToken.approve(address(UNIROUTER), tokenAmt);

        if (toToken == WETH || toToken == address(0)) {
            amountOut = UNIROUTER.exactInputSingle(
                IUniswapV3Router.ExactInputSingleParams(
                    address(fromToken),
                    WETH,
                    fee,
                    payable(address(this)),
                    block.timestamp + 2 hours,
                    tokenAmt,
                    0,
                    0
                )
            );
        } else {
            bytes memory path = abi.encodePacked(address(CRVToken), fee, WETH, uint24(3000), toToken);
            amountOut = UNIROUTER.exactInput(
                IUniswapV3Router.ExactInputParams(path, address(this), block.timestamp + 2 hours, tokenAmt, 0)
            );
        }
    }

    function deposit(uint amount, address depositToken) external payable {
        bool isEth = depositToken == address(0);
        if (!depositTokens[depositToken]) revert InvalidToken();

        if (isEth) amount = msg.value;
        if (amount == 0) revert ZeroAmount();

        // get reward first
        _getReward(0, false);

        // transfer token then deposit
        if (!isEth) IERC20(depositToken).safeTransferFrom(msg.sender, address(this), amount);

        // swap on uniswapv3 if deposit token is not the first token
        if (firstUnderlying != depositToken) _doSwap(depositToken, amount, isEth);

        // then get lp
        amount = _getCurveLP(amount, firstUnderlying == WETH);

        // then deposit to convex
        CVXBooster.deposit(lpPID, amount, true);

        // update user info
        _updateUserInfo(amount);

        // update totalDeposit
        totalDeposit += amount;

        emit Deposit(msg.sender, depositToken, amount);
    }

    function withdraw(uint amount, bool doSwap, address swapToken) external {
        if (amount == 0) revert ZeroAmount();
        if (doSwap && !depositTokens[swapToken]) revert InvalidToken();

        UserInfo storage info = userInfo[msg.sender];
        if (amount > info.amount) amount = info.amount;

        if (amount == 0) return;

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
        if (doSwap) {
            if (crvAmt != 0) crvAmt = _withdrawSwap(crvAmt, 3e3, CRVToken, swapToken);
            if (cvxAmt != 0) crvAmt += _withdrawSwap(cvxAmt, 1e4, CVXToken, swapToken);
            if (crvAmt != 0) {
                IERC20(firstUnderlying).safeTransfer(msg.sender, crvAmt);
            }
        } else {
            if (crvAmt != 0) CRVToken.safeTransfer(msg.sender, crvAmt);
            if (cvxAmt != 0) CVXToken.safeTransfer(msg.sender, cvxAmt);
        }

        // lpToken.safeTransfer(msg.sender, amount);
        amount = _removeCurveLP(amount, firstUnderlying == WETH);
        if (amount != 0) IERC20(firstUnderlying).transfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount);
    }

    function claim(bool doSwap, address swapToken) external {
        if (doSwap && !depositTokens[swapToken]) revert InvalidToken();

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
        if (doSwap) {
            if (crvAmt != 0) crvAmt = _withdrawSwap(crvAmt, 3e3, CRVToken, swapToken);
            if (cvxAmt != 0) crvAmt += _withdrawSwap(cvxAmt, 1e4, CVXToken, swapToken);
            if (crvAmt != 0) {
                IERC20(firstUnderlying).safeTransfer(msg.sender, crvAmt);
            }
        } else {
            if (crvAmt != 0) CRVToken.safeTransfer(msg.sender, crvAmt);
            if (cvxAmt != 0) CVXToken.safeTransfer(msg.sender, cvxAmt);
        }

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

    function pendingReward(address account) external view returns (uint crvReward, uint cvxReward) {
        if (totalDeposit == 0) return (0, 0);

        crvReward = REWARDPOOL.earned(address(this));
        cvxReward = _getCVXReward(crvReward);

        uint _crvPerShare = crvReward == 0 ? crvPerShare : crvPerShare + ((crvReward * MULTIPLIER) / totalDeposit);
        uint _cvxPerShare = cvxReward == 0 ? cvxPerShare : cvxPerShare + ((cvxReward * MULTIPLIER) / totalDeposit);

        UserInfo memory info = userInfo[account];
        crvReward = info.crvPending + (info.amount * (_crvPerShare - info.crvShare)) / MULTIPLIER;

        cvxReward = info.cvxPending + (info.amount * (_cvxPerShare - info.cvxShare)) / MULTIPLIER;
    }
}
