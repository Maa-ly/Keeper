// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script} from "lib/forge-std/src/Script.sol";
import {LeverageLooper} from "src/LeverageLooper.sol";
import {ISwapRouter} from "src/interface/ISwapRouter.sol";
import {IAaveV3Pool} from "src/interface/IAaveV3Pool.sol";
import {IPriceOracle} from "src/interface/IPriceOracle.sol";

contract DeployLeverageLooper is Script {
    function run() external {
        address pool = vm.envAddress("POOL_ADDR");
        address router = vm.envAddress("ROUTER_ADDR");
        address oracle = vm.envAddress("ORACLE_ADDR");
        address collateral = vm.envAddress("COLLATERAL_ADDR");
        address debt = vm.envAddress("DEBT_ADDR");

        vm.startBroadcast();
        LeverageLooper looper = new LeverageLooper(pool, router, oracle, collateral, debt);

        uint256 minDiffBps = vm.envOr("MIN_DIFF_BPS", uint256(300));
        uint256 arbAmount = vm.envOr("ARB_AMOUNT", uint256(1000e6));
        uint256 slippageBps = vm.envOr("ARB_SLIPPAGE_BPS", uint256(100));
        looper.setArbParams(minDiffBps, arbAmount, slippageBps);

        bool hasChainA = vm.envBool("HAS_CHAIN_A");
        if (hasChainA) {
            uint256 chainAId = vm.envUint("CHAIN_A_ID");
            address routerA = vm.envAddress("CHAIN_A_ROUTER");
            address poolA = vm.envAddress("CHAIN_A_POOL");
            address oracleA = vm.envAddress("CHAIN_A_ORACLE");
            address collateralA = vm.envAddress("CHAIN_A_COLLATERAL");
            address debtA = vm.envAddress("CHAIN_A_DEBT");
            uint24 feeA = uint24(vm.envUint("CHAIN_A_FEE"));
            looper.setChain(chainAId, routerA, poolA, oracleA, collateralA, debtA, feeA);
        }

        bool hasChainB = vm.envBool("HAS_CHAIN_B");
        if (hasChainB) {
            uint256 chainBId = vm.envUint("CHAIN_B_ID");
            address routerB = vm.envAddress("CHAIN_B_ROUTER");
            address poolB = vm.envAddress("CHAIN_B_POOL");
            address oracleB = vm.envAddress("CHAIN_B_ORACLE");
            address collateralB = vm.envAddress("CHAIN_B_COLLATERAL");
            address debtB = vm.envAddress("CHAIN_B_DEBT");
            uint24 feeB = uint24(vm.envUint("CHAIN_B_FEE"));
            looper.setChain(chainBId, routerB, poolB, oracleB, collateralB, debtB, feeB);
        }

        bool hasPriceSub = vm.envOr("HAS_PRICE_SUB", false);
        if (hasPriceSub) {
            uint256 pChain = vm.envUint("PRICE_SUB_CHAIN_ID");
            address pContract = vm.envAddress("PRICE_SUB_CONTRACT");
            uint256 pT0 = vm.envUint("PRICE_SUB_TOPIC0");
            uint256 pT1 = vm.envOr("PRICE_SUB_TOPIC1", uint256(0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad));
            uint256 pT2 = vm.envOr("PRICE_SUB_TOPIC2", uint256(0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad));
            uint256 pT3 = vm.envOr("PRICE_SUB_TOPIC3", uint256(0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad));
            looper.subscribe(pChain, pContract, pT0, pT1, pT2, pT3);
        }

        bool hasHealthSub = vm.envOr("HAS_HEALTH_SUB", false);
        if (hasHealthSub) {
            uint256 hChain = vm.envUint("HEALTH_SUB_CHAIN_ID");
            address hContract = vm.envAddress("HEALTH_SUB_CONTRACT");
            uint256 hT0 = vm.envUint("HEALTH_SUB_TOPIC0");
            uint256 hT1 = vm.envOr("HEALTH_SUB_TOPIC1", uint256(0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad));
            uint256 hT2 = vm.envOr("HEALTH_SUB_TOPIC2", uint256(0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad));
            uint256 hT3 = vm.envOr("HEALTH_SUB_TOPIC3", uint256(0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad));
            looper.subscribe(hChain, hContract, hT0, hT1, hT2, hT3);
        }

        bool hasDest = vm.envOr("HAS_DEST", false);
        if (hasDest) {
            address dest = vm.envAddress("DEST_LOOPER_ADDR");
            uint256 destChain = vm.envUint("DEST_CHAIN_ID");
            looper.setDestination(dest, destChain);
            uint64 gasLimit = uint64(vm.envOr("CALLBACK_GAS_LIMIT", uint256(2000000)));
            looper.setCallbackGasLimit(gasLimit);
        }

        vm.stopBroadcast();
    }
}
