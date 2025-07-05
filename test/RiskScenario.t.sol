// // SPDX-License-Identifier: GPL-2.0-or-later
// pragma solidity ^0.8.27;

// import {DeltaNeutralVaultTestBase} from "./DeltaNeutralVaultBase.t.sol";
// import {console} from "forge-std/Test.sol";
// import {IPositionManager} from "../src/interfaces/IPositionManager.sol";

// contract DeltaNeutralVaultRiskScenariosTest is DeltaNeutralVaultTestBase {

//     function test_RiskScenario_HighVolatilityMarketStress() public {
//         // Large institutional deposit
//         uint256 institutionalDeposit = 1_000_000e6;
//         USDC.mint(charlie, institutionalDeposit);
//         uint256 charlieShares = depositToVault(charlie, institutionalDeposit);

//         console.log("=== High Volatility Market Stress Test ===");
//         console.log("Institutional deposit:", institutionalDeposit);

//         // Deploy capital across multiple positions
//         vm.startPrank(strategist);
//         positionManager.openPosition(address(ethUsdcPool), 400_000e6);
//         positionManager.openPosition(address(btcUsdcPool), 400_000e6);
//         vm.stopPrank();

//         // Simulate 24 hours of extreme volatility
//         for (uint256 hour = 0; hour < 24; hour++) {
//             console.log(string.concat("\n--- Hour ", vm.toString(hour), " ---"));

//             // Oscillating prices with increasing amplitude
//             uint256 amplitude = 5 + (hour * 2); // 5% to 53% swings

//             if (hour % 2 == 0) {
//                 // Even hours: prices up
//                 movePrice(address(ETH), INITIAL_PRICE_ETH * (100 + amplitude) / 100);
//                 movePrice(address(BTC), INITIAL_PRICE_BTC * (100 + amplitude / 2) / 100);
//             } else {
//                 // Odd hours: prices down
//                 movePrice(address(ETH), INITIAL_PRICE_ETH * (100 - amplitude) / 100);
//                 movePrice(address(BTC), INITIAL_PRICE_BTC * (100 - amplitude / 2) / 100);
//             }

//             // Update volatility
//             increaseVolatility(address(ETH), (30 + hour) * 1e16);
//             increaseVolatility(address(BTC), (35 + hour) * 1e16);

//             // Risk assessment every 4 hours
//             if (hour % 4 == 0) {
//                 vm.prank(guardian);
//                 riskManager.performRiskAssessment();

//                 // Get portfolio risk metrics
//                 (uint256 leverage, uint256 avgHealth, uint256 volatility, bool hasHighRisk) =
//                     riskManager.getPortfolioRiskMetrics();

//                 console.log("Leverage:", leverage);
//                 console.log("Avg Health Factor:", avgHealth);
//                 console.log("Portfolio Volatility:", volatility);
//                 console.log("High Risk Positions:", hasHighRisk);

//                 // Check if emergency action needed
//                 if (avgHealth < 130) {
//                     console.log("CRITICAL: Low health factor detected!");

//                     // Emergency deleverage if position at risk
//                     address[] memory positions = positionManager.getActivePositions();
//                     for (uint i = 0; i < positions.length; i++) {
//                         if (riskManager.isPositionAtRisk(positions[i])) {
//                             vm.prank(guardian);
//                             try riskManager.emergencyDeleverage(positions[i]) {
//                                 console.log("Emergency deleverage executed for position", i);
//                             } catch {
//                                 console.log("Emergency deleverage failed for position", i);
//                             }
//                         }
//                     }
//                 }
//             }

//             // Attempt rebalance if needed
//             if (strategyEngine.shouldRebalance()) {
//                 try vault.rebalance() {
//                     console.log("Rebalanced at delta:", strategyEngine.getDeltaExposure());
//                 } catch {
//                     console.log("Rebalance failed - risk checks not passed");
//                 }
//             }

//             skipTime(1 hours);
//         }

//         console.log("\n=== After 24 Hours of Stress ===");
//         console.log("Vault still operational:", !vault.paused());
//         console.log("Final vault value:", vault.totalAssets());
//         console.log("Value retention:", vault.totalAssets() * 100 / institutionalDeposit, "%");

//         // Verify vault survived
//         assertGt(vault.totalAssets(), institutionalDeposit * 70 / 100, "Should retain at least 70% value");
//     }

//     function test_RiskScenario_CorrelatedAssetCrash() public {
//         // Setup positions
//         depositToVault(alice, 300_000e6);
//         depositToVault(bob, 200_000e6);

//         vm.startPrank(strategist);
//         positionManager.openPosition(address(ethUsdcPool), 250_000e6);
//         positionManager.openPosition(address(btcUsdcPool), 200_000e6);
//         vm.stopPrank();

//         console.log("=== Correlated Asset Crash Scenario ===");
//         console.log("Initial positions opened");

//         // Simulate crypto market crash (both assets crash together)
//         uint256[] memory crashPercentages = new uint256[](5);
//         crashPercentages[0] = 10; // -10%
//         crashPercentages[1] = 20; // -20%
//         crashPercentages[2] = 35; // -35%
//         crashPercentages[3] = 45; // -45%
//         crashPercentages[4] = 40; // Recovery to -40%

//         for (uint256 i = 0; i < crashPercentages.length; i++) {
//             skipTime(30 minutes);

//             console.log(string.concat("\n--- Stage ", vm.toString(i + 1), " ---"));
//             console.log("Market down:", crashPercentages[i], "%");

//             // Both assets crash in correlation
//             movePrice(address(ETH), INITIAL_PRICE_ETH * (100 - crashPercentages[i]) / 100);
//             movePrice(address(BTC), INITIAL_PRICE_BTC * (100 - crashPercentages[i]) / 100);

//             // Check circuit breaker conditions
//             (int256 currentDelta, uint256 deltaDeviation, , bool needsRebalance) =
//                 strategyEngine.getStrategyHealth();

//             console.log("Current delta:", currentDelta);
//             console.log("Delta deviation:", deltaDeviation);
//             console.log("Needs rebalance:", needsRebalance);

//             // Risk manager should detect the crash pattern
//             if (i >= 2) { // After 35% crash
//                 // Circuit breaker should trip
//                 if (!riskManager.circuitBreaker().isTripped) {
//                     vm.prank(guardian);
//                     riskManager.tripCircuitBreaker("Correlated asset crash detected");
//                     console.log("Circuit breaker tripped!");
//                 }
//             }
//         }

//         // Attempt recovery operations
//         console.log("\n=== Recovery Operations ===");

//         // Wait for circuit breaker cooldown
//         if (riskManager.circuitBreaker().isTripped) {
//             skipTime(5 hours);
//             vm.prank(guardian);
//             riskManager.resetCircuitBreaker();
//         }

//         // Close positions to stop bleeding
//         vm.startPrank(strategist);
//         address[] memory positions = positionManager.getActivePositions();
//         for (uint i = 0; i < positions.length; i++) {
//             try positionManager.closePosition(positions[i]) {
//                 console.log("Closed position:", positions[i]);
//             } catch {
//                 console.log("Failed to close position:", positions[i]);
//             }
//         }
//         vm.stopPrank();

//         console.log("\n=== Final State ===");
//         console.log("Total value locked:", positionManager.getTotalValue());
//         console.log("Vault total assets:", vault.totalAssets());

//         // Process user withdrawals
//         requestWithdrawal(alice, vault.balanceOf(alice));
//         requestWithdrawal(bob, vault.balanceOf(bob));

//         skipTime(25 hours);

//         uint256 aliceBalanceBefore = USDC.balanceOf(alice);
//         uint256 bobBalanceBefore = USDC.balanceOf(bob);

//         processWithdrawal(alice);
//         processWithdrawal(bob);

//         uint256 aliceRecovered = USDC.balanceOf(alice) - aliceBalanceBefore;
//         uint256 bobRecovered = USDC.balanceOf(bob) - bobBalanceBefore;

//         console.log("Alice recovered:", aliceRecovered, "from", 300_000e6);
//         console.log("Bob recovered:", bobRecovered, "from", 200_000e6);

//         // Should have protected some capital
//         assertGt(aliceRecovered + bobRecovered, 300_000e6, "Should recover more than 60% in crash");
//     }

//     function test_RiskScenario_LiquidityCrisis() public {
//         // Setup: Multiple large deposits
//         depositToVault(alice, 400_000e6);
//         depositToVault(bob, 300_000e6);
//         depositToVault(charlie, 300_000e6);

//         console.log("=== Liquidity Crisis Scenario ===");
//         console.log("Total deposits:", 1_000_000e6);

//         // Deploy most capital
//         vm.startPrank(strategist);
//         positionManager.openPosition(address(ethUsdcPool), 450_000e6);
//         positionManager.openPosition(address(btcUsdcPool), 450_000e6);
//         vm.stopPrank();

//         console.log("Capital deployed:", 900_000e6);
//         console.log("Idle capital:", vault.totalAssets() - 900_000e6);

//         // Suddenly, everyone wants to withdraw (bank run scenario)
//         requestWithdrawal(alice, vault.balanceOf(alice));
//         requestWithdrawal(bob, vault.balanceOf(bob));
//         requestWithdrawal(charlie, vault.balanceOf(charlie));

//         console.log("\n=== Bank Run Initiated ===");
//         console.log("Total withdrawal requests:", vault.pendingWithdrawals(alice) +
//             vault.pendingWithdrawals(bob) + vault.pendingWithdrawals(charlie));

//         // Market also crashes during withdrawal period
//         skipTime(12 hours);
//         movePrice(address(ETH), INITIAL_PRICE_ETH * 80 / 100); // -20%
//         movePrice(address(BTC), INITIAL_PRICE_BTC * 75 / 100); // -25%

//         console.log("\n=== Market Crash During Withdrawals ===");
//         console.log("ETH down 20%, BTC down 25%");

//         // Vault needs to close positions to meet withdrawals
//         vm.startPrank(strategist);

//         // Calculate how much liquidity is needed
//         uint256 totalPendingWithdrawals = vault.convertToAssets(
//             vault.pendingWithdrawals(alice) +
//             vault.pendingWithdrawals(bob) +
//             vault.pendingWithdrawals(charlie)
//         );

//         console.log("Liquidity needed:", totalPendingWithdrawals);
//         console.log("Current idle funds:", USDC.balanceOf(address(vault)));

//         // Close positions to raise liquidity
//         address[] memory positions = positionManager.getActivePositions();
//         for (uint i = 0; i < positions.length; i++) {
//             IPositionManager.Position memory pos = positionManager.getPosition(positions[i]);
//             console.log(string.concat("\nClosing position ", vm.toString(i)));
//             console.log("Position value before closing:", pos.amount0 + pos.amount1);

//             positionManager.closePosition(positions[i]);
//         }
//         vm.stopPrank();

//         console.log("\n=== After Position Closures ===");
//         console.log("Available liquidity:", USDC.balanceOf(address(vault)));

//         // Process withdrawals after delay
//         skipTime(13 hours); // Complete 25 hour delay

//         uint256[] memory balancesBefore = new uint256[](3);
//         balancesBefore[0] = USDC.balanceOf(alice);
//         balancesBefore[1] = USDC.balanceOf(bob);
//         balancesBefore[2] = USDC.balanceOf(charlie);

//         // Process in order
//         processWithdrawal(alice);
//         processWithdrawal(bob);
//         processWithdrawal(charlie);

//         uint256[] memory received = new uint256[](3);
//         received[0] = USDC.balanceOf(alice) - balancesBefore[0];
//         received[1] = USDC.balanceOf(bob) - balancesBefore[1];
//         received[2] = USDC.balanceOf(charlie) - balancesBefore[2];

//         console.log("\n=== Withdrawal Results ===");
//         console.log("Alice received:", received[0], "(", received[0] * 100 / 400_000e6, "%)");
//         console.log("Bob received:", received[1], "(", received[1] * 100 / 300_000e6, "%)");
//         console.log("Charlie received:", received[2], "(", received[2] * 100 / 300_000e6, "%)");

//         uint256 totalRecovered = received[0] + received[1] + received[2];
//         console.log("Total recovered:", totalRecovered);
//         console.log("Recovery rate:", totalRecovered * 100 / 1_000_000e6, "%");

//         // Verify orderly liquidation
//         assertGt(totalRecovered, 750_000e6, "Should recover at least 75% despite crisis");
//         assertTrue(received[0] > 0 && received[1] > 0 && received[2] > 0, "All users should receive funds");
//     }

//     function test_RiskScenario_ComplexRebalancingUnderStress() public {
//         // Setup with specific risk parameters
//         vm.prank(admin_);
//         riskManager.updateRiskParams(
//             IRiskManager.RiskParams({
//                 maxLeverage: 200, // 2x max
//                 minCollateralRatio: 150,
//                 maxPositionConcentration: 40,
//                 maxCorrelation: 60,
//                 emergencyDeleverageRatio: 125
//             })
//         );

//         depositToVault(alice, 500_000e6);

//         console.log("=== Complex Rebalancing Under Stress ===");

//         // Open leveraged positions
//         vm.startPrank(strategist);
//         positionManager.openPosition(address(ethUsdcPool), 200_000e6);
//         positionManager.openPosition(address(btcUsdcPool), 200_000e6);
//         vm.stopPrank();

//         // Simulate complex market conditions over 48 hours
//         for (uint256 i = 0; i < 48; i++) {
//             console.log(string.concat("\n--- Hour ", vm.toString(i), " ---"));

//             // Complex price movements
//             if (i < 12) {
//                 // First 12 hours: ETH rallies, BTC falls
//                 movePrice(address(ETH), INITIAL_PRICE_ETH * (100 + i * 3) / 100);
//                 movePrice(address(BTC), INITIAL_PRICE_BTC * (100 - i * 2) / 100);
//             } else if (i < 24) {
//                 // Next 12 hours: Both crash
//                 uint256 crashPercent = (i - 12) * 3;
//                 movePrice(address(ETH), INITIAL_PRICE_ETH * (136 - crashPercent) / 100);
//                 movePrice(address(BTC), INITIAL_PRICE_BTC * (76 - crashPercent / 2) / 100);
//             } else if (i < 36) {
//                 // Recovery phase with high volatility
//                 uint256 recoveryHour = i - 24;
//                 if (recoveryHour % 3 == 0) {
//                     movePrice(address(ETH), INITIAL_PRICE_ETH * (100 + recoveryHour) / 100);
//                     movePrice(address(BTC), INITIAL_PRICE_BTC * (70 + recoveryHour) / 100);
//                 } else {
//                     movePrice(address(ETH), INITIAL_PRICE_ETH * (95 + recoveryHour / 2) / 100);
//                     movePrice(address(BTC), INITIAL_PRICE_BTC * (65 + recoveryHour / 2) / 100);
//                 }
//             } else {
//                 // Stabilization
//                 movePrice(address(ETH), INITIAL_PRICE_ETH * 110 / 100);
//                 movePrice(address(BTC), INITIAL_PRICE_BTC * 95 / 100);
//             }

//             // Check and perform rebalancing
//             if (i % 6 == 0) { // Every 6 hours
//                 console.log("Delta before rebalance:", strategyEngine.getDeltaExposure());

//                 bool shouldRebalance = strategyEngine.shouldRebalance();
//                 bool isHealthy = riskManager.checkHealthFactors();

//                 console.log("Should rebalance:", shouldRebalance);
//                 console.log("Health check:", isHealthy);

//                 if (shouldRebalance && isHealthy) {
//                     // Check if rebalance is safe
//                     bytes memory strategyData = strategyEngine.calculateOptimalAllocations();
//                     bool isSafe = riskManager.isRebalanceSafe(strategyData);

//                     if (isSafe) {
//                         vm.prank(strategist);
//                         vault.rebalance();
//                         console.log("Rebalanced successfully");
//                     } else {
//                         console.log("Rebalance deemed unsafe by risk manager");
//                     }
//                 }
//             }

//             // Simulate small yields
//             if (i % 12 == 0) {
//                 simulateYield(500e6);
//                 harvest();
//             }

//             skipTime(1 hours);
//         }

//         console.log("\n=== Final Results After 48 Hours ===");
//         console.log("Final vault value:", vault.totalAssets());
//         console.log("Number of rebalances:", vault.totalRebalances());
//         console.log("Total fees earned:", vault.totalPerformanceFees());

//         // Verify vault maintained stability
//         assertGt(vault.totalAssets(), 480_000e6, "Should maintain most value through stress");
//         assertGt(vault.totalRebalances(), 3, "Should have rebalanced multiple times");
//     }
// }
