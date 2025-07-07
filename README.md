# Pooled Delta-Neutral Vault

## WTF is this?

Delta-Neutral Vault is basically a yield farming strategy that doesn't care if ETH goes to $10k or $100. I built this because I got tired of getting rekt by price movements while trying to farm yield and also I wanted to explore the Euler protocol.

The idea is stupid simple: 
- Take user's USDC
- Use it as collateral on Euler
- Borrow the same $ value in ETH/BTC
- Chill and collect the APY difference

No LP, no IL, no price risk. Just pure interest rate arbitrage.

## How this thing actually works

### The Magic Formula
```
Profit = USDC_lending_APY - ETH_borrowing_APY
```

That's it. If USDC earns 5% and ETH costs 3% to borrow, you make 2%. Market dumps 50%? You still make 2%. Market pumps 200%? Still 2%. 

### Real Example
Say Alice deposits 100k USDC:
1. We dump it into Euler as collateral
2. Borrow $100k worth of ETH (say 50 ETH @ $2k)
3. Now we have: +100k USDC, +50 ETH, -50 ETH debt
4. ETH moons to $4k? We still owe 50 ETH, not $200k
5. ETH dumps to $1k? We still owe 50 ETH, not $50k

Net exposure = 0. Alice sleeps well.

## Architecture (the boring stuff)

```
Users
  ↓
DeltaNeutralVault.sol (ERC4626 - handles deposits/withdrawals)
  ↓
PositionManager.sol (does the actual work)
  ├── Deposits to Euler
  ├── Manages borrows
  └── Tracks everything
  
Supporting cast:
- StrategyEngine.sol (big brain calculations)
- RiskManager.sol (makes sure we don't blow up)
- AccessRegistry.sol (who can do what)
```

## Contracts Breakdown

### DeltaNeutralVault.sol
The main entry point. It's an ERC4626 vault (because standards are nice).

Key stuff:
- `deposit()` - Give us your USDC
- `requestWithdrawal()` - "I want out" (24hr delay tho)
- `processWithdrawals()` - Actually get your money back
- `harvest()` - Collect fees (yes, we take a cut)

**Note**: We have a 24hr withdrawal delay. Why? So we don't get rekt by flash loan exploits.

### PositionManager.sol
This is where the magic happens. Manages all the Euler interactions.

```solidity
openPosition(address pool, uint256 usdcAmount)
// "pool" is just an identifier, not an actual pool
// We're NOT providing liquidity anywhere
```

Important: We deposit collateral FIRST, then borrow. 

### StrategyEngine.sol
Calculates how much to allocate where. Currently supports ETH and BTC positions.

Rebalancing logic:
- Check delta exposure every hour
- If off by >5%, rebalance
- Don't rebalance if gas is insane

### RiskManager.sol
The paranoid contract. Checks:
- Health factors (don't get liquidated)
- Position concentration (max 30% per asset)  
- Circuit breakers (pause if shit hits the fan)
- Max leverage (3x, we're not degens)

### AccessRegistry.sol
OpenZeppelin AccessControl (Roles):
- `ADMIN` - Can change fees, add new strategies
- `STRATEGIST` - Opens/closes positions
- `KEEPER` - Calls harvest, routine stuff
- `GUARDIAN` - Emergency pause button

## How to Use This Thing

### For Users
```solidity
// Deposit
USDC.approve(vault, amount);
vault.deposit(amount, myAddress);

// Withdraw (2 steps because 24hr delay)
vault.requestWithdrawal(shares);
// wait 24 hours...
vault.processWithdrawals();
```

### For Strategists
```solidity
// Open a position
positionManager.openPosition(ethIdentifier, 100_000e18);

// Rebalance when needed
vault.rebalance();
```

## The Actual Flow

1. **User deposits USDC** → Vault mints shares
2. **Vault sends USDC to PositionManager**
3. **PM deposits USDC to Euler** as collateral
4. **PM borrows ETH/BTC** from Euler
5. **We hold both** (no LP pools!)
6. **Time passes** → Collect interest differential
7. **User withdraws** → Unwind positions if needed

## Gotchas & Important Shit

### Why No Liquidity Provision?
Originally tried to LP on EulerSwap. Turns out EulerSwap isn't a real AMM - it's just a swap router. Spent 2 days debugging that. Don't be like me.

### The Decimal Drama
Euler uses 18 decimals for everything. USDC normally has 6. Our tests use 18 for USDC too because lazy. In prod, handle this properly or get rekt.

### EVC is Weird
Euler Vault Connector (EVC) needs specific call patterns. You can't just call `borrow()` directly. Everything goes through `evc.call()`. RTFM on Euler docs.

### Collateral First!
```solidity
// This works
deposit(USDC);
enableCollateral();
borrow(ETH);

// This gives E_AccountLiquidity error
borrow(ETH);  // No collateral = no bueno
deposit(USDC);
```

## Risk Stuff (CYA Section)

- **Interest Rate Risk**: If borrow APY > lending APY, we lose money
- **Liquidation Risk**: If collateral factor changes, positions might get liquidated
- **Smart Contract Risk**: Bugs happen. Code is audited but still...
- **Euler Risk**: We're built on Euler. If Euler dies, we die

## Local Development

```bash
# Clone
git clone <repo>

# Install
forge install

# Test
forge test -vvv


## Future Ideas

- [ ] Add more assets (stETH? wBTC?)
- [ ] Auto-compound yields
- [ ] Liquidation protection insurance
- [ ] Cross-chain positions (ambitious)
- [ ] Options strategies on top (galaxy brain)

