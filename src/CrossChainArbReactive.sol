// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AbstractReactive} from "../lib/reactive-lib/src/abstract-base/AbstractReactive.sol";
import {IReactive} from "../lib/reactive-lib/src/interfaces/IReactive.sol";
import {ISwapRouter} from "./interface/ISwapRouter.sol";
import {IAaveV3Pool} from "./interface/IAaveV3Pool.sol";
import {IPriceOracle} from "./interface/IPriceOracle.sol";
import {LeverageLuidation} from "./leverageLuidation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract CrossChainArbReactive is AbstractReactive {
    using SafeERC20 for IERC20;

    struct ChainConfig { ISwapRouter router; IAaveV3Pool pool; IPriceOracle oracle; address collateral; address debt; uint24 fee; }

    mapping(uint256 => ChainConfig) public cfg;
    mapping(uint256 => uint256) public lastPrice;

    uint256 public minDiffBps;
    uint256 public arbAmount;
    uint256 public slippageBps;

    LeverageLuidation public liquidator;

    constructor(address _liquidator) { liquidator = LeverageLuidation(_liquidator); minDiffBps = 300; slippageBps = 100; arbAmount = 1000e6; }

    function setChain(uint256 chainId, address router, address pool, address oracle, address collateral, address debt, uint24 fee) external {
        cfg[chainId] = ChainConfig(ISwapRouter(router), IAaveV3Pool(pool), IPriceOracle(oracle), collateral, debt, fee);
    }

    function setParams(uint256 _minDiffBps, uint256 _arbAmount, uint256 _slippageBps) external { minDiffBps = _minDiffBps; arbAmount = _arbAmount; slippageBps = _slippageBps; }

    function react(IReactive.LogRecord calldata log) external override {
        uint256 t0 = log.topic_0;
        bytes memory payload = log.data;
        if (t0 == uint256(keccak256("PriceUpdate(uint256)"))) {
            uint256 price = abi.decode(payload, (uint256));
            lastPrice[log.chain_id] = price;
            uint256 a = log.chain_id;
            uint256 b = a ^ 1;
            if (lastPrice[a] > 0 && lastPrice[b] > 0) {
                uint256 pa = lastPrice[a];
                uint256 pb = lastPrice[b];
                if (pa + (pa * minDiffBps) / 10000 <= pb) {
                    _arb(a, b);
                } else if (pb + (pb * minDiffBps) / 10000 <= pa) {
                    _arb(b, a);
                }
            }
        } else if (t0 == uint256(keccak256("HealthBelow(address)"))) {
            (address target) = abi.decode(payload, (address));
            ChainConfig memory ca = cfg[log.chain_id];
            liquidator.liquidateLoop(target, 0, 3, ca.fee, slippageBps, true, arbAmount);
        }
    }

    function _arb(uint256 lowChain, uint256 highChain) internal {
        ChainConfig memory cl = cfg[lowChain];
        ChainConfig memory ch = cfg[highChain];

        IERC20(cl.debt).forceApprove(address(cl.router), arbAmount);
        uint256 minEth = _usdToTokenOut(arbAmount, cl.oracle.getAssetPrice(cl.collateral), _decimals(cl.collateral));
        minEth = (minEth * (10000 - slippageBps)) / 10000;
        cl.router.exactInputSingle(ISwapRouter.ExactInputSingleParams({ tokenIn: cl.debt, tokenOut: cl.collateral, fee: cl.fee, recipient: address(this), deadline: block.timestamp, amountIn: arbAmount, amountOutMinimum: minEth, sqrtPriceLimitX96: 0 }));

        uint256 ethBal = IERC20(cl.collateral).balanceOf(address(this));
        IERC20(cl.collateral).forceApprove(address(ch.router), ethBal);
        uint256 minUsd = _usdToTokenOut(ethBal, ch.oracle.getAssetPrice(ch.debt), _decimals(ch.debt));
        minUsd = (minUsd * (10000 - slippageBps)) / 10000;
        ch.router.exactInputSingle(ISwapRouter.ExactInputSingleParams({ tokenIn: cl.collateral, tokenOut: ch.debt, fee: ch.fee, recipient: address(this), deadline: block.timestamp, amountIn: ethBal, amountOutMinimum: minUsd, sqrtPriceLimitX96: 0 }));
    }

    function _usdToTokenOut(uint256 baseAmount, uint256 price, uint256 tokenDecimals) internal pure returns (uint256) { return (baseAmount * (10 ** tokenDecimals)) / price; }

    function _decimals(address token) internal view returns (uint8) { try IERC20Metadata(token).decimals() returns (uint8 d) { return d; } catch { return 18; } }
}

interface IERC20Metadata is IERC20 { function decimals() external view returns (uint8); }

