# Reave — ReactiveVM Orchestrated Leverage Looping

**Overview**
- Event-driven Reactive Contract orchestrates Aave V3 supply/borrow and Uniswap V3 swaps to reach a target LTV, with unwind, liquidation, and TVL loop support.
- Lasna (Reactive testnet): Orchestration lives inside ReactVM. It consumes events and emits callbacks to the destination chain.
- Sepolia (destination): Executes Aave/Uniswap operations. All core finance steps run on the chain where the protocols exist.

**Problem**
- Leveraged looping requires multi-step, stateful coordination across protocols: supply collateral, borrow against it, swap debt to collateral, repeat, then safely unwind or liquidate when needed.
- Traditional scripts or bots are brittle across chains and fail under reorgs or event race conditions.
- Developers need deterministic, event-driven orchestration that can react to on-chain signals and trigger transactions with guardrails.

**Why Reactive Contracts**
- ReactiveVM receives EVM events and executes contract logic in response, maintaining per-VM state and ordering.
- Contracts can emit cross-chain callbacks that instruct destination chains to perform actions where liquidity and protocols exist.
- This decouples orchestration from execution: safer, auditable flows with built-in event routing.

**Contracts**
- `src/LeverageLooper.sol` — unified contract with:
  - `optInFromUser`, `optInAndLoop`, `unwindToLtv`, `loopToTvl`, `liquidateLoop`, `maybeArb`.
  - `react(IReactive.LogRecord)` routes `PriceUpdate`, `HealthBelow`, `UserOptIn`, `Unwind`, `LoopToTVL`.
- In ReactVM mode, `react(...)` emits `Callback(chainId, destLooper, gasLimit, calldata)` to call the destination contract.

**Architecture**
- ReactiveVM (Lasna):
  - Subscribes to price and health events via RN tooling.
  - Runs `react(...)`, checks thresholds and health, and emits `Callback` payloads.
  - Keeps local state: `lastPrice`, `minDiffBps`, `arbAmount`, `baselineNetBase`.
- Destination (Sepolia):
  - Receives transactions to execute Aave `supply/borrow/repay/withdraw/liquidationCall` and Uniswap V3 swaps.
  - Functions invoked: `optInFromUser`, `unwindToLtv`, `loopToTvl`, `liquidateLoop`, `maybeArb`.

**Core Flows**
- Opt-in loop: user approves collateral → RC loops supply/borrow/swap to target LTV with health factor guard.
- Unwind: swaps collateral to debt and repays until target LTV is reached.
- Loop to TVL: arbitrage first if profitable, then accumulate collateral to reach target TVL; optionally one-step liquidation.
- Liquidation: when `HealthBelow`, buy debt if needed and call `liquidationCall` with per-step cap.
- Arbitrage: compare per-chain prices; when diff ≥ `minDiffBps`, swap `debt→collateral` on low-price chain, `collateral→debt` on high-price chain.

**Addresses (Sepolia examples)**
- `POOL_ADDR=0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951`
- `ORACLE_ADDR=0x2da88497588bf89281816106C7259e31AF45a663`
- `ROUTER_ADDR=0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E`
- `COLLATERAL_ADDR=WETH=0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c`
- `DEBT_ADDR=USDC=0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8`

**Prereqs**
- Foundry (`forge`, `cast`), funded keys on Sepolia and Lasna.
- Uniswap V3 pools available for the chosen pair/fee.
- Aave V3 addresses provider yields valid `Pool` and `PriceOracle`.

**Trade-offs**
- Orchestration in Lasna improves determinism and reactivity; execution remains on Sepolia for protocol access.
- Cross-chain intents avoid direct cross-chain calls from ReactVM; RN handles routing and delivery.
- Universal Router can replace SwapRouter later, at the cost of interface refactoring.

**Env**
- Configure `Reactive/.env.lasna`:
  - `REACTIVE_RPC=https://lasna-rpc.rnk.dev/`
  - `REACTIVE_PRIVATE_KEY=0x<LASNA_KEY>`
  - Sepolia destination addresses (`POOL_ADDR`, `ORACLE_ADDR`, `ROUTER_ADDR`, `COLLATERAL_ADDR`, `DEBT_ADDR`).
  - `HAS_DEST=true`, `DEST_CHAIN_ID=11155111`, `DEST_LOOPER_ADDR=0x<SEPOLIA_DEST_ADDR>`, `CALLBACK_GAS_LIMIT=2000000`.
  - Optional: `HAS_PRICE_SUB`, `HAS_HEALTH_SUB` for RN-side subscription registration.

**Faucet (Lasna)**
- Get REACT via Sepolia faucet:
  - `export SEPOLIA_RPC=https://sepolia.drpc.org`
  - `export SEPOLIA_PRIVATE_KEY=0x<SEPOLIA_KEY>`
  - `cast send 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434 --rpc-url $SEPOLIA_RPC --private-key $SEPOLIA_PRIVATE_KEY "request(address)" 0x<YOUR_EOA> --value 0.1ether`
  - Check: `cast balance 0x<YOUR_EOA> --rpc-url https://lasna-rpc.rnk.dev/`

**Deploy**
- Destination (Sepolia):
  - `forge script script/DeployLeverageLooper.s.sol:DeployLeverageLooper --rpc-url https://sepolia.drpc.org --private-key 0x<SEPOLIA_KEY> --broadcast`
  - Save the deployed address → set `DEST_LOOPER_ADDR` in env.
- ReactiveVM (Lasna):
  - `forge script script/DeployLeverageLooper.s.sol:DeployLeverageLooper --rpc-url https://lasna-rpc.rnk.dev/ --private-key 0x<LASNA_KEY> --broadcast`
  - RN tooling should register subscriptions to feed events to the Lasna RC.

**Deployed (Sepolia)**
- Contract: `0xb0a4c3b9CB97D0A1171F48a0edfE51580d2d545b`
- Etherscan: `https://sepolia.etherscan.io/address/0xb0a4c3b9CB97D0A1171F48a0edfE51580d2d545b`
- Tx hashes:
  - Config tx 1: `0x137c0511c160aa92b167a0381d97a14ae54e77bb6cccbe8be091954dea5a0fdb`
  - Config tx 2: `0x19e97d409caf6b37c2cd78a408a477fa05371026af667d6bc335da9611cd6f03`
  - Create tx: `0x1d34f7c64429ec48c139f22b6451f6b9394e2d6533960f759140c2fffd814ede`

**RPC Endpoints (public)**
- Sepolia: `https://rpc.sepolia.org` or `https://ethereum-sepolia-rpc.publicnode.com`
- Linea Sepolia (Lasna): `https://rpc.sepolia.linea.build` or `https://lasna-rpc.rnk.dev/`
- Base Sepolia: `https://sepolia.base.org`
- Optimism Sepolia: `https://sepolia.optimism.io`
- Arbitrum Sepolia: `https://sepolia-rollup.arbitrum.io/rpc`
- Polygon Amoy: `https://rpc-amoy.polygon.technology`
- Scroll Sepolia: `https://sepolia-rpc.scroll.io`
**Workflow (Step-by-step)**
- Step 1: Approve collateral on Sepolia
  - Tx: `approve(DEST_LOOPER_ADDR, amount)` from user
- Step 2: Emit `UserOptIn` event on origin
  - Origin Tx: `UserOptIn(...)
  - Reactive Tx: Lasna RC `react(...)` + `Callback`
  - Destination Tx: Sepolia `optInFromUser(...)` executes supply/borrow/swap loop
- Step 3: Emit `PriceUpdate` events
  - Reactive Tx: Lasna RC `react(...)` + `Callback`
  - Destination Tx: Sepolia `maybeArb()` swaps across configured chains
- Step 4: Emit `HealthBelow` when target account unhealthy
  - Reactive Tx: Lasna RC `react(...)` + `Callback`
  - Destination Tx: Sepolia `liquidateLoop(...)`
- Step 5: Trigger unwind or TVL loop
  - Reactive Tx: Lasna RC `react(...)` + `Callback`
  - Destination Tx: Sepolia `unwindToLtv(...)` / `loopToTvl(...)`
  
Record all transaction hashes at each step (origin, reactive, destination) for submission.

**Run**
- Approvals on Sepolia:
  - `cast send $COLLATERAL_ADDR --rpc-url https://sepolia.drpc.org --private-key 0x<USER_KEY> "approve(address,uint256)" $DEST_LOOPER_ADDR 1000000000000000000`
- Trigger `UserOptIn` via your controller/UI emitting the event; RN routes to Lasna RC; Lasna emits callback to Sepolia:
  - Destination tx executes: `optInFromUser(user, amount, targetLtv, ...)`.
- `PriceUpdate` events routed → Lasna RC emits callback → Sepolia executes `maybeArb()`.
- `HealthBelow` events routed → Lasna RC emits callback → Sepolia executes `liquidateLoop(target, ...)`.
- Unwind/TVL loop triggers similarly.

**Testing**
- `forge build`
- `forge test`
- Core tests:
  - Cross-chain arbitrage: `Reactive/test/CrossChainArbReactive.t.sol:56`.
  - Loop and unwind: `Reactive/test/LeverageLooper.t.sol`.

**Security & Edge Cases**
- Slippage bounds via `amountOutMinimum`.
- Health factor guard to halt loops.
- Max iterations per loop.
- Borrow caps and available borrow checks.
- Price oracle decimals handled; base/token conversions via helpers.
- Callback gas limit configurable to avoid underpricing.

**Submission Checklist**
- Reactive Lasna RC address and Sepolia destination address.
- Step-by-step workflow with transaction hashes:
  - Origin events (emit `UserOptIn`, `PriceUpdate`, `HealthBelow`).
  - Reactive callbacks (Lasna `Callback` emits).
  - Destination transactions (Sepolia Aave/Uniswap calls).
- Short video (3–5 min) explaining design, threat model, and trade-offs.
- Public GitHub repo with deploy scripts and instructions.

**Threat Model (Brief)**
- Market risk: sudden price moves during swaps → slippage bounds.
- Liquidity risk: insufficient pool liquidity → max iterations and bailouts.
- Parameter risk: misconfigured LTV → bounded by `maxIterations` and health checks.
- Callback delivery: RN routing; include adequate gas limit; monitor debt via `coverDebt()` if supported.

**Notes**
- Per ReactVM docs, subscriptions should be registered from RN tooling; calling `subscribe()` inside RVM has no effect.
- If Universal Router is preferred later, swap logic can be refactored; current build uses Uniswap V3 `SwapRouter`.
