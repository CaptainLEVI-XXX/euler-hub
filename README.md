# 🧠 Delta Neutral Vault Protocol

## Overview

Delta Neutral Vault is a capital-efficient, actively managed ERC4626-compliant vault that automatically maintains delta-neutral positions through on-chain rebalancing, powered by risk-aware strategies and smart automation.

Users deposit stablecoins like **USDC** to earn yield from **market-neutral DeFi strategies**, while the protocol ensures capital safety using circuit breakers, health checks, and automated deleveraging.

---

## 🏗️ Architecture

### 1. **Vault Layer - `DeltaNeutralVault.sol`**
- Entry point for users to **deposit**, **withdraw**, and **earn yield**.
- Implements ERC4626 logic for **share accounting**.
- Handles:
  - Management & performance fees
  - Withdrawal queuing with time delay
  - Capital deployment to strategies

---

### 2. **Execution Layer - `PositionManager` (interface)**
- Executes and manages **long/short positions** based on strategy allocation.
- Handles:
  - Opening/closing LP positions
  - Borrowing and lending
  - Claiming yield or incentive rewards
  - Emergency deleveraging

---

### 3. **Strategy Layer - `StrategyEngine.sol`**
- Calculates **optimal portfolio allocations** using:
  - 24h trading volume
  - 30-day volatility
  - Asset correlation
- Ensures **target delta exposure** remains near 0.
- Triggers **rebalances** based on time, gas cost, and deviation thresholds.

---

### 4. **Risk Layer - `RiskManager.sol`**
- Continuously monitors:
  - **Health factors** of open positions
  - **Portfolio volatility & drawdown**
  - **Oracle manipulation** and price integrity
- Implements:
  - Circuit breaker mechanism
  - Emergency deleverage logic
  - Risk parameter updates by admin

---

## 🔁 System Flow

```mermaid
graph TD
  U[User deposits USDC] --> V[Vault mints shares]
  V --> S[StrategyEngine calculates allocations]
  S --> PM[PositionManager executes trades]
  PM --> RM[RiskManager validates safety]
  RM -->|Health checks| PM
  V -->|Harvests yield| PM
  V -->|Handles queued withdrawals| U
