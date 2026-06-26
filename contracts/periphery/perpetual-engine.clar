;; perpetual-engine.clar
;; ─────────────────────────────────────────────────────────────────────────────
;; StarStacks Perpetual Engine
;;
;; Central logic for the perpetual futures protocol.
;; Handles:
;;   1. Opening long and short BTC positions (backed by sBTC collateral).
;;   2. Closing positions (full or partial) with PnL settlement in sBTC.
;;   3. Net open-interest (OI) tracking — computes the directional imbalance
;;      between aggregate longs and shorts, then triggers hedge rebalancing.
;;   4. Funding rate accumulation — periodic payments from the dominant side
;;      (majority longs pay shorts, or vice versa) to keep the market balanced.
;;   5. Delegating liquidation to liquidation-engine.clar.
;;
;; Key invariant:
;;   net_oi = total_long_oi - total_short_oi
;;   When net_oi > 0  → more longs  → DEX holds a short hedge of size |net_oi|
;;   When net_oi < 0  → more shorts → DEX holds a long hedge  of size |net_oi|
;;
;; All values are in sBTC satoshis (1 sat = 0.00000001 sBTC).
;; Prices come from oracle-adapter.clar (Pyth BTC/USD, scaled by 10^8).
;; ─────────────────────────────────────────────────────────────────────────────

;; ── Error codes ───────────────────────────────────────────────────────────────
(define-constant ERR-UNAUTHORIZED          (err u5000))
(define-constant ERR-ZERO-AMOUNT           (err u5001))
(define-constant ERR-POSITION-NOT-FOUND    (err u5002))
(define-constant ERR-INSUFFICIENT-COLLATERAL (err u5003))
(define-constant ERR-LEVERAGE-TOO-HIGH     (err u5004))
(define-constant ERR-ENGINE-PAUSED         (err u5005))
(define-constant ERR-ALREADY-LIQUIDATED    (err u5006))
(define-constant ERR-NOT-LIQUIDATABLE      (err u5007))
(define-constant ERR-OVERFLOW              (err u5008))
(define-constant ERR-INVALID-SIDE         (err u5009))
(define-constant ERR-FUNDING-TOO-EARLY    (err u5010))

;; ── Constants ─────────────────────────────────────────────────────────────────

;; Oracle price scale (10^8).
(define-constant PRICE-SCALE u100000000)

;; Maximum leverage (25x).
(define-constant MAX-LEVERAGE u25)

;; Minimum collateral ratio (4%) — positions below this are liquidatable.
;; Stored as basis points: 400 = 4.00%
(define-constant MIN-COLLATERAL-RATIO-BPS u400)

;; Funding rate: 0.01% per Bitcoin block on the dominant side.
;; Stored as basis points: 1 = 0.01%
(define-constant FUNDING-RATE-PER-BLOCK-BPS u1)

;; Minimum Bitcoin blocks between global funding updates.
(define-constant FUNDING-INTERVAL-BLOCKS u144) ;; ~1 day

;; Protocol fee on position open/close: 5 bps = 0.05%
(define-constant PROTOCOL-FEE-BPS u5)

;; ── State ─────────────────────────────────────────────────────────────────────

;; Global open interest.
(define-data-var total-long-oi   uint u0)   ;; aggregate long positions (sats)
(define-data-var total-short-oi  uint u0)   ;; aggregate short positions (sats)

;; Position ID counter (monotonically increasing).
(define-data-var next-position-id uint u1)

;; Cumulative funding index.  Increases when longs dominate (longs pay shorts),
;; decreases when shorts dominate.  Scaled by PRICE-SCALE.
(define-data-var cumulative-funding-index  int 0)
(define-data-var last-funding-block        uint u0)

;; Accumulated protocol fees (in sBTC sats) for governance to distribute.
(define-data-var protocol-fee-pool uint u0)

;; Pause flag.
(define-data-var engine-paused bool false)

;; ── Positions map ─────────────────────────────────────────────────────────────
;;
;; Key:   { trader: principal, id: uint }
;; Value: position record
(define-map positions
  { trader: principal, id: uint }
  {
    size:              uint,   ;; notional position size in sBTC sats
    collateral:        uint,   ;; sBTC sats posted as collateral
    entry-price:       uint,   ;; BTC/USD price at open, scaled by 10^8
    is-long:           bool,   ;; true = long, false = short
    funding-index-at-open: int, ;; snapshot of cumulative-funding-index at open
    opened-at-block:   uint,   ;; burn-block-height at open
    is-liquidated:     bool    ;; set true by liquidation-engine
  }
)

;; Trader → list of open position IDs (for enumeration).
(define-map trader-positions principal (list 50 uint))

;; ── Authorization ─────────────────────────────────────────────────────────────

(define-private (only-extension)
  (ok (asserts!
        (contract-call? .starstacks-core is-extension contract-caller)
        ERR-UNAUTHORIZED))
)

(define-private (not-paused)
  (ok (asserts! (not (var-get engine-paused)) ERR-ENGINE-PAUSED))
)

;; ── Internal helpers ──────────────────────────────────────────────────────────

;; Calculate protocol fee (in sats).
(define-private (calc-fee (amount uint))
  (/ (* amount PROTOCOL-FEE-BPS) u10000)
)

;; Compute unrealised PnL for a position given the current mark price.
;; Returns a signed integer (positive = profit, negative = loss).
(define-private (compute-pnl
    (size uint)
    (entry-price uint)
    (mark-price  uint)
    (is-long     bool))
  (let (
    (price-delta
      (if is-long
        (- (to-int mark-price) (to-int entry-price))
        (- (to-int entry-price) (to-int mark-price))
      )
    )
  )
    ;; PnL = size * price_delta / entry_price
    ;; Result in sBTC sats.
    (/ (* (to-int size) price-delta) (to-int entry-price))
  )
)

;; Compute accrued funding for a position since it was opened.
;; Longs pay when cumulative index rose (more longs dominant).
;; Shorts receive when index rose.
(define-private (compute-funding
    (size uint)
    (is-long bool)
    (funding-at-open int))
  (let (
    (current-index (var-get cumulative-funding-index))
    (delta (- current-index funding-at-open))
    ;; Funding amount = size * |delta| / PRICE_SCALE
    (funding-amount (/ (* (to-int size) (if (< delta 0) (* delta -1) delta)) (to-int PRICE-SCALE)))
  )
    ;; Longs pay when delta > 0 (index rose), receive when delta < 0.
    ;; Shorts are the mirror.
    (if is-long
      (* funding-amount -1)  ;; longs pay → negative for them
      funding-amount         ;; shorts receive
    )
  )
)

;; Net collateral remaining after PnL and funding.
(define-private (effective-collateral
    (collateral uint)
    (pnl int)
    (funding int))
  (let ((net (+ (to-int collateral) pnl funding)))
    (if (< net 0) 0 (to-uint net))
  )
)

;; Health factor in basis points: (effective_collateral / size) * 10000.
;; Position is healthy if >= MIN-COLLATERAL-RATIO-BPS.
(define-private (health-factor
    (eff-collateral uint)
    (size uint))
  (if (is-eq size u0)
    u10000  ;; no size → healthy by default
    (/ (* eff-collateral u10000) size)
  )
)

;; ── Funding rate update (permissionless, rate-limited) ────────────────────────

;; Anyone can trigger a funding update after FUNDING-INTERVAL-BLOCKS have passed.
;; Funding flows from dominant side (majority OI) to minority side.
;;
;; The cumulative index increases when longs dominate (longs pay),
;; decreases when shorts dominate (shorts pay).
(define-public (update-funding)
  (begin
    (try! (not-paused))
    (let (
      (blocks-elapsed (- burn-block-height (var-get last-funding-block)))
    )
      (asserts! (>= blocks-elapsed FUNDING-INTERVAL-BLOCKS) ERR-FUNDING-TOO-EARLY)

      (let (
        (long-oi  (var-get total-long-oi))
        (short-oi (var-get total-short-oi))
        (total-oi (+ long-oi short-oi))
      )
        (if (is-eq total-oi u0)
          ;; No open interest — nothing to do.
          (begin
            (var-set last-funding-block burn-block-height)
            (ok u0)
          )
          (begin
            ;; Funding rate proportional to imbalance * blocks elapsed.
            ;; index_delta = (long_oi - short_oi) / total_oi * FUNDING_RATE * blocks
            (let (
              (imbalance (- (to-int long-oi) (to-int short-oi)))
              (rate-per-block (to-int FUNDING-RATE-PER-BLOCK-BPS))
              (scale (to-int u10000))
              (blocks (to-int blocks-elapsed))
              (index-delta
                (/ (* (* imbalance rate-per-block) blocks)
                   (* (to-int total-oi) scale))
              )
            )
              (var-set cumulative-funding-index
                (+ (var-get cumulative-funding-index) index-delta))
              (var-set last-funding-block burn-block-height)

              (print {
                event:            "funding-updated",
                index-delta:      index-delta,
                cumulative-index: (var-get cumulative-funding-index),
                long-oi:          long-oi,
                short-oi:         short-oi,
                blocks-elapsed:   blocks-elapsed
              })
              (ok (to-uint (if (< index-delta 0) (* index-delta -1) index-delta)))
            )
          )
        )
      )
    )
  )
)

;; ── Open position ─────────────────────────────────────────────────────────────

;; Open a new leveraged position.
;;
;; Parameters:
;;   collateral — sBTC sats the trader is posting (already transferred to vault)
;;   leverage   — multiplier 1–25 (integer)
;;   is-long    — true = long BTC, false = short BTC
;;   min-out    — minimum DEX output for the swap (slippage guard)
;;
;; Flow:
;;   1. Validate inputs and price freshness.
;;   2. Compute notional size = collateral * leverage.
;;   3. Deduct protocol fee from collateral.
;;   4. Record position.
;;   5. Update aggregate OI and trigger hedge rebalance.
;;   6. Execute user-facing swap in internal DEX.
(define-public (open-position
    (collateral uint)
    (leverage   uint)
    (is-long    bool)
    (min-out    uint))
  (begin
    (try! (not-paused))
    (asserts! (> collateral u0)  ERR-ZERO-AMOUNT)
    (asserts! (> leverage u0)    ERR-LEVERAGE-TOO-HIGH)
    (asserts! (<= leverage MAX-LEVERAGE) ERR-LEVERAGE-TOO-HIGH)

    ;; 1. Get fresh price (will error if stale).
    (let ((mark-price (try! (contract-call? .oracle-adapter get-btc-price))))

      ;; 2. Compute notional size.
      (let (
        (size        (* collateral leverage))
        (fee         (calc-fee size))
        (net-collat  (if (> collateral fee) (- collateral fee) u0))
        (position-id (var-get next-position-id))
      )
        (asserts! (> net-collat u0) ERR-INSUFFICIENT-COLLATERAL)

        ;; 3. Lock collateral in vault.
        (try! (contract-call? .collateral-vault deposit-collateral tx-sender net-collat))

        ;; 4. Record position.
        (map-set positions
          { trader: tx-sender, id: position-id }
          {
            size:                  size,
            collateral:            net-collat,
            entry-price:           mark-price,
            is-long:               is-long,
            funding-index-at-open: (var-get cumulative-funding-index),
            opened-at-block:       burn-block-height,
            is-liquidated:         false
          }
        )

        ;; 5. Append ID to trader's list.
        (let ((existing-ids (default-to (list) (map-get? trader-positions tx-sender))))
          (map-set trader-positions tx-sender
            (unwrap-panic (as-max-len? (append existing-ids position-id) u50)))
        )

        (var-set next-position-id (+ position-id u1))

        ;; 6. Update aggregate OI.
        (if is-long
          (var-set total-long-oi  (+ (var-get total-long-oi)  size))
          (var-set total-short-oi (+ (var-get total-short-oi) size))
        )

        ;; 7. Accumulate protocol fee.
        (var-set protocol-fee-pool (+ (var-get protocol-fee-pool) fee))

        ;; 8. Trigger hedge rebalance in DEX.
        (let (
          (long-oi  (var-get total-long-oi))
          (short-oi (var-get total-short-oi))
          (net-long (> long-oi short-oi))
          (delta    (if (> long-oi short-oi)
                      (- long-oi short-oi)
                      (- short-oi long-oi)))
        )
          (if (> delta u0)
            (try! (contract-call? .sbtc-dex rebalance-hedge net-long delta))
            true
          )
        )

        ;; 9. Execute user swap in DEX (records price impact on user's side).
        (if is-long
          (try! (contract-call? .sbtc-dex swap-x-to-y size min-out tx-sender))
          (try! (contract-call? .sbtc-dex swap-y-to-x size min-out tx-sender))
        )

        (print {
          event:       "position-opened",
          trader:      tx-sender,
          id:          position-id,
          size:        size,
          collateral:  net-collat,
          entry-price: mark-price,
          is-long:     is-long,
          fee:         fee
        })
        (ok position-id)
      )
    )
  )
)

;; ── Close position ────────────────────────────────────────────────────────────

;; Close an existing position and settle PnL.
;;
;; Parameters:
;;   position-id — the ID returned by open-position
(define-public (close-position (position-id uint))
  (begin
    (try! (not-paused))

    (let ((pos (unwrap! (map-get? positions { trader: tx-sender, id: position-id })
                         ERR-POSITION-NOT-FOUND)))
      (asserts! (not (get is-liquidated pos)) ERR-ALREADY-LIQUIDATED)

      ;; Get fresh mark price.
      (let ((mark-price (try! (contract-call? .oracle-adapter get-btc-price))))

        (let (
          (pnl      (compute-pnl
                      (get size pos)
                      (get entry-price pos)
                      mark-price
                      (get is-long pos)))
          (funding  (compute-funding
                      (get size pos)
                      (get is-long pos)
                      (get funding-index-at-open pos)))
          (eff-col  (effective-collateral (get collateral pos) pnl funding))
          (fee      (calc-fee (get size pos)))
          (payout   (if (> eff-col fee) (- eff-col fee) u0))
        )
          ;; Mark as closed.
          (map-set positions { trader: tx-sender, id: position-id }
            (merge pos { is-liquidated: true }))

          ;; Update aggregate OI.
          (if (get is-long pos)
            (var-set total-long-oi
              (if (> (var-get total-long-oi) (get size pos))
                (- (var-get total-long-oi) (get size pos))
                u0))
            (var-set total-short-oi
              (if (> (var-get total-short-oi) (get size pos))
                (- (var-get total-short-oi) (get size pos))
                u0))
          )

          ;; Rebalance hedge after OI change.
          (let (
            (long-oi  (var-get total-long-oi))
            (short-oi (var-get total-short-oi))
            (net-long (> long-oi short-oi))
            (delta    (if (> long-oi short-oi)
                        (- long-oi short-oi)
                        (- short-oi long-oi)))
          )
            (if (> delta u0)
              (try! (contract-call? .sbtc-dex rebalance-hedge net-long delta))
              true
            )
          )

          ;; Release collateral and payout (vault sends sBTC to trader).
          (try! (contract-call? .collateral-vault
            release-collateral tx-sender (get collateral pos) tx-sender))

          ;; Accumulate protocol fee.
          (var-set protocol-fee-pool (+ (var-get protocol-fee-pool) fee))

          (print {
            event:       "position-closed",
            trader:      tx-sender,
            id:          position-id,
            mark-price:  mark-price,
            pnl:         pnl,
            funding:     funding,
            payout:      payout,
            fee:         fee
          })
          (ok { pnl: pnl, payout: payout })
        )
      )
    )
  )
)

;; ── Mark position as liquidated (called only by liquidation-engine) ────────────

(define-public (mark-liquidated (trader principal) (position-id uint))
  (begin
    (try! (only-extension))
    (let ((pos (unwrap! (map-get? positions { trader: trader, id: position-id })
                         ERR-POSITION-NOT-FOUND)))
      (asserts! (not (get is-liquidated pos)) ERR-ALREADY-LIQUIDATED)

      ;; Update aggregate OI.
      (if (get is-long pos)
        (var-set total-long-oi
          (if (> (var-get total-long-oi) (get size pos))
            (- (var-get total-long-oi) (get size pos))
            u0))
        (var-set total-short-oi
          (if (> (var-get total-short-oi) (get size pos))
            (- (var-get total-short-oi) (get size pos))
            u0))
      )

      ;; Rebalance hedge.
      (let (
        (long-oi  (var-get total-long-oi))
        (short-oi (var-get total-short-oi))
        (net-long (> long-oi short-oi))
        (delta    (if (> long-oi short-oi)
                    (- long-oi short-oi)
                    (- short-oi long-oi)))
      )
        (if (> delta u0)
          (try! (contract-call? .sbtc-dex rebalance-hedge net-long delta))
          true
        )
      )

      (map-set positions { trader: trader, id: position-id }
        (merge pos { is-liquidated: true }))

      (ok true)
    )
  )
)

;; ── Admin ─────────────────────────────────────────────────────────────────────

(define-public (set-paused (paused bool))
  (begin
    (asserts!
      (contract-call? .starstacks-core is-extension contract-caller)
      ERR-UNAUTHORIZED)
    (var-set engine-paused paused)
    (ok true)
  )
)

;; ── Read-only queries ─────────────────────────────────────────────────────────

(define-read-only (get-position (trader principal) (id uint))
  (map-get? positions { trader: trader, id: id })
)
(define-read-only (get-trader-positions (trader principal))
  (map-get? trader-positions trader)
)
(define-read-only (get-total-long-oi)   (var-get total-long-oi))
(define-read-only (get-total-short-oi)  (var-get total-short-oi))
(define-read-only (get-net-oi)
  (let ((l (var-get total-long-oi)) (s (var-get total-short-oi)))
    (if (>= l s)
      { direction: "long", size: (- l s) }
      { direction: "short", size: (- s l) }
    )
  )
)
(define-read-only (get-funding-index)   (var-get cumulative-funding-index))
(define-read-only (get-protocol-fees)   (var-get protocol-fee-pool))

;; Preview health factor for a position given a mark price.
(define-read-only (get-position-health (trader principal) (id uint) (mark-price uint))
  (match (map-get? positions { trader: trader, id: id })
    pos
      (let (
        (pnl     (compute-pnl
                    (get size pos)
                    (get entry-price pos)
                    mark-price
                    (get is-long pos)))
        (funding (compute-funding
                    (get size pos)
                    (get is-long pos)
                    (get funding-index-at-open pos)))
        (eff-col (effective-collateral (get collateral pos) pnl funding))
      )
        (some { health-bps: (health-factor eff-col (get size pos)),
                effective-collateral: eff-col,
                pnl: pnl,
                funding: funding })
      )
    none
  )
)
