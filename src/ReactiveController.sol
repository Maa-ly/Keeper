// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LeverageLooper} from "./LeverageLooper.sol";
import {LeverageLuidation} from "./leverageLuidation.sol";
import {AbstractReactive} from "../lib/reactive-lib/src/abstract-base/AbstractReactive.sol";
import {IReactive} from "../lib/reactive-lib/src/interfaces/IReactive.sol";

contract ReactiveController is AbstractReactive {
    LeverageLooper public looper;
    LeverageLuidation public liquidator;
    address public collateral;

    constructor(address pool, address router, address oracle, address _collateral, address debt) {
        looper = new LeverageLooper(pool, router, oracle, _collateral, debt);
        liquidator = new LeverageLuidation(pool, router, oracle, _collateral, debt);
        collateral = _collateral;
    }

    function onUserOptIn(
        uint256 supplyAmount,
        uint256 targetLTVBps,
        uint256 maxIterations,
        uint24 poolFee,
        uint256 slippageBps,
        uint256 minHealthFactor
    ) external {
        IERC20(collateral).transferFrom(msg.sender, address(this), supplyAmount);
        IERC20(collateral).approve(address(looper), supplyAmount);
        looper.optInAndLoop(supplyAmount, targetLTVBps, maxIterations, poolFee, slippageBps, minHealthFactor);
    }

    function onUnwind(uint256 targetLTVBps, uint256 maxIterations, uint24 poolFee, uint256 slippageBps) external {
        looper.unwindToLTV(targetLTVBps, maxIterations, poolFee, slippageBps);
    }

    function onLiquidationOpportunity(
        address target,
        uint256 desiredLockedBase,
        uint256 maxIterations,
        uint24 poolFee,
        uint256 slippageBps,
        bool supplyAcquired,
        uint256 maxDebtPerStep
    ) external {
        liquidator.liquidateLoop(
            target, desiredLockedBase, maxIterations, poolFee, slippageBps, supplyAcquired, maxDebtPerStep
        );
    }

    function react(IReactive.LogRecord calldata log) external override {
        bytes memory payload = log.data;
        uint256 t0 = log.topic_0;
        if (t0 == uint256(keccak256("UserOptIn(address,uint256,uint256,uint24,uint256,uint256)"))) {
            (
                uint256 supplyAmount,
                uint256 targetLTVBps,
                uint256 maxIterations,
                uint24 poolFee,
                uint256 slippageBps,
                uint256 minHealthFactor
            ) = abi.decode(payload, (uint256, uint256, uint256, uint24, uint256, uint256));
            IERC20(collateral).approve(address(looper), supplyAmount);
            looper.optInAndLoop(supplyAmount, targetLTVBps, maxIterations, poolFee, slippageBps, minHealthFactor);
        } else if (t0 == uint256(keccak256("Unwind(uint256,uint256,uint24,uint256)"))) {
            (uint256 targetLTVBps, uint256 maxIterations, uint24 poolFee, uint256 slippageBps) =
                abi.decode(payload, (uint256, uint256, uint24, uint256));
            looper.unwindToLTV(targetLTVBps, maxIterations, poolFee, slippageBps);
        } else if (
            t0 == uint256(keccak256("LiquidationOpportunity(address,uint256,uint256,uint24,uint256,bool,uint256)"))
        ) {
            (
                address target,
                uint256 desiredLockedBase,
                uint256 maxIterations,
                uint24 poolFee,
                uint256 slippageBps,
                bool supplyAcquired,
                uint256 maxDebtPerStep
            ) = abi.decode(payload, (address, uint256, uint256, uint24, uint256, bool, uint256));
            liquidator.liquidateLoop(
                target, desiredLockedBase, maxIterations, poolFee, slippageBps, supplyAcquired, maxDebtPerStep
            );
        }
    }
}
