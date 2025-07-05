## How it works - Example Scenario

###  User Deposit
    - User deposit 10,000 USDC in vault.
    - Receives vault shares representing their position.
    - USDC join the pool with other user's capital.

### Position Creation.
    - Vault has collected 1 M USDC in total.
    - strategy Engine determines the optimal pairs(ETH/USDC,BTC/USDC etc.)
    - for each pair , vault borrows the non-USDC asset.


### Delta Neutral Positioning example for ETH/USDC pair.
    - Vault allocated 500K to ETH/USDC pair.
    - Borrows 250ETH  (worth 500k at $2000/ETH).
    - Create a LP position with 250ETH and 500K USDC.
    - Net exposure : ZERO (borrowed ETH = LP position)

### Continous Rebalancing.
    - Every Hour the system checks for delta exposure.
    - If ETH prices rises to 2200/ETH
        - LP position will have less ETH and more USDC.
        - System borrows more ETH to maintain neutraility.
    - If ETH prices falls to 1800/ETH
        - LP position will have more ETH and less USDC.
        - System repays some Borrowed ETH to maintain neutraility. 
