// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {LeverageLuidation} from "../src/leverageLuidation.sol";
import {IAaveV3Pool} from "../src/interface/IAaveV3Pool.sol";
import {ISwapRouter} from "../src/interface/ISwapRouter.sol";
import {IPriceOracle} from "../src/interface/IPriceOracle.sol";

contract MockToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockOracle is IPriceOracle {
    function getAssetPrice(address) external pure returns (uint256) {
        return 1e8;
    }
}

contract MockRouter is ISwapRouter {
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        IERC20(params.tokenOut).transfer(msg.sender, params.amountIn);
        return params.amountIn;
    }
}

contract MockPool is IAaveV3Pool {
    address public dataProvider;
    uint256 public targetHealth;
    mapping(address => uint256) public collateralBase;

    function setHealth(uint256 hf) external {
        targetHealth = hf;
    }

    function ADDRESSES_PROVIDER() external view returns (address) {
        return dataProvider;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        collateralBase[onBehalfOf] += amount * 1e8 / 1e18;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        IERC20(asset).transfer(to, amount);
        return amount;
    }

    function borrow(address, uint256, uint256, uint16, address) external {}

    function repay(address asset, uint256 amount, uint256, address) external returns (uint256) {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        return amount;
    }

    function liquidationCall(address collateralAsset, address debtAsset, address, uint256 debtToCover, bool) external {
        IERC20(debtAsset).transferFrom(msg.sender, address(this), debtToCover);
        IERC20(collateralAsset).transfer(msg.sender, debtToCover);
        targetHealth = 1e18;
    }

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
        totalDebtBase = 0;
        availableBorrowsBase = 1e24;
        currentLiquidationThreshold = 8000;
        ltv = 5000;
        healthFactor = targetHealth;
    }
}

contract LeverageLuidationTest is Test {
    MockToken collateral;
    MockToken debt;
    MockOracle oracle;
    MockRouter router;
    MockPool pool;
    LeverageLuidation liq;
    address target;

    function setUp() public {
        collateral = new MockToken("COLL", "COLL");
        debt = new MockToken("DEBT", "DEBT");
        oracle = new MockOracle();
        router = new MockRouter();
        pool = new MockPool();
        liq = new LeverageLuidation(address(pool), address(router), address(oracle), address(collateral), address(debt));
        target = address(0xBEEF);
        pool.setHealth(5e17);
        collateral.mint(address(this), 1_000e18);
        collateral.approve(address(liq), type(uint256).max);
        debt.mint(address(router), 1_000e18);
        collateral.mint(address(pool), 1_000e18);
        debt.mint(address(this), 1_000e18);
        debt.approve(address(pool), type(uint256).max);
        debt.mint(address(liq), 100e18);
    }

    function testDepositAndLiquidateLoop() public {
        liq.depositCollateral(100e18);
        uint256 beforeBase = _userBase(address(liq));
        assertGt(beforeBase, 0);
        debt.approve(address(router), type(uint256).max);
        collateral.approve(address(router), type(uint256).max);
        liq.liquidateLoop(target, beforeBase + 50e8, 5, 3000, 100, true, 10e18);
        uint256 afterBase = _userBase(address(liq));
        assertGt(afterBase, beforeBase);
    }

    function _userBase(address u) internal view returns (uint256) {
        (uint256 c,,,,,) = pool.getUserAccountData(u);
        return c;
    }
}
