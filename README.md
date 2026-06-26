# StarStacks — Perpetual Futures DEX on Stacks

StarStacks is a perpetual futures DEX built on Stacks, using **sBTC as the settlement and collateral asset** and **Pyth Network** (`pyth-oracle-v4`) for on-chain BTC/USD pricing.

It hedges only the **net directional imbalance** between longs and shorts through its internal DEX — not every individual trade — making it highly capital-efficient.

---

## Architecture Overview

```
starstacks-core.clar              ← ExecutorDAO core; owns all extension auth
├── governance/
│   ├── proposal-trait.clar       ← Trait all proposals must implement
│   ├── extension-trait.clar      ← Trait all extensions must implement
│   ├── proposal-update-oracle-staleness.clar
│   ├── proposal-update-liquidation-params.clar
│   ├── proposal-emergency-pause.clar
│   └── proposal-upgrade-engine.clar
├── oracle-adapter.clar           ← Pyth wrapper + staleness gate
├── collateral-vault.clar         ← sBTC custody + Dual Stacking rewards
├── sbtc-dex.clar                 ← Constant-product AMM + hedge rebalancer
├── perpetual-engine.clar         ← Positions, OI tracker, funding rate
└── liquidation-engine.clar       ← Permissionless liquidation + keeper rewards
```

---

## Contract Responsibilities

### `starstacks-core.clar`
- Single source of truth for authorization.
- Maintains a registry of active extension contracts.
- Executes governance proposals (proposals are smart contracts).
- Bootstrap via `initialize()` — called once after all extensions are deployed.

### `oracle-adapter.clar`
- Wraps Pyth `pyth-oracle-v4` BTC/USD feed.
- All prices returned as fixed-point integers scaled by `10^8`.
  - e.g. `u6500000000000` = $65,000.00
- `get-btc-price` — safe read, rejects prices older than `MAX-PRICE-AGE-BLOCKS` (5 Bitcoin blocks, ~50 min).
- `get-btc-price-unsafe` — for UI reads, no staleness gate.
- `update-btc-price` — permissionless feed update; keepers call this continuously.

### `collateral-vault.clar`
- Custodies all trader sBTC collateral.
- **Dual Stacking integration**: the vault contract is enrolled in `dual-stacking-v2` as a DeFi protocol via `enroll-defi`. Its sBTC balance is snapshotted each cycle.
- DS rewards land in this contract → anyone calls `distribute-ds-rewards()` → reward-per-share increases → traders call `claim-ds-rewards()` to collect.
- Traders earn sBTC stacking yield on idle collateral while positions are live.

### `sbtc-dex.clar`
- Constant-product AMM (`x * y = k`) for internal sBTC ↔ synthetic-BTC swaps.
- Swap fee: **10 bps (0.10%)** — accrues to LPs.
- `add-liquidity` / `remove-liquidity` — LP provision with slippage guards.
- `swap-x-to-y` / `swap-y-to-x` — called by `perpetual-engine` when users open positions.
- `rebalance-hedge` — called by `perpetual-engine` after every OI change; swaps only the **delta** in net imbalance, not the full OI.

### `perpetual-engine.clar`
- Opens and closes long/short BTC positions.
- **Net OI tracking**: maintains `total-long-oi` and `total-short-oi`.
- After every position change, computes `net_delta = |long_oi - short_oi|` and calls `sbtc-dex.rebalance-hedge`.
- **Funding rate**: permissionless `update-funding()` callable every 144 Bitcoin blocks (~1 day). Rate flows from the dominant side to the minority side proportional to OI imbalance.
- Protocol fee: **5 bps** on position open and close.

### `liquidation-engine.clar`
- Permissionless `liquidate(trader, position-id)`.
- Checks position health using the safe oracle price (rejects stale prices).
- A position is liquidatable when health factor < **400 bps (4%)**.
- Seized collateral split:
  - **5%** → keeper (liquidation bot reward)
  - **10%** → insurance fund
  - Remainder → trader (if any)
- `liquidate-batch` — liquidate up to 10 positions per tx (gas-efficient for keepers).
- `is-liquidatable(trader, id, mark-price)` — read-only preview for keepers.

---

## Key Design Properties

| Property | Value |
|---|---|
| Settlement asset | sBTC |
| Oracle | Pyth `pyth-oracle-v4`, BTC/USD |
| Max leverage | 25x |
| Liquidation threshold | 4% collateral ratio |
| Keeper reward | 5% of seized collateral |
| Protocol fee | 5 bps on open/close |
| Swap fee | 10 bps (to LPs) |
| Funding interval | 144 Bitcoin blocks (~1 day) |
| Price staleness limit | 5 Bitcoin blocks (~50 min) |

---

## Dual Stacking Integration

The `collateral-vault` is enrolled in Stacks' `dual-stacking-v2` contract as a DeFi protocol:

```
tracking-address  = collateral-vault
rewarded-address  = collateral-vault
stacking-address  = none (whitelisted → auto 10x max boost)
```

**Flow:**
1. Dual Stacking snapshots vault's sBTC balance each cycle.
2. DS rewards (sBTC) are distributed to the vault address.
3. Anyone calls `collateral-vault.distribute-ds-rewards()`.
4. Reward-per-share increases proportionally.
5. Traders call `collateral-vault.claim-ds-rewards()` to collect.

**Result:** Every trader who posts collateral passively earns sBTC stacking yield while their position is open — no extra action required.

---

## Deployment Order

```bash
# 1. Traits (no dependencies)
clarinet deploy governance/proposal-trait.clar
clarinet deploy governance/extension-trait.clar

# 2. Core (uses traits)
clarinet deploy starstacks-core.clar

# 3. Extensions (all call starstacks-core)
clarinet deploy oracle-adapter.clar
clarinet deploy collateral-vault.clar
clarinet deploy sbtc-dex.clar
clarinet deploy perpetual-engine.clar
clarinet deploy liquidation-engine.clar

# 4. Bootstrap: register all extensions in core
# (replace addresses with actual deployed principals)
clarinet call starstacks-core initialize \
  perpetual-engine sbtc-dex oracle-adapter liquidation-engine collateral-vault

# 5. Enroll collateral-vault in Dual Stacking
clarinet call dual-stacking-v2 enroll-defi \
  collateral-vault collateral-vault collateral-vault none
```

---

## Governance Lifecycle

```
Deploy proposal contract
         ↓
Extension calls: (contract-call? .starstacks-core execute .new-proposal tx-sender)
         ↓
Core validates: is contract-caller an extension? Has proposal already run?
         ↓
Core calls: (as-contract (contract-call? .new-proposal execute sender))
         ↓
Proposal logic runs with core-level authority
```

Proposals can: add/remove extensions, change oracle parameters, adjust liquidation fees, pause any component, or migrate to new contract versions.

---

## Security Considerations

- **No reentrancy**: Clarity's execution model prevents reentrancy at the language level.
- **Immutability**: All contracts are immutable. Upgrades happen via new extension contracts registered through governance.
- **Staleness gate**: Liquidations REQUIRE fresh oracle prices (≤5 Bitcoin blocks old). Stale prices cause `ERR-PRICE-STALE`.
- **Post-conditions**: Callers should attach STX/sBTC post-conditions to prevent unexpected transfers.
- **Integer arithmetic**: All math uses fixed-point integers. No floats. Division truncates — this is accounted for in fee and PnL calculations.
- **Fuzz testing**: Use Rendezvous to hammer liquidation and funding math with random inputs before mainnet.
- **Audit**: All contracts should be audited before mainnet deployment. See [Stacks auditors](https://www.stacks.co/explore/ecosystem?category=Auditors).
