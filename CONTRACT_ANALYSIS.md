# StarStacks Contract Analysis

## Executive Summary

StarStacks is a **perpetual futures DEX** on Stacks that uses **sBTC as collateral** and hedges only the **net directional imbalance** between longs and shorts through an internal AMM.

---

## 1. Pyth Oracle Integration

### Current Implementation (MOCK)

The current `oracle-adapter.clar` is a **simplified mock** that does NOT use the real Pyth oracle:

```clarity
;; Mock implementation - NOT production-ready
(define-public (update-btc-price (price uint) (btc-block uint))
  ;; Manual price updates - anyone can push prices
  (begin
    (var-set cached-btc-price price)
    (var-set cached-price-btc-block btc-block)
    (ok price)
  )
)
```

### What It Should Use (Production)

Based on the [Pyth documentation](https://docs.stacks.co/more-guides/price-oracles/pyth.md), production should use:

```clarity
;; Production implementation
(define-constant PYTH-ORACLE 'SP1CGXWEAMG6P6FT04W66NVGJ7PQWMDAC19R7PJ0Y.pyth-oracle-v4)
(define-constant BTC-USD-FEED-ID 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43)

(define-public (update-btc-price-from-vaa (price-feed-bytes (buff 8192)))
  ;; Verify and update from Pyth VAA
  (contract-call? PYTH-ORACLE verify-and-update-price-feeds price-feed-byts {...})
)

(define-read-only (get-btc-price)
  ;; Get price from Pyth storage
  (contract-call? PYTH-ORACLE get-price BTC-USD-FEED-ID PYTH-STORAGE)
)
```

### Key Differences

| Aspect | Current (Mock) | Production (Pyth) |
|--------|----------------|-------------------|
| Price Source | Manual push | VAA from Pyth network |
| Staleness Check | burn-block-height | Bitcoin block from VAA |
| Price Feed ID | Hardcoded constant | Real Pyth feed ID |
| Update Method | Anyone calls `update-btc-price` | Keeper relays VAA data |
| Trust Model | Centralized/manual | Decentralized guardians |

---

## 2. Dual Stacking Integration

### Current Implementation (MOCK)

The `collateral-vault.clar` implements a **reward-per-share accounting system** that expects Dual Stacking rewards, but is NOT integrated with the actual `dual-stacking-v2` contract:

```clarity
;; Mock Dual Stacking integration
(define-public (distribute-ds-rewards)
  (let (
    (vault-balance (unwrap-panic (contract-call? SBTC-TOKEN get-balance tx-sender)))
    (locked (var-get total-collateral))
    ;; Any sBTC above locked collateral = DS rewards
    (new-rewards (if (> vault-balance locked) (- vault-balance locked) u0))
  )
    ;; Increase reward-per-share
    (var-set reward-per-share (+ (var-get reward-per-share) 
      (/ (* new-rewards PRECISION) locked)))
  )
)
```

### What It Should Do (Production)

The vault should be enrolled in the actual Dual Stacking contract:

```clarity
;; Production: Enroll in dual-stacking-v2
;; Parameters:
;;   tracking-address = collateral-vault contract
;;   rewarded-address = collateral-vault contract  
;;   stacking-address = none (whitelisted = auto max boost)
```

### Key Components in Vault

| Function | Purpose |
|----------|---------|
| `deposit-collateral()` | Lock sBTC, harvest pending rewards |
| `release-collateral()` | Unlock sBTC, transfer to recipient |
| `distribute-ds-rewards()` | Call when DS cycle ends, distribute yield |
| `claim-ds-rewards()` | Trader claims accumulated stacking yield |

### Reward Flow

```
Dual Stacking Cycle Ends
         ↓
sBTC rewards → collateral-vault balance
         ↓
Anyone calls distribute-ds-rewards()
         ↓
reward-per-share increases
         ↓
Trader calls claim-ds-rewards() → receives proportional yield
```

---

## 3. Mock Contracts in Project

### sbtc-token.clar (MOCK)

```clarity
;; This is a MOCK sBTC implementation
;; Production should use: SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token

(define-fungible-token clarity-coin)  ;; NOT real sBTC

;; Only deployer can mint
(define-public (mint (amount uint) (recipient principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
    (ft-mint? clarity-coin amount recipient)
  )
)
```

**Issues:**
- Named "Clarity Coin" not sBTC
- Minting restricted to deployer
- NOT the real sBTC bridge contract
- Missing `get-balance-available` function used by contracts

### oracle-adapter.clar (PARTIAL MOCK)

- Price is manually pushed (not from Pyth)
- Uses `burn-block-height` for staleness
- Missing actual VAA verification

### pyth-oracle-v4.clar (NOT PRESENT)

The project references Pyth but doesn't include the mock contract.

---

## 4. Contract Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                         USER ACTIONS                                 │
└─────────────────────────────────────────────────────────────────────┘
                                   │
          ┌────────────────────────┼────────────────────────┐
          ▼                        ▼                        ▼
   ┌─────────────┐         ┌─────────────┐         ┌─────────────┐
   │  Open Long  │         │  Open Short │         │  Liquidate  │
   └─────────────┘         └─────────────┘         └─────────────┘
          │                        │                        │
          ▼                        ▼                        ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      PERPETUAL ENGINE                                │
│  • Validates collateral/leverage                                     │
│  • Records position                                                  │
│  • Updates OI                                                        │
│  • Triggers hedge rebalance                                          │
└─────────────────────────────────────────────────────────────────────┘
           │                         │                       │
           ▼                         ▼                       ▼
    ┌────────────┐          ┌────────────┐          ┌────────────┐
    │COLLATERAL  │          │   SBTC-DEX │          │  ORACLE    │
    │   VAULT    │          │            │          │ ADAPTER    │
    └────────────┘          └────────────┘          └────────────┘
           │                         │                       │
           │                         │                       │
           ▼                         ▼                       ▼
    ┌────────────┐          ┌────────────┐          ┌────────────┐
    │  sBTC      │          │  Constant   │          │  Pyth      │
    │  TOKEN     │          │  Product   │          │  (MOCK)   │
    │ (MOCK)     │          │    AMM     │          │            │
    └────────────┘          └────────────┘          └────────────┘
           ▲                         ▲                       ▲
           │                         │                       │
           └───────────── DUAL STACKING? ─────────────────────┘
                              (NOT INTEGRATED)
```

### Detailed Flow: Open Position

```
1. User transfers sBTC to perpetual-engine
         ↓
2. perpetual-engine.open-position()
         ↓
3. Get BTC price from oracle-adapter.get-btc-price()
         ↓
4. Calculate position size = collateral × leverage
         ↓
5. Deduct protocol fee (5 bps)
         ↓
6. Call collateral-vault.deposit-collateral()
         │ (locks sBTC, updates reward-debt)
         ▼
7. Record position in positions map
         ↓
8. Update total-long-oi or total-short-oi
         ↓
9. Call sbtc-dex.rebalance-hedge() if net OI > 0
         │ (swap delta to hedge direction)
         ▼
10. Call sbtc-dex.swap-x-to-y() or swap-y-to-x()
         │ (execute user's trade)
         ▼
11. Position opened! ✓
```

### Detailed Flow: Liquidate Position

```
1. Keeper calls liquidation-engine.liquidate(trader, position-id)
         ↓
2. liquidation-engine fetches position from perpetual-engine
         ↓
3. Get BTC price from oracle-adapter.get-btc-price()
         │ (fails if price is stale)
         ▼
4. Calculate health factor = effectiveCollateral / positionSize
         ↓
5. If health < 400 bps (4%) → proceed with liquidation
         ↓
6. Seize collateral from collateral-vault
         │ (partial or full)
         ▼
7. Split seized collateral:
         • 5% → keeper
         • 10% → insurance fund
         • remainder → trader
         ↓
8. Mark position as liquidated in perpetual-engine
         ↓
9. Update OI and trigger hedge rebalance
         ↓
10. Liquidation complete! ✓
```

---

## 5. Summary of Required Changes for Production

### Priority 1: Replace Mock Contracts

| Current | Required for Production |
|---------|------------------------|
| `sbtc-token.clar` | Use real sBTC: `SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token` |
| `oracle-adapter.clar` | Integrate real Pyth: `SP1CGXWEAMG6P6FT04W66NVGJ7PQWMDAC19R7PJ0Y.pyth-oracle-v4` |

### Priority 2: Dual Stacking Integration

| Step | Action |
|------|--------|
| 1 | Deploy collateral-vault to get contract address |
| 2 | Call `dual-stacking-v2.enroll-defi()` with vault address |
| 3 | Test reward distribution cycle |

### Priority 3: Governance Contracts

| Contract | Purpose |
|----------|---------|
| `proposal-trait.clar` | ✅ Ready |
| `extension-trait.clar` | ✅ Ready |
| `proposal-emergency-pause.clar` | ✅ Ready |
| `proposal-update-oracle-staleness.clar` | ✅ Ready |
| `proposal-update-liquidation-params.clar` | ✅ Ready |
| `proposal-upgrade-engine.clar` | ⚠️ Has placeholder address |

---

## 6. Architecture Notes

### Key Design Decisions

1. **Net OI Hedging**: Only hedges imbalance, not every trade (capital efficient)
2. **ExecutorDAO Pattern**: Core owns all extension authorization
3. **Reward-per-Share**: ERC-4626 style vault accounting for DS rewards
4. **Permissionless Liquidation**: Anyone can liquidate unhealthy positions
5. **Staleness Gate**: Liquidations require fresh prices (5 BTC blocks)

### Security Considerations

- No reentrancy (Clarity execution model)
- Immutability via extension pattern
- Integer math only (no floats)
- Post-conditions recommended for all transfers

---

## 7. Dependencies Summary

```
Contracts
    │
    ├── starstacks-core (DAO core)
    │       └── extension-trait
    │       └── proposal-trait
    │
    ├── oracle-adapter
    │       └── pyth-oracle-v4 (EXTERNAL - NOT INTEGRATED)
    │
    ├── collateral-vault
    │       └── sbtc-token (MOCK - needs real sBTC)
    │       └── dual-stacking-v2 (NOT INTEGRATED)
    │
    ├── sbtc-dex
    │       └── sbtc-token (MOCK)
    │
    ├── perpetual-engine
    │       ├── oracle-adapter
    │       ├── collateral-vault
    │       ├── sbtc-dex
    │       └── starstacks-core
    │
    ├── liquidation-engine
    │       ├── perpetual-engine
    │       ├── collateral-vault
    │       ├── oracle-adapter
    │       ├── sbtc-token (MOCK)
    │       └── starstacks-core
    │
    └── Governance Proposals
            └── starstacks-core
```
