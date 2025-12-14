// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {LeverageLooper} from "../src/LeverageLooper.sol";
import {ISwapRouter} from "../src/interface/ISwapRouter.sol";
import {IAaveV3Pool} from "../src/interface/IAaveV3Pool.sol";
import {IPriceOracle} from "../src/interface/IPriceOracle.sol";
import {IReactive} from "../lib/reactive-lib/src/interfaces/IReactive.sol";

contract Mintable is ERC20 { constructor(string memory n,string memory s) ERC20(n,s){} function mint(address to,uint256 a) external { _mint(to,a);} }
interface IMint { function mint(address to,uint256 a) external; }

contract RouterMint is ISwapRouter {
    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256) {
        require(IERC20(p.tokenIn).transferFrom(msg.sender,address(this),p.amountIn));
        IMint(p.tokenOut).mint(p.recipient,p.amountIn);
        return p.amountIn;
    }
}

contract PoolMock is IAaveV3Pool {
    address public dataProvider; mapping(address=>uint256) public c; mapping(address=>uint256) public d;
    function ADDRESSES_PROVIDER() external view returns(address){return dataProvider;}
    function supply(address asset,uint256 amount,address onBehalfOf,uint16) external { require(IERC20(asset).transferFrom(msg.sender,address(this),amount)); c[onBehalfOf]+=amount*1e8/1e18; }
    function withdraw(address asset,uint256 amount,address to) external returns(uint256){ require(IERC20(asset).transfer(to,amount)); c[msg.sender]-=amount*1e8/1e18; return amount; }
    function borrow(address asset,uint256 amount,uint256,uint16,address onBehalfOf) external { IMint(asset).mint(onBehalfOf,amount); d[onBehalfOf]+=amount*1e8/1e18; }
    function repay(address asset,uint256 amount,uint256,address onBehalfOf) external returns(uint256){ require(IERC20(asset).transferFrom(msg.sender,address(this),amount)); uint256 b=amount*1e8/1e18; if(d[onBehalfOf]>=b)d[onBehalfOf]-=b; else d[onBehalfOf]=0; return amount; }
    function liquidationCall(address,address,address,uint256,bool) external {}
    function getUserAccountData(address user) external view returns(uint256,uint256,uint256,uint256,uint256,uint256){ uint256 cc=c[user]; uint256 dd=d[user]; return (cc,dd,cc*5000/10000,8000, cc==0?0:(dd*10000)/cc, 2e18);} }

contract OracleMock is IPriceOracle { uint256 public p; function set(uint256 _p) external { p=_p; } function getAssetPrice(address) external view returns(uint256){ return p; } }

contract CrossChainArbReactiveTest is Test {
    Mintable usdcA; Mintable usdcB; Mintable ethA; Mintable ethB; RouterMint rA; RouterMint rB; PoolMock pA; PoolMock pB; OracleMock oA; OracleMock oB; LeverageLooper looper;

    function setUp() public {
        usdcA=new Mintable("USDC-A","USDC-A"); usdcB=new Mintable("USDC-B","USDC-B"); ethA=new Mintable("ETH-A","ETH-A"); ethB=new Mintable("ETH-B","ETH-B"); rA=new RouterMint(); rB=new RouterMint(); pA=new PoolMock(); pB=new PoolMock(); oA=new OracleMock(); oB=new OracleMock();
        looper=new LeverageLooper(address(pA),address(rA),address(oA),address(ethA),address(usdcA));
        looper.setChain(1,address(rA),address(pA),address(oA),address(ethA),address(usdcA),3000);
        looper.setChain(0,address(rB),address(pB),address(oB),address(ethB),address(usdcB),3000);
        looper.setArbParams(100, 1_000e6, 100);
        usdcA.mint(address(looper),10_000e6); usdcB.mint(address(looper),10_000e6);
        vm.prank(address(looper)); IERC20(address(usdcA)).approve(address(rA), type(uint256).max);
        vm.prank(address(looper)); IERC20(address(ethA)).approve(address(rB), type(uint256).max);
    }

    function testArbExecutesOnPriceDiff() public {
        oA.set(2800e8); oB.set(3000e8);
        IReactive.LogRecord memory logA = IReactive.LogRecord({ chain_id: 1, _contract: address(0), topic_0: uint256(keccak256("PriceUpdate(uint256)")), topic_1:0,topic_2:0,topic_3:0, data: abi.encode(uint256(2800e8)), block_number: 0, op_code: 0, block_hash: 0, tx_hash: 0, log_index: 0 });
        IReactive.LogRecord memory logB = IReactive.LogRecord({ chain_id: 0, _contract: address(0), topic_0: uint256(keccak256("PriceUpdate(uint256)")), topic_1:0,topic_2:0,topic_3:0, data: abi.encode(uint256(3000e8)), block_number: 0, op_code: 0, block_hash: 0, tx_hash: 0, log_index: 0 });
        looper.react(logA); looper.react(logB);
        uint256 balB = IERC20(address(usdcB)).balanceOf(address(looper));
        uint256 spentA = IERC20(address(usdcA)).balanceOf(address(looper));
        assertLt(spentA, 10_000e6);
        assertGt(balB,0);
    }
}
