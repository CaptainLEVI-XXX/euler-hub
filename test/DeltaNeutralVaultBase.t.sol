// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {
    EulerSwapTestBase, EulerSwap, TestERC20, IEVault, IRMTestDefault
} from "euler-swap-test/EulerSwapTestBase.t.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";

import {DeltaNeutralVault} from "../src/DeltaNeutralVault.sol";
import {PositionManager} from "../src/PositionManager.sol";
import {RiskManager} from "../src/RiskManager.sol";
import {StrategyEngine} from "../src/StrategyEngine.sol";
import {IPositionManager} from "../src/interfaces/IPositionManager.sol";
import {IRiskManager} from "../src/interfaces/IRiskManager.sol";
import {IStrategyEngine} from "../src/interfaces/IStrategyEngine.sol";
import {AccessRegistry} from "../src/AccessRegistry.sol";
import {MockPriceOracle} from "./mock/MockPriceOracle.sol";
import {MockVolatilityOracle} from "./mock/MockVolatilityOracle.sol";

contract DeltaNeutralVaultTestBase is EulerSwapTestBase {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant STRATEGIST_ROLE = keccak256("STRATEGIST_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    // Core contracts
    DeltaNeutralVault public vault;
    PositionManager public positionManager;
    RiskManager public riskManager;
    StrategyEngine public strategyEngine;

    // Mock contracts
    MockPriceOracle public priceOracle;
    MockVolatilityOracle public volatilityOracle;
    AccessRegistry public accessRegistry;

    // Test accounts
    address public admin_ = makeAddr("admin1");
    address public strategist = makeAddr("strategist");
    address public keeper = makeAddr("keeper");
    address public guardian = makeAddr("guardian");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public treasury = makeAddr("treasury");

    // Test tokens - use from base
    TestERC20 public USDC;
    TestERC20 public ETH;
    TestERC20 public BTC;

    // No need to redeclare vaults - use eTST, eTST2, eTST3 directly from base

    // Euler pools
    EulerSwap public ethUsdcPool;
    EulerSwap public btcUsdcPool;

    // Constants
    uint256 constant INITIAL_PRICE_ETH = 2000e18; // $2000 per ETH
    uint256 constant INITIAL_PRICE_BTC = 40000e18; // $40000 per BTC
    uint256 constant INITIAL_PRICE_USDC = 1e18; // $1 per USDC

    function setUp() public virtual override {
        super.setUp();

        // Use tokens from base
        USDC = assetTST2; // TST2 as USDC
        ETH = assetTST; // TST as ETH
        BTC = assetTST3; // TST3 as BTC

        // No need to assign vaults - use eTST, eTST2, eTST3 directly from base

        // Deploy mock contracts
        priceOracle = new MockPriceOracle();
        volatilityOracle = new MockVolatilityOracle();
        accessRegistry = new AccessRegistry(admin_);

        console.log("deployed mock contracts");

        vm.startPrank(admin_);

        // Set up roles
        accessRegistry.grantRole(ADMIN_ROLE, admin_);
        accessRegistry.grantRole(STRATEGIST_ROLE, strategist);
        accessRegistry.grantRole(KEEPER_ROLE, keeper);
        accessRegistry.grantRole(GUARDIAN_ROLE, guardian);
        vm.stopPrank();

        console.log("granted roles");

        // Set up oracle prices
        priceOracle.setPrice(address(USDC), INITIAL_PRICE_USDC);
        priceOracle.setPrice(address(ETH), INITIAL_PRICE_ETH);
        priceOracle.setPrice(address(BTC), INITIAL_PRICE_BTC);

        console.log("set up oracle prices");

        // Set up volatilities (20% for ETH/BTC, 1% for USDC)
        volatilityOracle.setVolatility(address(ETH), 20e16);
        volatilityOracle.setVolatility(address(BTC), 25e16);
        volatilityOracle.setVolatility(address(USDC), 1e16);

        console.log("set up volatilities");

        // Deploy Delta-Neutral Vault protocol
        vault = new DeltaNeutralVault(
            IERC20(address(USDC)),
            "Delta Neutral USDC",
            "dnUSDC",
            address(evc),
            holder, // Use holder from base as euler account
            address(accessRegistry),
            admin_
        );

        positionManager = new PositionManager(
            address(vault),
            address(evc),
            address(eulerSwapFactory),
            holder, // Use holder from base as euler account
            address(USDC),
            address(accessRegistry),
            address(priceOracle)
        );

        riskManager = new RiskManager(
            address(vault),
            address(positionManager),
            address(priceOracle),
            address(volatilityOracle),
            address(accessRegistry)
        );

        strategyEngine =
            new StrategyEngine(address(vault), address(positionManager), address(priceOracle), address(accessRegistry));

        console.log("deployed delta-neutral vault protocol");

        // Set up operators for EVC - this is crucial
        vm.startPrank(holder);
        // Allow PositionManager to act on behalf of holder
        evc.setAccountOperator(holder, address(positionManager), true);
        // Allow Vault to act on behalf of holder for pool operations
        evc.setAccountOperator(holder, address(vault), true);
        vm.stopPrank();

        // Configure vault components
        vm.startPrank(admin_);
        vault.setPositionManager(address(positionManager));
        console.log("set position manager");
        vault.setRiskManager(address(riskManager));
        console.log("set risk manager");
        vault.setStrategyEngine(address(strategyEngine));
        console.log("set strategy engine");
        vm.stopPrank();

        console.log("configured vault components");

        // Create Euler Swap pools using base helper
        createDeltaNeutralPools();

        console.log("created euler swap pools");

        // Fund test accounts
        fundTestAccounts();

        console.log("funded test accounts");

        // Register vaults in position manager
        vm.startPrank(admin_);
        positionManager.registerVault(address(ETH), address(eTST)); // eTST is ETH vault
        positionManager.registerVault(address(BTC), address(eTST3)); // eTST3 is BTC vault
        positionManager.registerVault(address(USDC), address(eTST2)); // eTST2 is USDC vault

        // Set Access Registry
        accessRegistry.grantRole(VAULT_ROLE, address(vault));
        accessRegistry.grantRole(VAULT_ROLE, address(positionManager));
        accessRegistry.grantRole(VAULT_ROLE, address(riskManager));
        accessRegistry.grantRole(VAULT_ROLE, address(strategyEngine));
        vm.stopPrank();

        console.log("registered vaults in position manager");

        // Whitelist pools in strategy engine
        vm.startPrank(strategist);
        strategyEngine.whitelistPair(address(ethUsdcPool), true);
        strategyEngine.whitelistPair(address(btcUsdcPool), true);

        // Update pair metadata
        strategyEngine.updatePairMetadata(address(ethUsdcPool), 10_000_000e6, 20e16); // $10M volume, 20% volatility
        strategyEngine.updatePairMetadata(address(btcUsdcPool), 5_000_000e6, 25e16); // $5M volume, 25% volatility
        vm.stopPrank();
    }

    function createDeltaNeutralPools() internal {
        // The base createEulerSwap sets the pool as operator and tracks it in installedOperator
        // But it removes the previous operator when creating a new pool
        // So we need to create pools and then manually set all as operators

        // Create ETH/USDC pool
        ethUsdcPool = createEulerSwap(
            1000e18, // 1000 ETH
            2000000e18, // 2M USDC (using 18 decimals for TST2)
            0.003e18, // 0.3% fee
            1e18, // price X
            1e18, // price Y
            0.9e18, // concentration X
            0.9e18 // concentration Y
        );

        (uint112 reserve0ethUSDC, uint112 reserve1ethUSDC, uint32 statusethUSDC) = ethUsdcPool.getReserves();
        console.log("reserve0 for ETH/USDC pool", reserve0ethUSDC);
        console.log("reserve1 for ETH/USDC pool", reserve1ethUSDC);
        console.log("status for ETH/USDC pool", statusethUSDC);

        // Store the first pool address
        address firstPool = address(ethUsdcPool);

        // Create BTC/USDC pool (this will remove ethUsdcPool as operator)
        btcUsdcPool = createEulerSwap(
            50e18, // 50 BTC (using 18 decimals for TST3)
            2000000e18, // 2M USDC
            0.003e18, // 0.3% fee
            1e18, // price X
            1e18, // price Y
            0.9e18, // concentration X
            0.9e18 // concentration Y
        );

        (uint112 reserve0btcUSDC, uint112 reserve1btcUSDC, uint32 statusbtcUSDC) = btcUsdcPool.getReserves();
        console.log("reserve0 for BTC/USDC pool", reserve0btcUSDC);
        console.log("reserve1 for BTC/USDC pool", reserve1btcUSDC);
        console.log("status for BTC/USDC pool", statusbtcUSDC);

        // Now set both pools as operators
        vm.startPrank(holder);
        evc.setAccountOperator(holder, firstPool, true);
        // btcUsdcPool is already set as operator by the last createEulerSwap call
        vm.stopPrank();
    }

    function fundTestAccounts() internal {
        // Fund users with USDC
        USDC.mint(alice, 1_000_000e18); // Using 18 decimals
        USDC.mint(bob, 500_000e18);
        USDC.mint(charlie, 2_000_000e18);

        // Fund depositor (from base) with more liquidity
        USDC.mint(depositor, 10_000_000e18);
        ETH.mint(depositor, 5000e18);
        BTC.mint(depositor, 250e18);

        // Ensure vaults have liquidity
        vm.startPrank(depositor);
        USDC.approve(address(eTST2), type(uint256).max);
        ETH.approve(address(eTST), type(uint256).max);
        BTC.approve(address(eTST3), type(uint256).max);

        // Deposit to vaults to provide liquidity
        eTST2.deposit(5_000_000e18, depositor);
        eTST.deposit(2500e18, depositor);
        eTST3.deposit(125e18, depositor);
        vm.stopPrank();
    }

    // Helper functions
    function depositToVault(address user, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(user);
        USDC.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
    }

    function requestWithdrawal(address user, uint256 shares) internal {
        vm.prank(user);
        vault.requestWithdrawal(shares);
    }

    function processWithdrawal(address user) internal {
        vm.prank(user);
        vault.processWithdrawals();
    }

    function rebalance() internal {
        vm.prank(strategist);
        vault.rebalance();
    }

    function harvest() internal {
        vm.prank(keeper);
        vault.harvest();
    }

    // function simulateYield(uint256 yieldAmount) internal {
    //     // Simulate yield by sending tokens to position manager
    //     USDC.mint(address(positionManager), yieldAmount);
    // }

    function simulateYield(uint256 yieldAmount) internal {
        address[] memory activePools = positionManager.getActivePositions();
        if (activePools.length == 0) return;

        uint256 yieldPerPool = yieldAmount / activePools.length;

        for (uint256 i = 0; i < activePools.length; i++) {
            // Add USDC to the pool reserves (simulating trading fees)
            USDC.mint(activePools[i], yieldPerPool);
        }
    }

    function simulateYieldThroughRebalance(uint256 yieldAmount) internal {
        vm.startPrank(strategist);

        // Close a position
        address[] memory positions = positionManager.getActivePositions();
        if (positions.length > 0) {
            positionManager.closePosition(positions[0]);

            // Mint extra USDC to position manager (profit)
            USDC.mint(address(positionManager), yieldAmount);

            // Reopen position with more funds
            positionManager.openPosition(positions[0], USDC.balanceOf(address(positionManager)));
        }

        vm.stopPrank();
    }

    function movePrice(address token, uint256 newPrice) internal {
        priceOracle.setPrice(token, newPrice);
    }

    function increaseVolatility(address token, uint256 newVolatility) internal {
        volatilityOracle.setVolatility(token, newVolatility);
    }

    function skipTime(uint256 duration) internal {
        skip(duration);
    }

    function ensureLiquidityForWithdrawal(address user) internal {
        uint256 sharesOwned = vault.balanceOf(user);
        uint256 assetsNeeded = vault.convertToAssets(sharesOwned);
        uint256 currentLiquidity = USDC.balanceOf(address(vault));

        if (assetsNeeded > currentLiquidity) {
            // Close enough positions to meet withdrawal
            vm.startPrank(strategist);
            address[] memory positions = positionManager.getActivePositions();

            for (uint256 i = 0; i < positions.length && currentLiquidity < assetsNeeded; i++) {
                positionManager.closePosition(positions[i]);
                currentLiquidity = USDC.balanceOf(address(vault));
            }
            vm.stopPrank();
        }
    }
}
