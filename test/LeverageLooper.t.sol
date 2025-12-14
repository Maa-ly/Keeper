// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {LeverageLooper} from "../src/LeverageLooper.sol";
import {IAaveV3Pool} from "../src/interface/IAaveV3Pool.sol";
import {ISwapRouter} from "../src/interface/ISwapRouter.sol";
import {IPriceOracle} from "../src/interface/IPriceOracle.sol";

contract MockToken2 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockOracle2 is IPriceOracle {
    function getAssetPrice(address) external pure returns (uint256) {
        return 1e8;
    }
}

interface IMintable {
    function mint(address to, uint256 amount) external;
}

contract MockRouter2 is ISwapRouter {
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
        require(IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn));
        IMintable(params.tokenOut).mint(msg.sender, params.amountIn);
        return params.amountIn;
    }
}

contract MockPool2 is IAaveV3Pool {
    address public dataProvider;
    mapping(address => uint256) public collateralBase;
    mapping(address => uint256) public debtBase;

    function ADDRESSES_PROVIDER() external view returns (address) {
        return dataProvider;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount));
        collateralBase[onBehalfOf] += amount * 1e8 / 1e18;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(IERC20(asset).transfer(to, amount));
        collateralBase[msg.sender] -= amount * 1e8 / 1e18;
        return amount;
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external {
        IMintable(asset).mint(onBehalfOf, amount);
        debtBase[onBehalfOf] += amount * 1e8 / 1e18;
    }

    function repay(address asset, uint256 amount, uint256, address onBehalfOf) external returns (uint256) {
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount));
        uint256 base = amount * 1e8 / 1e18;
        if (debtBase[onBehalfOf] >= base) debtBase[onBehalfOf] -= base;
        else debtBase[onBehalfOf] = 0;
        return amount;
    }

    function liquidationCall(address, address, address, uint256, bool) external {}

    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        totalCollateralBase = collateralBase[user];
        totalDebtBase = debtBase[user];
        availableBorrowsBase = totalCollateralBase * 5000 / 10000;
        currentLiquidationThreshold = 8000;
        ltv = totalCollateralBase == 0 ? 0 : (totalDebtBase * 10000) / totalCollateralBase;
        healthFactor = ltv >= 8000 ? 9e17 : 2e18;
    }
}

contract LeverageLooperTest is Test {
    MockToken2 collateral;
    MockToken2 debt;
    MockOracle2 oracle;
    MockRouter2 router;
    MockPool2 pool;
    LeverageLooper looper;

    function setUp() public {
        collateral = new MockToken2("COLL", "COLL");
        debt = new MockToken2("DEBT", "DEBT");
        oracle = new MockOracle2();
        router = new MockRouter2();
        pool = new MockPool2();
        looper = new LeverageLooper(address(pool), address(router), address(oracle), address(collateral), address(debt));
        collateral.mint(address(this), 1_000e18);
        collateral.approve(address(looper), type(uint256).max);
        debt.mint(address(router), 1_000e18);
        collateral.mint(address(router), 1_000e18);
    }

    function testLoopAndUnwind() public {
        looper.optInAndLoop(100e18, 5000, 5, 3000, 100, 1e18, 0);
        (uint256 c, uint256 d,,, uint256 ltv,) = pool.getUserAccountData(address(looper));
        assertGt(c, 0);
        assertGt(d, 0);
        assertGe(ltv, 3000);

        collateral.approve(address(router), type(uint256).max);
        debt.approve(address(pool), type(uint256).max);
        looper.unwindToLtv(2000, 5, 3000, 100);
        (, uint256 d2,,, uint256 ltv2,) = pool.getUserAccountData(address(looper));
        assertLe(ltv2, 2100);
        assertLt(d2, d);
    }

    function testLoopToTVL() public {
        collateral.mint(address(looper), 200e18);
        looper.loopToTvl(150e8, 5, 3000, 100, address(0), 10e18);
        (uint256 c,,,,,) = pool.getUserAccountData(address(looper));
        assertGe(c, 150e8);
    }
}
