// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script} from "lib/forge-std/src/Script.sol";
import {LeverageLooper} from "src/LeverageLooper.sol";

contract InteractLeverageLooper is Script {
    function run() external {
        string memory action = vm.envString("ACTION");
        address looperAddr = vm.envAddress("LOOPER_ADDR");
        LeverageLooper looper = LeverageLooper(payable(looperAddr));

        vm.startBroadcast();

        if (keccak256(bytes(action)) == keccak256("opt_in_and_loop")) {
            uint256 supplyAmount = vm.envUint("SUPPLY_AMOUNT");
            uint256 targetLtvBps = vm.envUint("TARGET_LTV_BPS");
            uint256 maxIterations = vm.envUint("MAX_ITERATIONS");
            uint24 poolFee = uint24(vm.envUint("POOL_FEE"));
            uint256 slippageBps = vm.envUint("SLIPPAGE_BPS");
            uint256 minHealthFactor = vm.envUint("MIN_HEALTH_FACTOR");
            uint256 profitTargetBase = vm.envUint("PROFIT_TARGET_BASE");
            looper.optInAndLoop(
                supplyAmount,
                targetLtvBps,
                maxIterations,
                poolFee,
                slippageBps,
                minHealthFactor,
                profitTargetBase
            );
        } else if (keccak256(bytes(action)) == keccak256("unwind")) {
            uint256 targetLtvBps = vm.envUint("TARGET_LTV_BPS");
            uint256 maxIterations = vm.envUint("MAX_ITERATIONS");
            uint24 poolFee = uint24(vm.envUint("POOL_FEE"));
            uint256 slippageBps = vm.envUint("SLIPPAGE_BPS");
            looper.unwindToLtv(targetLtvBps, maxIterations, poolFee, slippageBps);
        } else if (keccak256(bytes(action)) == keccak256("maybe_arb")) {
            looper.maybeArb();
        } else if (keccak256(bytes(action)) == keccak256("loop_to_tvl")) {
            uint256 targetCollateralBase = vm.envUint("TARGET_COLLATERAL_BASE");
            uint256 maxIterations = vm.envUint("MAX_ITERATIONS");
            uint24 poolFee = uint24(vm.envUint("POOL_FEE"));
            uint256 slippageBps = vm.envUint("SLIPPAGE_BPS");
            address liquidationTarget = vm.envAddress("LIQ_TARGET");
            uint256 maxDebtPerStep = vm.envUint("MAX_DEBT_PER_STEP");
            looper.loopToTvl(
                targetCollateralBase,
                maxIterations,
                poolFee,
                slippageBps,
                liquidationTarget,
                maxDebtPerStep
            );
        } else if (keccak256(bytes(action)) == keccak256("liquidate_loop")) {
            address target = vm.envAddress("LIQ_TARGET");
            uint256 maxIterations = vm.envUint("MAX_ITERATIONS");
            uint256 maxDebtPerStep = vm.envUint("MAX_DEBT_PER_STEP");
            uint24 poolFee = uint24(vm.envUint("POOL_FEE"));
            uint256 slippageBps = vm.envUint("SLIPPAGE_BPS");
            looper.liquidateLoop(target, maxIterations, maxDebtPerStep, poolFee, slippageBps);
        } else if (keccak256(bytes(action)) == keccak256("set_chain")) {
            uint256 chainId = vm.envUint("CHAIN_ID");
            address router = vm.envAddress("CHAIN_ROUTER");
            address pool = vm.envAddress("CHAIN_POOL");
            address oracle = vm.envAddress("CHAIN_ORACLE");
            address collateral = vm.envAddress("CHAIN_COLLATERAL");
            address debt = vm.envAddress("CHAIN_DEBT");
            uint24 fee = uint24(vm.envUint("CHAIN_FEE"));
            looper.setChain(chainId, router, pool, oracle, collateral, debt, fee);
        } else if (keccak256(bytes(action)) == keccak256("set_destination")) {
            address dest = vm.envAddress("DEST_LOOPER_ADDR");
            uint256 destChain = vm.envUint("DEST_CHAIN_ID");
            looper.setDestination(dest, destChain);
        } else if (keccak256(bytes(action)) == keccak256("subscribe")) {
            uint256 chainId = vm.envUint("SUB_CHAIN_ID");
            address contractAddr = vm.envAddress("SUB_CONTRACT");
            uint256 t0 = vm.envUint("SUB_T0");
            uint256 t1 = vm.envUint("SUB_T1");
            uint256 t2 = vm.envUint("SUB_T2");
            uint256 t3 = vm.envUint("SUB_T3");
            looper.subscribe(chainId, contractAddr, t0, t1, t2, t3);
        }

        vm.stopBroadcast();
    }
}
