// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReactiveController} from "../src/ReactiveController.sol";
import {IAaveV3Pool} from "../src/interface/IAaveV3Pool.sol";
import {ISwapRouter} from "../src/interface/ISwapRouter.sol";
import {IPriceOracle} from "../src/interface/IPriceOracle.sol";

contract MToken is ERC20 { constructor(string memory n, string memory s) ERC20(n, s) {} function mint(address to, uint256 a) external { _mint(to, a); } }
contract MOracle is IPriceOracle { function getAssetPrice(address) external pure returns (uint256) { return 1e8; } }
interface IMint { function mint(address to, uint256 a) external; }
contract MRouter is ISwapRouter {
    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256) {
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        IMint(p.tokenOut).mint(p.recipient, p.amountIn);
        return p.amountIn;
    }
}
contract MPool is IAaveV3Pool {
    address public dataProvider;
    mapping(address => uint256) public cBase;
    mapping(address => uint256) public dBase;
    function ADDRESSES_PROVIDER() external view returns (address) { return dataProvider; }
    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external { IERC20(asset).transferFrom(msg.sender, address(this), amount); cBase[onBehalfOf]+= amount*1e8/1e18; }
    function withdraw(address asset, uint256 amount, address to) external returns (uint256) { IERC20(asset).transfer(to, amount); cBase[msg.sender]-= amount*1e8/1e18; return amount; }
    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external { IMint(asset).mint(onBehalfOf, amount); dBase[onBehalfOf]+= amount*1e8/1e18; }
    function repay(address asset, uint256 amount, uint256, address onBehalfOf) external returns (uint256) { IERC20(asset).transferFrom(msg.sender, address(this), amount); uint256 b= amount*1e8/1e18; if(dBase[onBehalfOf]>=b)dBase[onBehalfOf]-=b; else dBase[onBehalfOf]=0; return amount; }
    function liquidationCall(address, address, address, uint256, bool) external {}
    function getUserAccountData(address user) external view returns (uint256, uint256, uint256, uint256, uint256, uint256) { uint256 c=cBase[user]; uint256 d=dBase[user]; uint256 ab=c*5000/10000; uint256 clt=8000; uint256 ltv= c==0?0:(d*10000)/c; uint256 hf= ltv>=8000? 9e17:2e18; return (c,d,ab,clt,ltv,hf);} }

contract ReactiveControllerTest is Test {
    MToken collateral; MToken debt; MOracle oracle; MRouter router; MPool pool; ReactiveController ctl;
    function setUp() public { collateral=new MToken("COLL","COLL"); debt=new MToken("DEBT","DEBT"); oracle=new MOracle(); router=new MRouter(); pool=new MPool(); ctl=new ReactiveController(address(pool),address(router),address(oracle),address(collateral),address(debt)); collateral.mint(address(this),1_000e18); collateral.approve(address(ctl),type(uint256).max); debt.mint(address(router),1_000e18); }
    function testController() public { ctl.onUserOptIn(100e18,5000,4,3000,100,1e18); (uint256 c,uint256 d,,, ,)= _data(address(ctl.looper())); assertGt(c,0); assertGe(d,0); IERC20(address(collateral)).approve(address(router),type(uint256).max); IERC20(address(debt)).approve(address(pool),type(uint256).max); ctl.onUnwind(2000,4,3000,100); (uint256 c2,uint256 d2,,, ,)=_data(address(ctl.looper())); uint256 ltv2= c2==0?0:(d2*10000)/c2; assertLe(ltv2,2100);} 
    function _data(address u) internal view returns(uint256, uint256, uint256, uint256, uint256, uint256){ return pool.getUserAccountData(u);} }
