//SPDX-License-Identifier:MIT
pragma solidity ^0.8.27;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAaveV3Pool} from "./interface/IAaveV3Pool.sol";
import {ISwapRouter} from "./interface/ISwapRouter.sol";
import {IPriceOracle} from "./interface/IPriceOracle.sol";

contract LeverageLuidation {
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

    function depositCollateral(uint256 amount) external {
        IERC20(collateral).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(collateral).forceApprove(address(pool), amount);
        pool.supply(collateral, amount, address(this), REFERRAL_CODE);
    }

    function liquidateOnce(
        address target,
        uint256 desiredLockedBase,
        uint24 poolFee,
        uint256 slippageBps,
        bool supplyAcquired,
        uint256 maxDebtToCoverDebtUnits
    ) public {
        (uint256 tc, uint256 td,,,, uint256 hf) = pool.getUserAccountData(target);
        if (hf >= 1e18) return;

        uint256 debtBal = IERC20(debt).balanceOf(address(this));
        if (debtBal < maxDebtToCoverDebtUnits) {
            uint256 need = maxDebtToCoverDebtUnits - debtBal;
            uint256 collPrice = oracle.getAssetPrice(collateral);
            uint256 collDecimals = _decimals(collateral);
            uint256 minCollSpend = _tokenAmountFromBase(
                _baseFromToken(need, oracle.getAssetPrice(debt), _decimals(debt)), collPrice, collDecimals
            );
            IERC20(collateral).forceApprove(address(router), minCollSpend);
            uint256 minOut = (need * (10000 - slippageBps)) / 10000;
            router.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: collateral,
                    tokenOut: debt,
                    fee: poolFee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: minCollSpend,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        uint256 cover = maxDebtToCoverDebtUnits;
        IERC20(debt).forceApprove(address(pool), cover);
        pool.liquidationCall(collateral, debt, target, cover, false);

        uint256 received = IERC20(collateral).balanceOf(address(this));
        if (supplyAcquired && received > 0) {
            IERC20(collateral).forceApprove(address(pool), received);
            pool.supply(collateral, received, address(this), REFERRAL_CODE);
        }
    }

    function liquidateLoop(
        address target,
        uint256 desiredLockedBase,
        uint256 maxIterations,
        uint24 poolFee,
        uint256 slippageBps,
        bool supplyAcquired,
        uint256 maxDebtPerStep
    ) external {
        for (uint256 i = 0; i < maxIterations; i++) {
            (uint256 myC,,,,,) = pool.getUserAccountData(address(this));
            if (myC >= desiredLockedBase) break;
            liquidateOnce(target, desiredLockedBase, poolFee, slippageBps, supplyAcquired, maxDebtPerStep);
            (uint256 hfC,,,,,) = pool.getUserAccountData(target);
            if (hfC >= 1e18) break;
        }
    }

    function _decimals(address token) internal view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18;
        }
    }

    function _baseFromToken(uint256 amount, uint256 price, uint256 decimals) internal pure returns (uint256) {
        return (amount * price) / (10 ** decimals);
    }

    function _tokenAmountFromBase(uint256 baseAmount, uint256 price, uint256 decimals) internal pure returns (uint256) {
        return (baseAmount * (10 ** decimals)) / price;
    }
}

interface IERC20Metadata is IERC20 {
    function decimals() external view returns (uint8);
}
