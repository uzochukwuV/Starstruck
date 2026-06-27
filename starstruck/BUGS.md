# 🚨 StarStacks Contract Bug Report

**Date:** 2026-06-26  
**Reviewer:** OpenHands  
**Contracts Reviewed:** perpetual-engine.clar, sbtc-dex.clar, collateral-vault.clar, oracle-adapter.clar, liquidation-engine.clar

---

## 🔴 CRITICAL BUGS (P0)

### BUG #1: PnL Never Transferred to Traders

**File:** `contracts/perpetual-engine.clar`  
**Function:** `close-position()`  
**Severity:** CRITICAL - Traders lose ALL profits

#### Description
When a trader closes a position, the PnL (Profit and Loss) is calculated but **never actually transferred** to the trader. Only the original collateral is released.

#### Code Location
```clarity
;; Around line 432 in close-position()
(let (
  (pnl      (compute-pnl ...))
  (funding  (compute-funding ...))
  (eff-col  (effective-collateral (get collateral pos) pnl funding))
  (fee      (calc-fee (get size pos)))
  (payout   (if (> eff-col fee) (- eff-col fee) u0))  ;; ← CALCULATED BUT NEVER USED!
)
  ;; ❌ payout is never sent to trader!
  (try! (contract-call? .collateral-vault
    release-collateral tx-sender (get collateral pos) tx-sender))
  ;; Only returns ORIGINAL collateral, not collateral + PnL
)
```

#### Impact
- **Trader loses 100% of profits** - If BTC rises 50% on a long position, trader only gets back their collateral
- **Traders may lose more than collateral** - PnL is calculated but not applied to settlement
- **Breaks core protocol invariant** - Position closing should settle PnL

#### Recommended Fix
```clarity
;; Release original collateral + payout (PnL)
(let (
  (total-release (+ (get collateral pos) payout))
)
  (try! (contract-call? .collateral-vault
    release-collateral tx-sender total-release tx-sender))
)
```

---

### BUG #2: No Token Transfers in DEX Swaps

**File:** `contracts/sbtc-dex.clar`  
**Functions:** `swap-x-to-y()`, `swap-y-to-x()`  
**Severity:** CRITICAL - DEX is non-functional

#### Description
The DEX swap functions update internal reserves but **never actually transfer any sBTC tokens**. This makes all trading operations fictional.

#### Code Location
```clarity
;; swap-x-to-y() around line 248
(define-public (swap-x-to-y (amount-in uint) (min-out uint) (trader principal))
  (begin
    ...
    (let (
      (rx (var-get reserve-x))
      (ry (var-get reserve-y))
      (out (get-amount-out amount-in rx ry))
    )
      (asserts! (>= out min-out) ERR-SLIPPAGE-TOO-HIGH)
      (asserts! (> ry out) ERR-INSUFFICIENT-LIQUIDITY)

      (var-set reserve-x (+ rx amount-in))  ;; ❌ No token received!
      (var-set reserve-y (- ry out))        ;; ❌ No token sent!
      (ok out)                              ;; Returns fictional amount
    )
  )
)
```

#### Impact
- **All positions are fictional** - No actual sBTC is moved
- **LP fees never collected** - Swaps generate fees on paper but tokens don't move
- **Hedge rebalancing is fake** - Protocol thinks it has positions but doesn't

#### Recommended Fix
```clarity
;; In swap-x-to-y(), perpetual-engine transfers tokens to DEX first
;; Then DEX should send 'out' tokens to trader:
(try! (contract-call? SBTC-TOKEN transfer out current-contract trader none))
```

---

### BUG #3: Hedge Rebalance Doesn't Transfer Tokens

**File:** `contracts/sbtc-dex.clar`  
**Function:** `rebalance-hedge()`  
**Severity:** CRITICAL - Hedge mechanism is broken

#### Description
When the protocol rebalances its hedge (to offset net OI imbalance), only internal state is updated. **No actual sBTC is swapped or held** by the protocol.

#### Code Location
```clarity
;; rebalance-hedge() around line 280
(define-public (rebalance-hedge (new-net-long bool) (delta-size uint))
  (begin
    ...
    (if new-net-long
      ;; Protocol "shorts" sBTC by updating reserves
      (let ((out (get-amount-out delta-size rx ry)))
        (var-set reserve-x (+ rx delta-size))  ;; ❌ No actual short position
        (var-set reserve-y (- ry out))
        (var-set hedge-direction false)
        (var-set hedge-size delta-size)
        (ok out)
      )
      ;; Similar for long hedge
      ...
    )
  )
)
```

#### Impact
- **Hedge is purely accounting** - Protocol doesn't actually hold offsetting positions
- **No real risk mitigation** - If net OI is $10M long, protocol has no actual short
- **Relies entirely on LP pool** - Which is also not properly funded

#### Recommended Fix
This is a fundamental architecture issue. The hedge should either:
1. Actually hold sBTC positions (requires additional contracts)
2. Use an external venue for hedging
3. Accept that OI imbalance = unhedged risk to protocol

---

## 🟡 HIGH RISK ISSUES (P1)

### ISSUE #4: Oracle Price Cache Never Initialized

**File:** `contracts/oracle-adapter.clar`  
**Functions:** `get-btc-price()`  
**Severity:** HIGH - Protocol cannot start

#### Description
The oracle's cached BTC price starts at `u0`, which always fails the `> u0` check.

#### Code
```clarity
(define-data-var cached-btc-price uint u0)  ;; ← Starts at zero

(define-read-only (get-btc-price)
  (let ((price (var-get cached-btc-price)))
    (asserts! (> price u0) ERR-PRICE-UNAVAILABLE)  ;; ❌ Always fails!
    ...
  )
)
```

#### Impact
- **Protocol cannot open/close positions until someone calls `update-price-feeds()`**
- **No initialization or bootstrap price**
- **Relies on external keepers to update prices**

#### Recommended Fix
```clarity
;; Add initialization function or accept 0 as valid for testing
;; Or use a reasonable default price
(define-constant INITIAL-BTC-PRICE u6500000000000)  ;; ~$65,000

(define-data-var cached-btc-price uint INITIAL-BTC-PRICE)
```

---

### ISSUE #5: Double PnL Calculation Logic

**Files:** `contracts/perpetual-engine.clar`, `contracts/liquidation-engine.clar`  
**Severity:** HIGH - Potential不一致 (inconsistency)

#### Description
Both `perpetual-engine` and `liquidation-engine` have **identical copies** of:
- `compute-pnl()`
- `compute-funding()`
- `effective-collateral()`
- `health-factor()`

#### Code Duplication
```clarity
;; In perpetual-engine.clar (~line 130)
(define-private (compute-pnl (size uint) (entry-price uint) (mark-price uint) (is-long bool))
  ...
)

;; In liquidation-engine.clar (~line 40) - IDENTICAL
(define-private (compute-pnl (size uint) (entry-price uint) (mark-price uint) (is-long bool))
  ...
)
```

#### Impact
- **Maintenance burden** - Bug fixes need to be applied twice
- **Potential divergence** - Future changes might break consistency
- **Gas inefficiency** - Duplicated code

#### Recommended Fix
Extract to a shared trait or library contract.

---

### ISSUE #6: Perpetual Engine Transfers Before DEX Swap

**File:** `contracts/perpetual-engine.clar`  
**Function:** `open-position()`  
**Severity:** HIGH - Broken flow

#### Description
The `open-position()` function transfers collateral to the vault **before** the DEX swap executes. But since the DEX swap doesn't move tokens, the sBTC gets stuck in the vault.

#### Code Flow
```clarity
;; open-position() flow:
;; 1. Calculate size = collateral * leverage
;; 2. ❌ Transfer to vault: (contract-call? .collateral-vault deposit-collateral ...)
;; 3. Record position
;; 4. Update OI
;; 5. ❌ DEX swap does nothing: (contract-call? .sbtc-dex swap-x-to-y ...)
```

#### Impact
- **sBTC stuck in vault** - Can't be used for anything
- **Position exists on paper** - But no actual exposure
- **Broken from the start** - Combined with BUG #1 and #2

---

## 🟢 MEDIUM RISK ISSUES (P2)

### ISSUE #7: No Slippage Protection on Hedge Rebalance

**File:** `contracts/sbtc-dex.clar`  
**Function:** `rebalance-hedge()`

#### Description
The hedge rebalance function has **no slippage parameter** - it accepts whatever output the AMM formula produces.

#### Code
```clarity
(define-public (rebalance-hedge (new-net-long bool) (delta-size uint))
  ;; ❌ No min-out parameter!
  (let ((out (get-amount-out delta-size rx ry)))
    ;; Any amount accepted, even 0!
```

#### Impact
- **Could receive 0 tokens** if pool is imbalanced
- **No protection against sandwich attacks**
- **Protocol could pay too much for hedge**

#### Recommended Fix
```clarity
(define-public (rebalance-hedge (new-net-long bool) (delta-size uint) (min-out uint))
  ...
  (asserts! (>= out min-out) ERR-SLIPPAGE-TOO-HIGH)
```

---

### ISSUE #8: Add Liquidity Only Transfers x Tokens

**File:** `contracts/sbtc-dex.clar`  
**Function:** `add-liquidity()`

#### Description
The function takes both `amount-x` and `amount-y` but only transfers `amount-x` to the DEX.

#### Code
```clarity
(define-public (add-liquidity (amount-x uint) (amount-y uint) (min-lp uint))
  ...
  (try! (contract-call? SBTC-TOKEN transfer amount-x tx-sender current-contract none))
  ;; ❌ amount-y is never transferred!
```

#### Impact
- **Design unclear** - Is this a single-token or dual-token LP?
- **Potential accounting mismatch** - Reserves track both but only one is deposited

---

### ISSUE #9: Funding Rate Index Can Go Negative

**File:** `contracts/perpetual-engine.clar`  
**Function:** `update-funding()`

#### Description
The cumulative funding index can become negative when shorts dominate.

#### Code
```clarity
(var-set cumulative-funding-index
  (+ (var-get cumulative-funding-index) index-delta))
;; If shorts dominate, index-delta is negative
```

#### Impact
- **Potential issues with signed arithmetic** in downstream calculations
- **UI display confusion** - Negative funding rates

---

## 📊 HEDGE RISK ANALYSIS

### RISK #1: Hedge Notional Can Exceed LP Pool

**File:** `contracts/sbtc-dex.clar`

The protocol might need to hedge $100M but the LP pool only has $10M. The AMM formula will produce poor execution or fail entirely.

```clarity
(let ((out (get-amount-out delta-size rx ry)))
  (asserts! (> ry out) ERR-INSUFFICIENT-LIQUIDITY)
  ;; This will fail if delta > reserve
```

### RISK #2: LP Impermanent Loss Uncompensated

LPs bear the risk of the protocol's directional exposure without compensation beyond swap fees. When longs dominate and protocol shorts, LPs effectively hold a short position they didn't agree to.

### RISK #3: Oracle Keeper Dependency

Price updates require external keepers to relay Pyth VAAs. If no keepers operate, the protocol is frozen.

---

## ✅ WORKING CORRECTLY

- **Authorization pattern** - `starstacks-core` extension model is sound
- **Oracle staleness checks** - Good protection against stale prices
- **Oracle price bounds** - $1K - $10M sanity checks are reasonable
- **Dual Stacking integration** - Reward distribution logic is correct
- **Liquidation keeper incentives** - 5% reward is reasonable
- **Insurance fund** - 10% allocation for bad debt is prudent
- **Health factor calculation** - Correctly determines liquidatability

---

## 📋 PRIORITY FIXES SUMMARY

| Priority | Bug # | Issue | Est. Effort |
|----------|-------|-------|-------------|
| 🔴 P0 | #1 | PnL not transferred | Medium |
| 🔴 P0 | #2 | No token transfers in swaps | Medium |
| 🔴 P0 | #3 | Hedge doesn't move tokens | High |
| 🟡 P1 | #4 | Oracle not initialized | Low |
| 🟡 P1 | #5 | Duplicate PnL code | Medium |
| 🟡 P1 | #6 | Transfer before swap | High (design) |
| 🟢 P2 | #7 | No slippage on hedge | Low |
| 🟢 P2 | #8 | LP only x token | Medium |

---

## 🔧 RECOMMENDED NEXT STEPS

1. **Immediate:** Fix BUG #1 (PnL transfer) - Users are losing money
2. **Immediate:** Fix BUG #2 (DEX token transfers) - Core functionality broken
3. **High:** Address architecture issues (#3, #6) - Fundamental redesign needed
4. **Medium:** Extract shared PnL logic (#5) - Code quality
5. **Low:** Add slippage protection (#7) - Security hardening

---

*Generated by OpenHands on 2026-06-26*
