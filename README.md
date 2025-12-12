# Reactive  bounty

DETAILS
Build a simple leveraged “looping” strategy on top of an existing lending protocol using Reactive Smart Contracts. When a user opts in, the Reactive contract should automatically perform several supply/borrow/swap steps to reach a target leverage, and optionally allow a safe unwind.

The deadline is December, 14, 11:59 PM UTC.

Origin chain behavior
User supplies an asset (e.g. WETH or an ERC-20 token) into a lending protocol.
The Reactive contract:Supplies the asset as collateral.Borrows against it (e.g. a stablecoin or the same asset).Swaps the borrowed asset into more collateral.Repeats the loop a few times until a configured target LTV / leverage is reached.
All orchestration (multi-step, possibly multi-chain) is done by Reactive Contracts.
Edge cases
Handle obvious failure modes:

Not enough liquidity.
Slippage on swaps (use a max slippage parameter).
Borrow cap / collateral factor limits.



## Solution
**Price**
1 eth (mainnet) = 2800
1 eth (zksyncEra) = 3000


- flashloan (Aave) or collateral () - go to eth mainnet borrow 1 eth . acc(2800)
- go to zksyncEra sell eth forn usdc (3000) making (200) without mev calculated 
- go back to eth maninnet swap usdc to eth (getting more eth) 
- go back to zksyncEra sell eth for usdc (with mev in mind)
- making 400 or more off my initail price



- swap 


- collateral 

but how ill i know which asset to borrow against?? 
goota see prices on other chains 

1. what if instead of borrowing i liqudate??? !