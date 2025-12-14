// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAaveV3Pool} from "./interface/IAaveV3Pool.sol";
import {ISwapRouter} from "./interface/ISwapRouter.sol";
import {IPriceOracle} from "./interface/IPriceOracle.sol";
import {AbstractReactive} from "../lib/reactive-lib/src/abstract-base/AbstractReactive.sol";
import {IReactive} from "../lib/reactive-lib/src/interfaces/IReactive.sol";

contract LeverageLooper is AbstractReactive {
    using SafeERC20 for IERC20;

    IAaveV3Pool public immutable POOL;
    ISwapRouter public immutable ROUTER;
    IPriceOracle public immutable ORACLE;

    address public immutable COLLATERAL;
    address public immutable DEBT;

    uint16 public constant REFERRAL_CODE = 0;
    uint256 public constant INTEREST_RATE_MODE_VARIABLE = 2;
    uint256 public constant ORACLE_PRICE_DECIMALS = 8;

    struct ChainConfig {
        ISwapRouter router;
        IAaveV3Pool pool;
        IPriceOracle oracle;
        address collateral;
        address debt;
        uint24 fee;
    }

    mapping(uint256 => ChainConfig) public chainCfg;
    mapping(uint256 => uint256) public lastPrice;

    uint256 public minDiffBps;
    uint256 public arbAmount;
    uint256 public arbSlippageBps;
    uint256 public baselineNetBase;
    address public destLooper;
    uint256 public destChainId;
    uint64 public callbackGasLimit;

    constructor(address _pool, address _router, address _oracle, address _collateral, address _debt) {
        require(_pool != address(0) && _router != address(0) && _oracle != address(0));
        require(_collateral != address(0) && _debt != address(0));
        POOL = IAaveV3Pool(_pool);
        ROUTER = ISwapRouter(_router);
        ORACLE = IPriceOracle(_oracle);
        COLLATERAL = _collateral;
        DEBT = _debt;

        minDiffBps = 300;
        arbAmount = 1000e6;
        arbSlippageBps = 100;
        callbackGasLimit = 2000000;
    }

    function setChain(
        uint256 chainId,
        address _router,
        address _pool,
        address _oracle,
        address _collateral,
        address _debt,
        uint24 _fee
    ) external {
        chainCfg[chainId] = ChainConfig(
            ISwapRouter(_router), IAaveV3Pool(_pool), IPriceOracle(_oracle), _collateral, _debt, _fee
        );
    }

    function setArbParams(uint256 _minDiffBps, uint256 _arbAmount, uint256 _slippageBps) external {
        minDiffBps = _minDiffBps;
        arbAmount = _arbAmount;
        arbSlippageBps = _slippageBps;
    }

    function setDestination(address looper, uint256 chainId) external rnOnly {
        destLooper = looper;
        destChainId = chainId;
    }

    function setCallbackGasLimit(uint64 gasLimit) external rnOnly {
        callbackGasLimit = gasLimit;
    }

    function optInAndLoop(
        uint256 supplyAmount,
        uint256 targetLTVBps,
        uint256 maxIterations,
        uint24 poolFee,
        uint256 slippageBps,
        uint256 minHealthFactor,
        uint256 profitTargetBase
    ) public {
        _maybeArb();
        IERC20(COLLATERAL).safeTransferFrom(msg.sender, address(this), supplyAmount);
        IERC20(COLLATERAL).forceApprove(address(POOL), supplyAmount);
        POOL.supply(COLLATERAL, supplyAmount, address(this), REFERRAL_CODE);
        baselineNetBase = _netBase();

        for (uint256 i = 0; i < maxIterations; i++) {
            (
                uint256 totalCollateralBase,
                uint256 totalDebtBase,
                uint256 availableBorrowsBase,,
                uint256 ltv,
                uint256 health
            ) = POOL.getUserAccountData(address(this));
            if (ltv >= targetLTVBps) break;
            if (availableBorrowsBase == 0) break;
            if (profitTargetBase > 0) {
                uint256 netNow = _netBase();
                if (netNow >= baselineNetBase + profitTargetBase) break;
            }

            uint256 targetDebtBase = (totalCollateralBase * targetLTVBps) / 10000;
            if (targetDebtBase <= totalDebtBase) break;
            uint256 addDebtBase = targetDebtBase - totalDebtBase;
            if (addDebtBase > availableBorrowsBase) addDebtBase = availableBorrowsBase;

            uint256 debtPrice = ORACLE.getAssetPrice(DEBT);
            uint256 borrowAmount = _baseToToken(addDebtBase, debtPrice, _decimals(DEBT));
            POOL.borrow(DEBT, borrowAmount, INTEREST_RATE_MODE_VARIABLE, REFERRAL_CODE, address(this));

            IERC20(DEBT).forceApprove(address(ROUTER), borrowAmount);
            uint256 expectedOut = _baseToToken(addDebtBase, ORACLE.getAssetPrice(COLLATERAL), _decimals(COLLATERAL));
            uint256 minOut = (expectedOut * (10000 - slippageBps)) / 10000;
            uint256 amountOut = ROUTER.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: DEBT,
                    tokenOut: COLLATERAL,
                    fee: poolFee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: borrowAmount,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            );

            IERC20(COLLATERAL).forceApprove(address(POOL), amountOut);
            POOL.supply(COLLATERAL, amountOut, address(this), REFERRAL_CODE);

            (,,,,, health) = POOL.getUserAccountData(address(this));
            if (health < minHealthFactor) break;
        }
    }

    function optInFromUser(
        address user,
        uint256 supplyAmount,
        uint256 targetLtvBps,
        uint256 maxIterations,
        uint24 poolFee,
        uint256 slippageBps,
        uint256 minHealthFactor,
        uint256 profitTargetBase
    ) public {
        _maybeArb();
        IERC20(COLLATERAL).safeTransferFrom(user, address(this), supplyAmount);
        IERC20(COLLATERAL).forceApprove(address(POOL), supplyAmount);
        POOL.supply(COLLATERAL, supplyAmount, address(this), REFERRAL_CODE);
        baselineNetBase = _netBase();

        for (uint256 i = 0; i < maxIterations; i++) {
            (
                uint256 totalCollateralBase,
                uint256 totalDebtBase,
                uint256 availableBorrowsBase,,
                uint256 ltv,
                uint256 health
            ) = POOL.getUserAccountData(address(this));
            if (ltv >= targetLtvBps) break;
            if (availableBorrowsBase == 0) break;
            if (profitTargetBase > 0) {
                uint256 netNow = _netBase();
                if (netNow >= baselineNetBase + profitTargetBase) break;
            }

            uint256 targetDebtBase = (totalCollateralBase * targetLtvBps) / 10000;
            if (targetDebtBase <= totalDebtBase) break;
            uint256 addDebtBase = targetDebtBase - totalDebtBase;
            if (addDebtBase > availableBorrowsBase) addDebtBase = availableBorrowsBase;

            uint256 debtPrice = ORACLE.getAssetPrice(DEBT);
            uint256 borrowAmount = _baseToToken(addDebtBase, debtPrice, _decimals(DEBT));
            POOL.borrow(DEBT, borrowAmount, INTEREST_RATE_MODE_VARIABLE, REFERRAL_CODE, address(this));

            IERC20(DEBT).forceApprove(address(ROUTER), borrowAmount);
            uint256 expectedOut = _baseToToken(addDebtBase, ORACLE.getAssetPrice(COLLATERAL), _decimals(COLLATERAL));
            uint256 minOut = (expectedOut * (10000 - slippageBps)) / 10000;
            uint256 amountOut = ROUTER.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: DEBT,
                    tokenOut: COLLATERAL,
                    fee: poolFee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: borrowAmount,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            );

            IERC20(COLLATERAL).forceApprove(address(POOL), amountOut);
            POOL.supply(COLLATERAL, amountOut, address(this), REFERRAL_CODE);

            (,,,,, health) = POOL.getUserAccountData(address(this));
            if (health < minHealthFactor) break;
        }
    }

    function unwindToLtv(uint256 targetLtvBps, uint256 maxIterations, uint24 poolFee, uint256 slippageBps) public {
        for (uint256 i = 0; i < maxIterations; i++) {
            (uint256 totalCollateralBase, uint256 totalDebtBase,,, uint256 ltv,) =
                POOL.getUserAccountData(address(this));
            if (ltv <= targetLtvBps || totalDebtBase == 0) break;
            uint256 targetDebtBase = (totalCollateralBase * targetLtvBps) / 10000;
            uint256 repayBase = totalDebtBase - targetDebtBase;
            uint256 spendCollateral = _baseToToken(repayBase, ORACLE.getAssetPrice(COLLATERAL), _decimals(COLLATERAL));
            POOL.withdraw(COLLATERAL, spendCollateral, address(this));
            IERC20(COLLATERAL).forceApprove(address(ROUTER), spendCollateral);
            uint256 expectedDebtOut = _baseToToken(repayBase, ORACLE.getAssetPrice(DEBT), _decimals(DEBT));
            uint256 minDebtOut = (expectedDebtOut * (10000 - slippageBps)) / 10000;
            uint256 debtOut = ROUTER.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: COLLATERAL,
                    tokenOut: DEBT,
                    fee: poolFee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: spendCollateral,
                    amountOutMinimum: minDebtOut,
                    sqrtPriceLimitX96: 0
                })
            );
            IERC20(DEBT).forceApprove(address(POOL), debtOut);
            POOL.repay(DEBT, debtOut, INTEREST_RATE_MODE_VARIABLE, address(this));
        }
    }

    function liquidateLoop(
        address target,
        uint256 maxIterations,
        uint256 maxDebtPerStep,
        uint24 poolFee,
        uint256 slippageBps
    ) public {
        for (uint256 i = 0; i < maxIterations; i++) {
            (,,,,, uint256 hf) = POOL.getUserAccountData(target);
            if (hf >= 1e18) break;

            uint256 debtBal = IERC20(DEBT).balanceOf(address(this));
            if (debtBal < maxDebtPerStep) {
                uint256 need = maxDebtPerStep - debtBal;
                IERC20(COLLATERAL).forceApprove(address(ROUTER), need);
                uint256 minOut = (need * (10000 - slippageBps)) / 10000;
                ROUTER.exactInputSingle(
                    ISwapRouter.ExactInputSingleParams({
                        tokenIn: COLLATERAL,
                        tokenOut: DEBT,
                        fee: poolFee,
                        recipient: address(this),
                        deadline: block.timestamp,
                        amountIn: need,
                        amountOutMinimum: minOut,
                        sqrtPriceLimitX96: 0
                    })
                );
            }

            IERC20(DEBT).forceApprove(address(POOL), maxDebtPerStep);
            POOL.liquidationCall(COLLATERAL, DEBT, target, maxDebtPerStep, false);
        }
    }

    function loopToTvl(
        uint256 targetCollateralBase,
        uint256 maxIterations,
        uint24 poolFee,
        uint256 slippageBps,
        address liquidationTarget,
        uint256 maxDebtPerStep
    ) public {
        for (uint256 i = 0; i < maxIterations; i++) {
            _maybeArb();
            (uint256 totalCollateralBase,,,,,) = POOL.getUserAccountData(address(this));
            if (totalCollateralBase >= targetCollateralBase) break;

            uint256 deltaBase = targetCollateralBase - totalCollateralBase;
            uint256 needColl = _baseToToken(deltaBase, ORACLE.getAssetPrice(COLLATERAL), _decimals(COLLATERAL));
            uint256 collBal = IERC20(COLLATERAL).balanceOf(address(this));
            if (collBal < needColl) {
                uint256 amountIn = _baseToToken(deltaBase, ORACLE.getAssetPrice(DEBT), _decimals(DEBT));
                uint256 debtBal = IERC20(DEBT).balanceOf(address(this));
                if (amountIn > debtBal) amountIn = debtBal;
                if (amountIn > 0) {
                    IERC20(DEBT).forceApprove(address(ROUTER), amountIn);
                    uint256 expectedOut = _baseToToken(
                        _tokenToBase(amountIn, ORACLE.getAssetPrice(DEBT), _decimals(DEBT)),
                        ORACLE.getAssetPrice(COLLATERAL),
                        _decimals(COLLATERAL)
                    );
                    uint256 minOut = (expectedOut * (10000 - slippageBps)) / 10000;
                    ROUTER.exactInputSingle(
                        ISwapRouter.ExactInputSingleParams({
                            tokenIn: DEBT,
                            tokenOut: COLLATERAL,
                            fee: poolFee,
                            recipient: address(this),
                            deadline: block.timestamp,
                            amountIn: amountIn,
                            amountOutMinimum: minOut,
                            sqrtPriceLimitX96: 0
                        })
                    );
                }
            }

            collBal = IERC20(COLLATERAL).balanceOf(address(this));
            if (collBal > 0) {
                IERC20(COLLATERAL).forceApprove(address(POOL), collBal);
                POOL.supply(COLLATERAL, collBal, address(this), REFERRAL_CODE);
            }

            if (liquidationTarget != address(0)) {
                (,,,,, uint256 hf) = POOL.getUserAccountData(liquidationTarget);
                if (hf < 1e18) {
                    liquidateLoop(liquidationTarget, 1, maxDebtPerStep, poolFee, slippageBps);
                }
            }
        }
    }

    function react(IReactive.LogRecord calldata log) external override {
        uint256 t0 = log.topic_0;
        bytes memory payload = log.data;
        if (t0 == uint256(keccak256("PriceUpdate(uint256)"))) {
            uint256 price = abi.decode(payload, (uint256));
            lastPrice[log.chain_id] = price;
            if (vm) {
                emit Callback(destChainId, destLooper, callbackGasLimit, abi.encodeWithSelector(this.maybeArb.selector));
            } else {
                _maybeArb();
            }
        } else if (t0 == uint256(keccak256("HealthBelow(address)"))) {
            (address target) = abi.decode(payload, (address));
            if (vm) {
                emit Callback(
                    destChainId,
                    destLooper,
                    callbackGasLimit,
                    abi.encodeWithSelector(this.liquidateLoop.selector, target, 3, arbAmount, 3000, arbSlippageBps)
                );
            } else {
                liquidateLoop(target, 3, arbAmount, 3000, arbSlippageBps);
            }
        } else if (t0 == uint256(keccak256("UserOptIn(address,uint256,uint256,uint24,uint256,uint256,uint256)"))) {
            (
                address user,
                uint256 supplyAmount,
                uint256 targetLTVBps,
                uint256 maxIterations,
                uint24 poolFee,
                uint256 slippageBps,
                uint256 minHealthFactor,
                uint256 profitTargetBase
            ) = abi.decode(payload, (address, uint256, uint256, uint256, uint24, uint256, uint256, uint256));
            if (vm) {
                emit Callback(
                    destChainId,
                    destLooper,
                    callbackGasLimit,
                    abi.encodeWithSelector(
                        this.optInFromUser.selector,
                        user,
                        supplyAmount,
                        targetLTVBps,
                        maxIterations,
                        poolFee,
                        slippageBps,
                        minHealthFactor,
                        profitTargetBase
                    )
                );
            } else {
                IERC20(COLLATERAL).safeTransferFrom(user, address(this), supplyAmount);
                optInAndLoop(
                    supplyAmount, targetLTVBps, maxIterations, poolFee, slippageBps, minHealthFactor, profitTargetBase
                );
            }
        } else if (t0 == uint256(keccak256("Unwind(uint256,uint256,uint24,uint256)"))) {
            (uint256 targetLTVBps, uint256 maxIterations, uint24 poolFee, uint256 slippageBps) =
                abi.decode(payload, (uint256, uint256, uint24, uint256));
            if (vm) {
                emit Callback(
                    destChainId,
                    destLooper,
                    callbackGasLimit,
                    abi.encodeWithSelector(this.unwindToLtv.selector, targetLTVBps, maxIterations, poolFee, slippageBps)
                );
            } else {
                unwindToLtv(targetLTVBps, maxIterations, poolFee, slippageBps);
            }
        } else if (t0 == uint256(keccak256("LoopToTVL(uint256,uint256,uint24,uint256,address,uint256)"))) {
            (
                uint256 targetCollateralBase,
                uint256 maxIterations,
                uint24 poolFee,
                uint256 slippageBps,
                address liquidationTarget,
                uint256 maxDebtPerStep
            ) = abi.decode(payload, (uint256, uint256, uint24, uint256, address, uint256));
            if (vm) {
                emit Callback(
                    destChainId,
                    destLooper,
                    callbackGasLimit,
                    abi.encodeWithSelector(
                        this.loopToTvl.selector,
                        targetCollateralBase,
                        maxIterations,
                        poolFee,
                        slippageBps,
                        liquidationTarget,
                        maxDebtPerStep
                    )
                );
            } else {
                loopToTvl(targetCollateralBase, maxIterations, poolFee, slippageBps, liquidationTarget, maxDebtPerStep);
            }
        }
    }

    function maybeArb() external {
        _maybeArb();
    }

    function subscribe(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3
    ) external rnOnly {
        service.subscribe(chain_id, _contract, topic_0, topic_1, topic_2, topic_3);
    }

    function _maybeArb() internal {
        uint256 a = 1; // example chain id key
        uint256 b = 0; // paired chain id key
        if (lastPrice[a] == 0 || lastPrice[b] == 0) return;
        uint256 pa = lastPrice[a];
        uint256 pb = lastPrice[b];
        if (pa + (pa * minDiffBps) / 10000 <= pb) {
            _arb(a, b);
        } else if (pb + (pb * minDiffBps) / 10000 <= pa) {
            _arb(b, a);
        }
    }

    function _arb(uint256 lowChain, uint256 highChain) internal {
        ChainConfig memory cl = chainCfg[lowChain];
        ChainConfig memory ch = chainCfg[highChain];
        if (address(cl.router) == address(0) || address(ch.router) == address(0)) return;

        IERC20(cl.debt).forceApprove(address(cl.router), arbAmount);
        uint256 minEth = _baseToToken(arbAmount, cl.oracle.getAssetPrice(cl.collateral), _decimals(cl.collateral));
        minEth = (minEth * (10000 - arbSlippageBps)) / 10000;
        cl.router
            .exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: cl.debt,
                    tokenOut: cl.collateral,
                    fee: cl.fee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: arbAmount,
                    amountOutMinimum: minEth,
                    sqrtPriceLimitX96: 0
                })
            );

        uint256 ethBal = IERC20(cl.collateral).balanceOf(address(this));
        IERC20(cl.collateral).forceApprove(address(ch.router), ethBal);
        uint256 minUsd = _baseToToken(ethBal, ch.oracle.getAssetPrice(ch.debt), _decimals(ch.debt));
        minUsd = (minUsd * (10000 - arbSlippageBps)) / 10000;
        ch.router
            .exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: cl.collateral,
                    tokenOut: ch.debt,
                    fee: ch.fee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: ethBal,
                    amountOutMinimum: minUsd,
                    sqrtPriceLimitX96: 0
                })
            );
    }

    function _baseToToken(uint256 baseAmount, uint256 price, uint256 tokenDecimals) internal pure returns (uint256) {
        return (baseAmount * (10 ** tokenDecimals)) / price;
    }

    function _tokenToBase(uint256 tokenAmount, uint256 price, uint256 tokenDecimals) internal pure returns (uint256) {
        return (tokenAmount * price) / (10 ** tokenDecimals);
    }

    function _decimals(address token) internal view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18;
        }
    }

    function _netBase() internal view returns (uint256) {
        (uint256 totalCollateralBase, uint256 totalDebtBase,,,,) = POOL.getUserAccountData(address(this));
        if (totalCollateralBase >= totalDebtBase) return totalCollateralBase - totalDebtBase;
        return 0;
    }
}

interface IERC20Metadata is IERC20 {
    function decimals() external view returns (uint8);
}
