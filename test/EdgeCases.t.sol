// // SPDX-License-Identifier: GPL-2.0-or-later
// pragma solidity ^0.8.27;

// import {DeltaNeutralVaultTestBase} from "./DeltaNeutralVaultBase.t.sol";
// import {console} from "forge-std/console.sol";

// contract DeltaNeutralVaultEdgeCasesTest is DeltaNeutralVaultTestBase {

//     function test_EdgeCase_RapidDepositWithdrawCycles() public {
//         // Test rapid deposit/withdraw cycles to check for rounding errors
//         uint256 initialDeposit = 100_000e6;
//         uint256 aliceInitialBalance = USDC.balanceOf(alice);

//         console.log("=== Rapid Cycle Test ===");

//         for (uint256 i = 1; i <= 5; i++) {
//             console.log(string.concat("\nCycle ", vm.toString(i)));

//             // Deposit
//             uint256 shares = depositToVault(alice, initialDeposit);
//             console.log("Shares received:", shares);

//             // Open position to generate some activity
//             if (i == 1) {
//                 vm.prank(strategist);
//                 positionManager.openPosition(address(ethUsdcPool), 50_000e6);
//             }

//             // Generate small yield
//             simulateYield(100e6);
//             harvest();

//             // Request withdrawal
//             requestWithdrawal(alice, shares);
//             skipTime(25 hours);

//             // Process withdrawal
//             uint256 balanceBefore = USDC.balanceOf(alice);
//             processWithdrawal(alice);
//             uint256 received = USDC.balanceOf(alice) - balanceBefore;

//             console.log("Amount received:", received);
//             console.log("Difference:", int256(received) - int256(initialDeposit));
//         }

//         uint256 aliceFinalBalance = USDC.balanceOf(alice);
//         console.log("\n=== Final Results ===");
//         console.log("Net change:", int256(aliceFinalBalance) - int256(aliceInitialBalance));

//         // Should have made some profit from yields
//         assertGt(aliceFinalBalance, aliceInitialBalance, "Should have net positive after cycles");
//     }

//     function test_EdgeCase_MultipleUsersSimultaneousActions() public {
//         // Test multiple users performing actions in the same block
//         uint256[] memory deposits = new uint256[](3);
//         deposits[0] = 100_000e6; // Alice
//         deposits[1] = 75_000e6;  // Bob
//         deposits[2] = 125_000e6; // Charlie

//         console.log("=== Simultaneous Actions Test ===");

//         // All users deposit in same block
//         uint256 aliceShares = depositToVault(alice, deposits[0]);
//         uint256 bobShares = depositToVault(bob, deposits[1]);
//         uint256 charlieShares = depositToVault(charlie, deposits[2]);

//         console.log("Total assets after deposits:", vault.totalAssets());
//         console.log("Total supply:", vault.totalSupply());

//         // Open positions
//         vm.startPrank(strategist);
//         positionManager.openPosition(address(ethUsdcPool), 150_000e6);
//         positionManager.openPosition(address(btcUsdcPool), 100_000e6);
//         vm.stopPrank();

//         // All users request withdrawal in same block
//         requestWithdrawal(alice, aliceShares / 2);
//         requestWithdrawal(bob, bobShares);
//         requestWithdrawal(charlie, charlieShares / 3);

//         console.log("\n=== Pending Withdrawals ===");
//         console.log("Alice pending:", vault.pendingWithdrawals(alice));
//         console.log("Bob pending:", vault.pendingWithdrawals(bob));
//         console.log("Charlie pending:", vault.pendingWithdrawals(charlie));

//         // Generate yield before processing
//         simulateYield(3_000e6);
//         harvest();

//         skipTime(25 hours);

//         // All process withdrawals in same block
//         uint256[] memory balancesBefore = new uint256[](3);
//         balancesBefore[0] = USDC.balanceOf(alice);
//         balancesBefore[1] = USDC.balanceOf(bob);
//         balancesBefore[2] = USDC.balanceOf(charlie);

//         processWithdrawal(alice);
//         processWithdrawal(bob);
//         processWithdrawal(charlie);

//         uint256[] memory received = new uint256[](3);
//         received[0] = USDC.balanceOf(alice) - balancesBefore[0];
//         received[1] = USDC.balanceOf(bob) - balancesBefore[1];
//         received[2] = USDC.balanceOf(charlie) - balancesBefore[2];

//         console.log("\n=== Withdrawals Processed ===");
//         console.log("Alice received:", received[0]);
//         console.log("Bob received:", received[1]);
//         console.log("Charlie received:", received[2]);

//         // Verify proportional distribution
//         uint256 totalWithdrawn = received[0] + received[1] + received[2];
//         console.log("Total withdrawn:", totalWithdrawn);
//         console.log("Remaining in vault:", vault.totalAssets());

//         assertTrue(received[0] > 0 && received[1] > 0 && received[2] > 0, "All should receive funds");
//     }

//     function test_EdgeCase_ExtremePriceMovements() public {
//         // Setup positions
//         depositToVault(alice, 500_000e6);

//         vm.startPrank(strategist);
//         positionManager.openPosition(address(ethUsdcPool), 200_000e6);
//         positionManager.openPosition(address(btcUsdcPool), 200_000e6);
//         vm.stopPrank();

//         console.log("=== Extreme Price Movement Test ===");
//         console.log("Initial delta:", strategyEngine.getDeltaExposure());

//         // Simulate flash crash and recovery
//         uint256 originalETHPrice = priceOracle.prices(address(ETH));
//         uint256 originalBTCPrice = priceOracle.prices(address(BTC));

//         // Flash crash - 50% drop
//         movePrice(address(ETH), originalETHPrice / 2);
//         movePrice(address(BTC), originalBTCPrice / 2);

//         console.log("\n=== Flash Crash ===");
//         console.log("Prices dropped 50%");

//         // Check health factors
//         bool isHealthy = riskManager.checkHealthFactors();
//         console.log("Health check:", isHealthy);

//         if (!isHealthy) {
//             // Emergency deleverage should trigger
//             address[] memory positions = positionManager.getActivePositions();
//             for (uint i = 0; i < positions.length; i++) {
//                 if (!positionManager.isPositionHealthy(positions[i])) {
//                     console.log("Unhealthy position:", positions[i]);

//                     // Guardian intervenes
//                     vm.prank(guardian);
//                     riskManager.emergencyDeleverage(positions[i]);
//                 }
//             }
//         }

//         // Rapid recovery - back to 90% of original
//         skipTime(1 hours);
//         movePrice(address(ETH), originalETHPrice * 90 / 100);
//         movePrice(address(BTC), originalBTCPrice * 90 / 100);

//         console.log("\n=== Recovery Phase ===");
//         console.log("Prices recovered to 90%");
//         console.log("Final vault value:", vault.totalAssets());

//         // Verify vault survived
//         assertGt(vault.totalAssets(), 400_000e6, "Vault should retain most value after crash");
//     }

//     function test_EdgeCase_RebalanceFailuresAndRetries() public {
//         depositToVault(alice, 300_000e6);

//         // Open initial positions
//         vm.startPrank(strategist);
//         positionManager.openPosition(address(ethUsdcPool), 150_000e6);
//         vm.stopPrank();

//         console.log("=== Rebalance Failure Test ===");

//         // Create condition that makes rebalance fail
//         // Set oracle as manipulated
//         priceOracle.setManipulated(address(ETH), true);

//         // Try to rebalance - should fail due to oracle manipulation
//         vm.expectRevert();
//         rebalance();

//         console.log("Rebalance failed due to oracle manipulation");

//         // Fix oracle
//         priceOracle.setManipulated(address(ETH), false);

//         // Create extreme volatility that triggers circuit breaker
//         increaseVolatility(address(ETH), 100e16); // 100% volatility

//         // Perform risk assessment which should trip circuit breaker
//         vm.prank(guardian);
//         riskManager.performRiskAssessment();

//         // Try to rebalance - should fail due to circuit breaker
//         vm.expectRevert("CircuitBreakerActive()");
//         rebalance();

//         console.log("Rebalance failed due to circuit breaker");

//         // Wait for cooldown and reset circuit breaker
//         skipTime(5 hours);
//         vm.prank(guardian);
//         riskManager.resetCircuitBreaker();

//         // Reduce volatility
//         increaseVolatility(address(ETH), 25e16);

//         // Now rebalance should work
//         rebalance();
//         console.log("Rebalance successful after fixes");

//         assertTrue(true, "Rebalance recovery flow completed");
//     }

//     function test_EdgeCase_ZeroLiquidityScenario() public {
//         // Test behavior when all liquidity is withdrawn
//         uint256 deposit1 = 100_000e6;
//         uint256 deposit2 = 50_000e6;

//         uint256 shares1 = depositToVault(alice, deposit1);
//         uint256 shares2 = depositToVault(bob, deposit2);

//         console.log("=== Zero Liquidity Test ===");
//         console.log("Initial deposits:", deposit1 + deposit2);

//         // Both users request full withdrawal
//         requestWithdrawal(alice, shares1);
//         requestWithdrawal(bob, shares2);

//         skipTime(25 hours);

//         // Process withdrawals - vault should be empty
//         processWithdrawal(alice);
//         processWithdrawal(bob);

//         console.log("Vault total assets:", vault.totalAssets());
//         console.log("Vault total supply:", vault.totalSupply());

//         assertEq(vault.totalAssets(), 0, "Vault should be empty");
//         assertEq(vault.totalSupply(), 0, "No shares should exist");

//         // Try to deposit again after zero liquidity
//         uint256 newDeposit = 10_000e6;
//         uint256 newShares = depositToVault(charlie, newDeposit);

//         console.log("\n=== Reinitialization ===");
//         console.log("New deposit:", newDeposit);
//         console.log("New shares:", newShares);

//         assertGt(newShares, 0, "Should be able to deposit after zero liquidity");
//         assertEq(vault.totalAssets(), newDeposit, "Assets should match new deposit");
//     }

//     function test_EdgeCase_MaxCapacityAndOverflow() public {
//         // Test vault behavior at maximum capacity
//         uint256 maxDeposit = type(uint112).max / 2; // Half of max to leave room for operations

//         // Mint enough USDC for test
//         USDC.mint(charlie, maxDeposit);

//         console.log("=== Max Capacity Test ===");
//         console.log("Attempting max deposit:", maxDeposit);

//         // This should succeed
//         uint256 shares = depositToVault(charlie, maxDeposit);
//         console.log("Shares received:", shares);

//         // Try to deposit more - should handle gracefully
//         USDC.mint(alice, 1000e6);
//         vm.startPrank(alice);
//         USDC.approve(address(vault), 1000e6);

//         // Check if deposit would exceed limits
//         uint256 maxAssets = vault.maxDeposit(alice);
//         console.log("Max additional deposit allowed:", maxAssets);

//         if (maxAssets < 1000e6) {
//             vm.expectRevert();
//             vault.deposit(1000e6, alice);
//             console.log("Deposit correctly rejected at capacity");
//         } else {
//             vault.deposit(1000e6, alice);
//             console.log("Small deposit still allowed");
//         }
//         vm.stopPrank();

//         assertTrue(shares > 0, "Large deposit should succeed");
//     }

//     function test_EdgeCase_ProtocolIntegrationFailure() public {
//         // Test handling of external protocol failures
//         depositToVault(alice, 200_000e6);

//         console.log("=== Protocol Integration Failure Test ===");

//         // Simulate Euler vault issue by removing liquidity
//         vm.prank(address(this));
//         eUSDC.withdraw(eUSDC.balanceOf(address(this)), address(this), address(this));

//         console.log("USDC vault liquidity removed");

//         // Try to open position - might fail due to insufficient liquidity
//         vm.prank(strategist);
//         try positionManager.openPosition(address(ethUsdcPool), 150_000e6) {
//             console.log("Position opened despite low liquidity");
//         } catch {
//             console.log("Position opening failed due to liquidity constraints");
//         }

//         // Restore liquidity
//         USDC.approve(address(eUSDC), type(uint256).max);
//         eUSDC.deposit(1_000_000e6, address(this));

//         // Retry position opening
//         vm.prank(strategist);
//         positionManager.openPosition(address(ethUsdcPool), 100_000e6);
//         console.log("Position opened after liquidity restoration");

//         assertTrue(positionManager.getActivePositions().length > 0, "Should have active positions");
//     }
// }
