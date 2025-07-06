// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {DeltaNeutralVaultTestBase} from "./DeltaNeutralVaultBase.t.sol";
import {console} from "forge-std/console.sol";

contract DeltaNeutralVaultFullFlowTest is DeltaNeutralVaultTestBase {
    function test_FullFlow_DepositRebalanceHarvestWithdraw() public {
        // Initial state tracking
        uint256 initialAliceBalance = USDC.balanceOf(alice);
        uint256 initialBobBalance = USDC.balanceOf(bob);
        uint256 initialVaultAssets = USDC.balanceOf(address(vault));

        console.log("=== Initial State ===");
        console.log("Alice USDC balance:", initialAliceBalance);
        console.log("Bob USDC balance:", initialBobBalance);

        // Step 1: Multiple users deposit
        uint256 aliceDeposit = 100_000e6;
        uint256 bobDeposit = 50_000e6;

        console.log("Total shares:", vault.totalSupply());
        console.log("TOTAL ASSETS:", vault.totalAssets());

        uint256 aliceShares = depositToVault(alice, aliceDeposit);
        uint256 bobShares = depositToVault(bob, bobDeposit);

        console.log("\n=== After Deposits ===");
        console.log("Alice shares:", aliceShares);
        console.log("Bob shares:", bobShares);
        console.log("Total assets in vault:", vault.totalAssets());
        // console.log("Vault USDC balance:", USDC.balanceOf(address(vault)));

        assertEq(vault.balanceOf(alice), aliceShares, "Alice shares mismatch");
        assertEq(vault.balanceOf(bob), bobShares, "Bob shares mismatch");

        // Step 2: Open positions through rebalancing
        vm.prank(strategist);
        positionManager.openPosition(address(ethUsdcPool), 75_000e6); // Deploy half to ETH/USDC

        console.log("\n=== After Opening ETH/USDC Position ===");

        // Verify positions were opened
        address[] memory activePositions = positionManager.getActivePositions();
        assertEq(activePositions.length, 1, "Should have 1 active positions");

        console.log("\n=== After Opening Positions ===");
        console.log("Active positions:", activePositions.length);
        console.log("Position Manager total value:", positionManager.getTotalValue());

        // Step 3: Simulate market movements and rebalance
        skipTime(1 hours);

        // ETH price increases by 5%
        movePrice(address(ETH), INITIAL_PRICE_ETH * 105 / 100);

        // Check if rebalance is needed
        bool shouldRebalance = strategyEngine.shouldRebalance();
        console.log("\n=== Market Movement ===");
        console.log("Should rebalance:", shouldRebalance);
        console.log("Current delta exposure:", strategyEngine.getDeltaExposure());

        if (shouldRebalance) {
            rebalance();
            console.log("Rebalance executed");
            console.log("New delta exposure:", strategyEngine.getDeltaExposure());
        }

        // Step 4: Simulate yield generation
        uint256 yieldAmount = 1_500e6; // $1,500 in yield
        simulateYield(yieldAmount);

        // Harvest fees
        harvest();

        console.log("\n=== After Yield Generation ===");
        console.log("Total assets after yield:", vault.totalAssets());
        console.log("Vault USDC balance:", USDC.balanceOf(address(vault)));
        console.log("Performance fees collected:", vault.totalPerformanceFees());

        // Step 5: Request withdrawals
        requestWithdrawal(alice, aliceShares / 2); // Alice withdraws half
        requestWithdrawal(bob, bobShares); // Bob withdraws all

        console.log("\n=== Withdrawal Requests ===");
        console.log("Alice pending withdrawal:", vault.pendingWithdrawals(alice));
        console.log("Bob pending withdrawal:", vault.pendingWithdrawals(bob));

        // Step 6: Wait for withdrawal delay and process
        skipTime(25 hours); // 24 hour delay + 1 hour buffer

        uint256 aliceBalanceBefore = vault.balanceOf(alice);
        console.log("Alice USDC Shares before withdrawal:", aliceBalanceBefore);
        uint256 bobBalanceBefore = vault.balanceOf(bob);
        console.log("Bob USDC Shares before withdrawal:", bobBalanceBefore);

        // 181818181849421622805264
        // 4000000000000002974325004
        // 2750000000

        processWithdrawal(alice);
        processWithdrawal(bob);

        uint256 aliceBalanceAfter = USDC.balanceOf(alice);
        uint256 bobBalanceAfter = USDC.balanceOf(bob);

        console.log("\n=== After Withdrawals ===");
        console.log("Alice received:", aliceBalanceAfter - aliceBalanceBefore);
        console.log("Bob received:", bobBalanceAfter - bobBalanceBefore);
        console.log("Alice remaining shares:", vault.balanceOf(alice));
        console.log("Bob remaining shares:", vault.balanceOf(bob));

        // Verify profits
        uint256 aliceProfit = aliceBalanceAfter - aliceBalanceBefore > aliceDeposit / 2
            ? aliceBalanceAfter - aliceBalanceBefore - aliceDeposit / 2
            : 0;
        uint256 bobProfit =
            bobBalanceAfter - bobBalanceBefore > bobDeposit ? bobBalanceAfter - bobBalanceBefore - bobDeposit : 0;

        console.log("\n=== Profit Analysis ===");
        console.log("Alice profit:", aliceProfit);
        console.log("Bob profit:", bobProfit);

        // Assertions
        assertTrue(aliceBalanceAfter > aliceBalanceBefore, "Alice should receive funds");
        assertTrue(bobBalanceAfter > bobBalanceBefore, "Bob should receive funds");
        assertGt(vault.totalAssets(), 0, "Vault should still have assets");
        assertEq(vault.balanceOf(alice), aliceShares / 2, "Alice should have half shares remaining");
        assertEq(vault.balanceOf(bob), 0, "Bob should have no shares remaining");
    }

    function test_FullFlow_MultipleRebalancesWithVolatility() public {
        // Setup: Large deposit from Charlie
        uint256 charlieDeposit = 100e18;
        uint256 charlieShares = depositToVault(charlie, charlieDeposit);

        console.log("=== Charlie Initial Deposit ===");
        console.log("Deposit amount:", charlieDeposit);
        console.log("Shares received:", charlieShares);

        // Open multiple positions
        vm.startPrank(strategist);
        positionManager.openPosition(address(ethUsdcPool), 100e18);
        positionManager.openPosition(address(btcUsdcPool), 100e18);
        vm.stopPrank();

        // Simulate volatile market over 7 days
        for (uint256 day = 1; day <= 7; day++) {
            console.log(string.concat("\n=== Day ", vm.toString(day), " ==="));

            // Random price movements
            if (day % 2 == 0) {
                // Even days: ETH up, BTC down
                movePrice(address(ETH), INITIAL_PRICE_ETH * (100 + day * 2) / 100);
                movePrice(address(BTC), INITIAL_PRICE_BTC * (100 - day) / 100);
            } else {
                // Odd days: ETH down, BTC up
                movePrice(address(ETH), INITIAL_PRICE_ETH * (100 - day) / 100);
                movePrice(address(BTC), INITIAL_PRICE_BTC * (100 + day * 2) / 100);
            }

            // Increase volatility
            increaseVolatility(address(ETH), (20 + day * 2) * 1e16);
            increaseVolatility(address(BTC), (25 + day * 2) * 1e16);

            // Check health and rebalance if needed
            bool isHealthy = riskManager.checkHealthFactors();
            console.log("Health check passed:", isHealthy);

            if (strategyEngine.shouldRebalance() && isHealthy) {
                rebalance();
                console.log("Rebalanced at delta:", strategyEngine.getDeltaExposure());
            }

            // Generate daily yield
            uint256 dailyYield = 200e6 + (day * 50e6); // Increasing daily yield
            simulateYield(dailyYield);

            // Skip to next day
            skipTime(1 days);
        }

        // Harvest accumulated fees
        harvest();

        console.log("\n=== After 7 Days ===");
        console.log("Total assets:", vault.totalAssets());
        // console.log("Total value locked:", positionManager.totalValueLocked);
        console.log("Performance fees:", vault.totalPerformanceFees());


        ensureLiquidityForWithdrawal(charlie);


        vm.roll(block.number + 12);

        // Charlie withdraws
        requestWithdrawal(charlie, charlieShares);
        skipTime(25 hours);

        uint256 charlieBalanceBefore = USDC.balanceOf(charlie);
        processWithdrawal(charlie);
        uint256 charlieBalanceAfter = USDC.balanceOf(charlie);

        uint256 charlieReceived = charlieBalanceAfter - charlieBalanceBefore;
        uint256 charlieProfit = charlieReceived > charlieDeposit ? charlieReceived - charlieDeposit : 0;

        console.log("\n=== Charlie Withdrawal ===");
        console.log("Amount received:", charlieReceived);
        console.log("Profit:", charlieProfit);
        console.log("ROI:", (charlieProfit * 10000 / charlieDeposit), "bps");

        // Verify profit
        assertGt(charlieReceived, charlieDeposit, "Charlie should have made a profit");
        assertGt(charlieProfit, 1000e6, "Profit should be significant after 7 days");
    }

    function test_FullFlow_EmergencyScenarioAndRecovery() public {
        // Setup: Multiple deposits
        depositToVault(alice, 200_000e6);
        depositToVault(bob, 150_000e6);
        depositToVault(charlie, 300_000e6);

        console.log("=== Initial Deposits Complete ===");
        console.log("Total assets:", vault.totalAssets());

        // Open positions
        vm.startPrank(strategist);
        positionManager.openPosition(address(ethUsdcPool), 300_000e6);
        positionManager.openPosition(address(btcUsdcPool), 300_000e6);
        vm.stopPrank();

        // Simulate extreme market crash
        skipTime(1 hours);
        movePrice(address(ETH), INITIAL_PRICE_ETH * 70 / 100); // 30% crash
        movePrice(address(BTC), INITIAL_PRICE_BTC * 65 / 100); // 35% crash

        // Increase volatility dramatically
        increaseVolatility(address(ETH), 60e16); // 60% volatility
        increaseVolatility(address(BTC), 70e16); // 70% volatility

        console.log("\n=== Market Crash ===");
        console.log("ETH price drop: 30%");
        console.log("BTC price drop: 35%");

        // Check if circuit breaker should trip
        vm.prank(guardian);
        riskManager.performRiskAssessment();

        // Guardian pauses the vault
        vm.prank(guardian);
        vault.pause();

        console.log("\n=== Emergency Response ===");
        console.log("Vault paused: true");

        // Try to deposit (should fail)
        vm.expectRevert("Pausable: paused");
        depositToVault(alice, 10_000e6);

        // Admin unpauses after stabilization
        skipTime(6 hours);
        movePrice(address(ETH), INITIAL_PRICE_ETH * 85 / 100); // Partial recovery
        movePrice(address(BTC), INITIAL_PRICE_BTC * 80 / 100); // Partial recovery

        vm.prank(admin_);
        vault.unpause();

        // Close risky positions
        vm.startPrank(strategist);
        positionManager.closePosition(address(ethUsdcPool));
        positionManager.closePosition(address(btcUsdcPool));
        vm.stopPrank();

        console.log("\n=== Recovery Phase ===");
        console.log("Positions closed");
        console.log("Final vault value:", vault.totalAssets());

        // Process emergency withdrawals
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares = vault.balanceOf(bob);
        uint256 charlieShares = vault.balanceOf(charlie);

        requestWithdrawal(alice, aliceShares);
        requestWithdrawal(bob, bobShares);
        requestWithdrawal(charlie, charlieShares);

        skipTime(25 hours);

        uint256 totalRecovered = 0;

        // Process all withdrawals
        uint256 aliceBalanceBefore = USDC.balanceOf(alice);
        processWithdrawal(alice);
        uint256 aliceReceived = USDC.balanceOf(alice) - aliceBalanceBefore;
        totalRecovered += aliceReceived;

        uint256 bobBalanceBefore = USDC.balanceOf(bob);
        processWithdrawal(bob);
        uint256 bobReceived = USDC.balanceOf(bob) - bobBalanceBefore;
        totalRecovered += bobReceived;

        uint256 charlieBalanceBefore = USDC.balanceOf(charlie);
        processWithdrawal(charlie);
        uint256 charlieReceived = USDC.balanceOf(charlie) - charlieBalanceBefore;
        totalRecovered += charlieReceived;

        console.log("\n=== Final Withdrawals ===");
        console.log("Alice recovered:", aliceReceived);
        console.log("Bob recovered:", bobReceived);
        console.log("Charlie recovered:", charlieReceived);
        console.log("Total recovered:", totalRecovered);
        // console.log("Total deposited:", 650_000e6);
        console.log("Loss percentage:", (650_000e6 - totalRecovered) * 100 / 650_000e6, "%");

        // Verify recovery
        assertGt(totalRecovered, 650_000e6 * 70 / 100, "Should recover at least 70% after crash");
        assertEq(vault.totalAssets(), 0, "Vault should be empty after full withdrawal");
    }

    function test_FullFlow_FeeAccrualAndDistribution() public {
        // Setup with admin_ setting fees
        vm.startPrank(admin_);
        vault.setFees(2000, 100); // 20% performance fee, 1% management fee
        vm.stopPrank();

        // Multiple deposits
        depositToVault(alice, 100_000e6);
        depositToVault(bob, 100_000e6);

        // Open positions
        vm.prank(strategist);
        positionManager.openPosition(address(ethUsdcPool), 150_000e6);

        console.log("=== Fee Test Setup ===");
        console.log("Performance fee: 20%");
        console.log("Management fee: 1%");
        console.log("Total deposited: 200,000 USDC");

        // Simulate 30 days of operation
        for (uint256 week = 1; week <= 4; week++) {
            console.log(string.concat("\n=== Week ", vm.toString(week), " ==="));

            // Weekly yield generation
            uint256 weeklyYield = 2_000e6; // $2,000 per week
            simulateYield(weeklyYield);

            // Harvest performance fees
            harvest();

            // Skip a week
            skipTime(7 days);

            console.log("Weekly yield:", weeklyYield);
            console.log("Total performance fees:", vault.totalPerformanceFees());
            console.log("Total management fees:", vault.totalManagementFees());
        }

        // Final harvest and fee collection
        harvest();

        uint256 totalYield = 8_000e6; // 4 weeks * $2,000
        uint256 expectedPerformanceFees = totalYield * 2000 / 10000; // 20%
        // uint256 expectedManagementFees = 200_000e6 * 100 * 30 / (10000 * 365); // ~16.4 USDC

        console.log("\n=== Final Fee Analysis ===");
        console.log("Total yield generated:", totalYield);
        console.log("Expected performance fees:", expectedPerformanceFees);
        console.log("Actual performance fees:", vault.totalPerformanceFees());
        // console.log("Expected management fees:", expectedManagementFees);
        console.log("Actual management fees:", vault.totalManagementFees());

        // Verify fee accrual
        assertApproxEqAbs(
            vault.totalPerformanceFees(), expectedPerformanceFees, 10e6, "Performance fees should match expected"
        );
        assertGt(vault.totalManagementFees(), 0, "Management fees should accrue");

        // Users withdraw to see net returns
        requestWithdrawal(alice, vault.balanceOf(alice));
        requestWithdrawal(bob, vault.balanceOf(bob));

        skipTime(25 hours);

        uint256 aliceBalanceBefore = USDC.balanceOf(alice);
        uint256 bobBalanceBefore = USDC.balanceOf(bob);

        processWithdrawal(alice);
        processWithdrawal(bob);

        uint256 aliceNet = USDC.balanceOf(alice) - aliceBalanceBefore - 100_000e6;
        uint256 bobNet = USDC.balanceOf(bob) - bobBalanceBefore - 100_000e6;

        console.log("\n=== Net Returns After Fees ===");
        console.log("Alice net return:", aliceNet);
        console.log("Bob net return:", bobNet);
        console.log("Total net return:", aliceNet + bobNet);
        console.log("Fees paid:", totalYield - (aliceNet + bobNet));

        // Verify users still made profit after fees
        assertGt(aliceNet, 0, "Alice should have positive returns after fees");
        assertGt(bobNet, 0, "Bob should have positive returns after fees");
    }
}
