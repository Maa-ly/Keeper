// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAaveV3Pool} from "./interface/IAaveV3Pool.sol";
import {ISwapRouter} from "./interface/ISwapRouter.sol";
import {IPriceOracle} from "./interface/IPriceOracle.sol";

contract LeverageLooper {
    using SafeERC20 for IERC20;

    IAaveV3Pool public immutable pool;
    ISwapRouter public immutable router;
    IPriceOracle public immutable oracle;

    address public immutable collateral;
    address public immutable debt;

    uint16 public constant REFERRAL_CODE = 0;
    uint256 public constant INTEREST_RATE_MODE_VARIABLE = 2;
    uint256 public constant ORACLE_PRICE_DECIMALS = 8;

    constructor(address _pool, address _router, address _oracle, address _collateral, address _debt) {
        require(_pool != address(0) && _router != address(0) && _oracle != address(0));
        require(_collateral != address(0) && _debt != address(0));
        pool = IAaveV3Pool(_pool);
        router = ISwapRouter(_router);
        oracle = IPriceOracle(_oracle);
        collateral = _collateral;
        debt = _debt;
    }

    function optInAndLoop(
        uint256 supplyAmount,
        uint256 targetLTVBps,
        uint256 maxIterations,
        uint24 poolFee,
        uint256 slippageBps,
        uint256 minHealthFactor
    ) external {
        IERC20(collateral).safeTransferFrom(msg.sender, address(this), supplyAmount);
        IERC20(collateral).forceApprove(address(pool), supplyAmount);
        pool.supply(collateral, supplyAmount, address(this), REFERRAL_CODE);

        for (uint256 i = 0; i < maxIterations; i++) {
            (
                uint256 totalCollateralBase,
                uint256 totalDebtBase,
                uint256 availableBorrowsBase,,
                uint256 ltv,
                uint256 health
            ) = pool.getUserAccountData(address(this));
            if (ltv >= targetLTVBps) break;
            if (availableBorrowsBase == 0) break;

            uint256 targetDebtBase = (totalCollateralBase * targetLTVBps) / 10000;
            if (targetDebtBase <= totalDebtBase) break;
            uint256 addDebtBase = targetDebtBase - totalDebtBase;
            if (addDebtBase > availableBorrowsBase) addDebtBase = availableBorrowsBase;

            uint256 debtPrice = oracle.getAssetPrice(debt);
            uint256 borrowAmount = _baseToToken(addDebtBase, debtPrice, _decimals(debt));
            pool.borrow(debt, borrowAmount, INTEREST_RATE_MODE_VARIABLE, REFERRAL_CODE, address(this));

            IERC20(debt).forceApprove(address(router), borrowAmount);
            uint256 expectedOut = _baseToToken(addDebtBase, oracle.getAssetPrice(collateral), _decimals(collateral));
            uint256 minOut = (expectedOut * (10000 - slippageBps)) / 10000;
            uint256 amountOut = router.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: debt,
                    tokenOut: collateral,
                    fee: poolFee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: borrowAmount,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            );

            IERC20(collateral).forceApprove(address(pool), amountOut);
            pool.supply(collateral, amountOut, address(this), REFERRAL_CODE);

            (,,,,, health) = pool.getUserAccountData(address(this));
            if (health < minHealthFactor) break;
        }
    }

    function unwindToLTV(uint256 targetLTVBps, uint256 maxIterations, uint24 poolFee, uint256 slippageBps) external {
        for (uint256 i = 0; i < maxIterations; i++) {
            (uint256 totalCollateralBase, uint256 totalDebtBase,,, uint256 ltv,) =
                pool.getUserAccountData(address(this));
            if (ltv <= targetLTVBps || totalDebtBase == 0) break;
            uint256 targetDebtBase = (totalCollateralBase * targetLTVBps) / 10000;
            uint256 repayBase = totalDebtBase - targetDebtBase;
            uint256 spendCollateral = _baseToToken(repayBase, oracle.getAssetPrice(collateral), _decimals(collateral));
            pool.withdraw(collateral, spendCollateral, address(this));
            IERC20(collateral).forceApprove(address(router), spendCollateral);
            uint256 expectedDebtOut = _baseToToken(repayBase, oracle.getAssetPrice(debt), _decimals(debt));
            uint256 minDebtOut = (expectedDebtOut * (10000 - slippageBps)) / 10000;
            uint256 debtOut = router.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: collateral,
                    tokenOut: debt,
                    fee: poolFee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: spendCollateral,
                    amountOutMinimum: minDebtOut,
                    sqrtPriceLimitX96: 0
                })
            );
            IERC20(debt).forceApprove(address(pool), debtOut);
            pool.repay(debt, debtOut, INTEREST_RATE_MODE_VARIABLE, address(this));
        }
    }

    function _baseToToken(uint256 baseAmount, uint256 price, uint256 tokenDecimals) internal pure returns (uint256) {
        return (baseAmount * (10 ** tokenDecimals)) / price;
    }

    function _decimals(address token) internal view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18;
        }
    }
}

interface IERC20Metadata is IERC20 {
    function decimals() external view returns (uint8);
}
