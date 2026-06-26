;; sbtc-dex.clar
;; ─────────────────────────────────────────────────────────────────────────────
;; StarStacks Internal DEX
;;
;; A constant-product AMM (x*y=k) for sBTC/BTC (represented as two SIP-010
;; tokens or sBTC vs a synthetic BTC position token).
;;
;; Responsibilities:
;;   1. Maintain a liquidity pool that LPs can deposit into / withdraw from.
;;   2. Execute swaps for user position opens (buy/sell BTC exposure).
;;   3. Execute hedge-rebalance swaps triggered by perpetual-engine when the
;;      net imbalance between longs and shorts changes.
;;   4. Accrue swap fees to LPs.
;;
;; Hedge model:
;;   The perpetual engine calls `rebalance-hedge` with the signed net delta
;;   (positive = more longs than shorts → protocol needs to SHORT sBTC to
;;   neutralise; negative = more shorts → protocol needs to LONG sBTC).
;;   Only the CHANGE in net delta is swapped, not the whole position.
;;
;; Fee: 10 bps (0.10%) on each swap, held in the pool for LPs.
;; ─────────────────────────────────────────────────────────────────────────────

;; ── Error codes ───────────────────────────────────────────────────────────────
(define-constant ERR-UNAUTHORIZED          (err u4000))
(define-constant ERR-ZERO-AMOUNT           (err u4001))
(define-constant ERR-INSUFFICIENT-LIQUIDITY (err u4002))
(define-constant ERR-SLIPPAGE-TOO-HIGH     (err u4003))
(define-constant ERR-POOL-LOCKED           (err u4004))
(define-constant ERR-ZERO-LP               (err u4005))
(define-constant ERR-OVERFLOW              (err u4006))
(define-constant ERR-SAME-TOKEN            (err u4007))

;; ── Constants ────────────────────────────────────────────────────────────────
;; Swap fee: 10 bps = 10 / 10000
(define-constant FEE-NUMERATOR   u10)
(define-constant FEE-DENOMINATOR u10000)

;; Precision for LP share tracking.
(define-constant LP-PRECISION u1000000000000) ;; 10^12

;; Minimum liquidity locked forever to prevent pool draining.
(define-constant MINIMUM-LIQUIDITY u1000)

;; ── sBTC token reference ─────────────────────────────────────────────────────
(define-constant SBTC-TOKEN .sbtc-token)

;; ── Pool state ────────────────────────────────────────────────────────────────

;; Pool reserves (in sBTC sats and synthetic-BTC sats).
;; We represent "BTC" as a synthetic token (sBTC mirroring a BTC long position).
;; In practice both sides are sBTC-denominated; the x/y split tracks directional
;; exposure rather than two distinct tokens.
(define-data-var reserve-x uint u0)   ;; sBTC reserve (base)
(define-data-var reserve-y uint u0)   ;; synthetic BTC reserve (quote)

;; Total LP shares issued.
(define-data-var total-lp-shares uint u0)

;; Accumulated protocol fee reserve (for insurance fund).
(define-data-var insurance-reserve uint u0)

;; Current hedge position held by the protocol (signed as (direction, size)).
;; direction: true = long sBTC hedge, false = short sBTC hedge.
(define-data-var hedge-direction bool true)
(define-data-var hedge-size      uint u0)

;; Emergency pause.
(define-data-var pool-paused bool false)

;; ── LP shares per provider ────────────────────────────────────────────────────
(define-map lp-shares principal uint)

;; ── Authorization ────────────────────────────────────────────────────────────

(define-private (only-extension)
  (ok (asserts!
        (contract-call? .starstacks-core is-extension contract-caller)
        ERR-UNAUTHORIZED))
)

(define-private (not-paused)
  (ok (asserts! (not (var-get pool-paused)) ERR-POOL-LOCKED))
)

;; ── Math helpers ─────────────────────────────────────────────────────────────

;; Constant-product output: given `in`, reserves `rx` and `ry`, return amount out.
;; Formula (with fee deducted on input):
;;   amount_in_with_fee = amount_in * (FEE_DENOM - FEE_NUM)
;;   amount_out = (amount_in_with_fee * ry) / (rx * FEE_DENOM + amount_in_with_fee)
(define-private (get-amount-out (amount-in uint) (rx uint) (ry uint))
  (let (
    (amount-with-fee (* amount-in (- FEE-DENOMINATOR FEE-NUMERATOR)))
    (numerator       (* amount-with-fee ry))
    (denominator     (+ (* rx FEE-DENOMINATOR) amount-with-fee))
  )
    (/ numerator denominator)
  )
)

;; Integer square root (Babylonian method) — used for initial LP minting.
(define-private (sqrt (n uint))
  (if (< n u2)
    n
    (let ((x (/ (+ n u1) u2)))
      (let ((x1 (/ (+ x (/ n x)) u2)))
        (let ((x2 (/ (+ x1 (/ n x1)) u2)))
          (let ((x3 (/ (+ x2 (/ n x2)) u2)))
            (let ((x4 (/ (+ x3 (/ n x3)) u2)))
              (if (<= x4 x3) x4 x3)
            )
          )
        )
      )
    )
  )
)

;; ── Liquidity provision ───────────────────────────────────────────────────────

;; Add liquidity to the pool.
;; Both sides must be deposited in proportion to current reserves (after the
;; first deposit which sets the initial ratio).
;;
;; Parameters:
;;   amount-x  — sBTC sats to add on the x side
;;   amount-y  — sBTC sats to add on the y (synthetic BTC) side
;;   min-lp    — minimum LP shares to receive (slippage guard)
(define-public (add-liquidity (amount-x uint) (amount-y uint) (min-lp uint))
  (begin
    (try! (not-paused))
    (asserts! (and (> amount-x u0) (> amount-y u0)) ERR-ZERO-AMOUNT)

    (let (
      (rx (var-get reserve-x))
      (ry (var-get reserve-y))
      (total-lp (var-get total-lp-shares))
    )
      (let (
        ;; LP shares minted:
        ;; First deposit: sqrt(x*y) - MINIMUM_LIQUIDITY
        ;; Subsequent: min(amount_x/rx, amount_y/ry) * total_lp
        (lp-minted
          (if (is-eq total-lp u0)
            (let ((geo-mean (sqrt (* amount-x amount-y))))
              (asserts! (> geo-mean MINIMUM-LIQUIDITY) ERR-ZERO-LP)
              (- geo-mean MINIMUM-LIQUIDITY)
            )
            (let (
              (lp-x (/ (* amount-x total-lp) rx))
              (lp-y (/ (* amount-y total-lp) ry))
            )
              (if (< lp-x lp-y) lp-x lp-y)
            )
          )
        )
      )
        (asserts! (>= lp-minted min-lp) ERR-SLIPPAGE-TOO-HIGH)
        (asserts! (> lp-minted u0) ERR-ZERO-LP)

        ;; Transfer sBTC from LP provider to this contract.
        ;; (In a real two-token pool, x and y are separate tokens;
        ;;  here both are sBTC representing different sides of the book.)
        (try! (contract-call? SBTC-TOKEN transfer amount-x tx-sender (as-contract tx-sender) none))

        ;; Update state.
        (var-set reserve-x (+ rx amount-x))
        (var-set reserve-y (+ ry amount-y))
        (var-set total-lp-shares (+ total-lp lp-minted))
        (map-set lp-shares tx-sender
          (+ (default-to u0 (map-get? lp-shares tx-sender)) lp-minted))

        (print {
          event:     "liquidity-added",
          provider:  tx-sender,
          amount-x:  amount-x,
          amount-y:  amount-y,
          lp-minted: lp-minted
        })
        (ok lp-minted)
      )
    )
  )
)

;; Remove liquidity from the pool.
;; Burns LP shares and returns proportional sBTC.
(define-public (remove-liquidity (lp-amount uint) (min-x uint) (min-y uint))
  (begin
    (try! (not-paused))
    (asserts! (> lp-amount u0) ERR-ZERO-AMOUNT)

    (let (
      (total-lp  (var-get total-lp-shares))
      (rx        (var-get reserve-x))
      (ry        (var-get reserve-y))
      (user-lp   (default-to u0 (map-get? lp-shares tx-sender)))
    )
      (asserts! (>= user-lp lp-amount) ERR-INSUFFICIENT-LIQUIDITY)

      (let (
        (out-x (/ (* lp-amount rx) total-lp))
        (out-y (/ (* lp-amount ry) total-lp))
      )
        (asserts! (>= out-x min-x) ERR-SLIPPAGE-TOO-HIGH)
        (asserts! (>= out-y min-y) ERR-SLIPPAGE-TOO-HIGH)

        ;; Burn LP shares.
        (map-set lp-shares tx-sender (- user-lp lp-amount))
        (var-set total-lp-shares (- total-lp lp-amount))
        (var-set reserve-x (- rx out-x))
        (var-set reserve-y (- ry out-y))

        ;; Return sBTC.
        (try! (as-contract
          (contract-call? SBTC-TOKEN transfer out-x tx-sender tx-sender none)))

        (print {
          event:    "liquidity-removed",
          provider: tx-sender,
          lp-burnt: lp-amount,
          out-x:    out-x,
          out-y:    out-y
        })
        (ok { out-x: out-x, out-y: out-y })
      )
    )
  )
)

;; ── User swap: buy BTC exposure (long) ───────────────────────────────────────

;; Swap sBTC in → synthetic BTC out (opens/increases long BTC exposure).
;; Called by perpetual-engine when a user opens a long position.
;;
;; Parameters:
;;   amount-in — sBTC sats going in
;;   min-out   — minimum synthetic BTC out (slippage guard)
;;   trader    — the user whose position is being opened
(define-public (swap-x-to-y (amount-in uint) (min-out uint) (trader principal))
  (begin
    (try! (not-paused))
    (try! (only-extension))
    (asserts! (> amount-in u0) ERR-ZERO-AMOUNT)

    (let (
      (rx      (var-get reserve-x))
      (ry      (var-get reserve-y))
      (out     (get-amount-out amount-in rx ry))
    )
      (asserts! (>= out min-out) ERR-SLIPPAGE-TOO-HIGH)
      (asserts! (> ry out) ERR-INSUFFICIENT-LIQUIDITY)

      (var-set reserve-x (+ rx amount-in))
      (var-set reserve-y (- ry out))

      (print {
        event:      "swap",
        direction:  "x-to-y",
        trader:     trader,
        amount-in:  amount-in,
        amount-out: out,
        reserve-x:  (var-get reserve-x),
        reserve-y:  (var-get reserve-y)
      })
      (ok out)
    )
  )
)

;; Swap synthetic BTC in → sBTC out (closes/decreases long, or opens short).
(define-public (swap-y-to-x (amount-in uint) (min-out uint) (trader principal))
  (begin
    (try! (not-paused))
    (try! (only-extension))
    (asserts! (> amount-in u0) ERR-ZERO-AMOUNT)

    (let (
      (rx  (var-get reserve-x))
      (ry  (var-get reserve-y))
      (out (get-amount-out amount-in ry rx))
    )
      (asserts! (>= out min-out) ERR-SLIPPAGE-TOO-HIGH)
      (asserts! (> rx out) ERR-INSUFFICIENT-LIQUIDITY)

      (var-set reserve-y (+ ry amount-in))
      (var-set reserve-x (- rx out))

      (print {
        event:      "swap",
        direction:  "y-to-x",
        trader:     trader,
        amount-in:  amount-in,
        amount-out: out,
        reserve-x:  (var-get reserve-x),
        reserve-y:  (var-get reserve-y)
      })
      (ok out)
    )
  )
)

;; ── Hedge rebalancer (called by perpetual-engine) ─────────────────────────────

;; Rebalances the protocol's net directional hedge.
;;
;; Parameters:
;;   new-net-long  — true if longs > shorts after the latest position change
;;   delta-size    — the CHANGE in net imbalance (sats), not the total OI
;;
;; Logic:
;;   If new net is long and delta > 0 → protocol needs to sell sBTC (short hedge).
;;   If new net is short and delta > 0 → protocol needs to buy sBTC (long hedge).
;;   If delta is 0, no swap needed.
(define-public (rebalance-hedge (new-net-long bool) (delta-size uint))
  (begin
    (try! (only-extension))
    (asserts! (> delta-size u0) ERR-ZERO-AMOUNT)

    (let (
      (rx  (var-get reserve-x))
      (ry  (var-get reserve-y))
    )
      (if new-net-long
        ;; More longs than shorts → protocol shorts sBTC: swap x→y internally.
        (let ((out (get-amount-out delta-size rx ry)))
          (asserts! (> ry out) ERR-INSUFFICIENT-LIQUIDITY)
          (var-set reserve-x (+ rx delta-size))
          (var-set reserve-y (- ry out))
          (var-set hedge-direction false)  ;; holding short hedge
          (var-set hedge-size delta-size)
          (print {
            event:      "hedge-rebalanced",
            direction:  "short",
            delta-size: delta-size,
            out:        out
          })
          (ok out)
        )
        ;; More shorts than longs → protocol longs sBTC: swap y→x internally.
        (let ((out (get-amount-out delta-size ry rx)))
          (asserts! (> rx out) ERR-INSUFFICIENT-LIQUIDITY)
          (var-set reserve-y (+ ry delta-size))
          (var-set reserve-x (- rx out))
          (var-set hedge-direction true)   ;; holding long hedge
          (var-set hedge-size delta-size)
          (print {
            event:      "hedge-rebalanced",
            direction:  "long",
            delta-size: delta-size,
            out:        out
          })
          (ok out)
        )
      )
    )
  )
)

;; ── Admin ─────────────────────────────────────────────────────────────────────

(define-public (set-paused (paused bool))
  (begin
    (asserts!
      (contract-call? .starstacks-core is-extension contract-caller)
      ERR-UNAUTHORIZED)
    (var-set pool-paused paused)
    (ok true)
  )
)

;; ── Read-only queries ─────────────────────────────────────────────────────────

(define-read-only (get-reserves)
  { reserve-x: (var-get reserve-x), reserve-y: (var-get reserve-y) }
)
(define-read-only (get-total-lp)         (var-get total-lp-shares))
(define-read-only (get-lp-shares (who principal))
  (default-to u0 (map-get? lp-shares who))
)
(define-read-only (get-hedge-state)
  { direction: (var-get hedge-direction), size: (var-get hedge-size) }
)
(define-read-only (get-insurance-reserve) (var-get insurance-reserve))

;; Preview a swap without executing it.
(define-read-only (quote-swap-x-to-y (amount-in uint))
  (get-amount-out amount-in (var-get reserve-x) (var-get reserve-y))
)
(define-read-only (quote-swap-y-to-x (amount-in uint))
  (get-amount-out amount-in (var-get reserve-y) (var-get reserve-x))
)
