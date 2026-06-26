;; liquidation-engine.clar
;; ─────────────────────────────────────────────────────────────────────────────
;; StarStacks Liquidation Engine
;;
;; Permissionless liquidation of undercollateralised positions.
;;
;; A position is liquidatable when its health factor drops below
;; MIN-COLLATERAL-RATIO-BPS (400 bps = 4%).
;;
;; When liquidated:
;;   • A keeper (anyone) calls `liquidate`.
;;   • The engine verifies the position is unhealthy using the safe oracle price.
;;   • The entire remaining collateral is seized from the vault.
;;   • KEEPER-REWARD-BPS of the seized collateral goes to the keeper.
;;   • INSURANCE-FUND-BPS of the seized collateral goes to the insurance fund.
;;   • Any remainder goes to the trader (if in profit despite being underwater).
;;   • The position is marked closed in perpetual-engine.
;;   • OI is decremented and hedge is rebalanced.
;;
;; Keeper incentive: 5% of seized collateral (configurable by governance).
;; Insurance fund: 10% of seized collateral.
;; ─────────────────────────────────────────────────────────────────────────────

;; ── Error codes ───────────────────────────────────────────────────────────────
(define-constant ERR-UNAUTHORIZED          (err u6000))
(define-constant ERR-POSITION-NOT-FOUND    (err u6001))
(define-constant ERR-NOT-LIQUIDATABLE      (err u6002))
(define-constant ERR-ALREADY-LIQUIDATED    (err u6003))
(define-constant ERR-PRICE-STALE           (err u6004))
(define-constant ERR-ENGINE-PAUSED         (err u6005))
(define-constant ERR-SELF-LIQUIDATION      (err u6006))
(define-constant ERR-ZERO-COLLATERAL       (err u6007))

;; ── Constants ─────────────────────────────────────────────────────────────────

;; Position health threshold — below this → liquidatable.
(define-constant MIN-COLLATERAL-RATIO-BPS u400)  ;; 4.00%

;; Keeper reward: 5% of seized collateral.
(define-constant KEEPER-REWARD-BPS u500)

;; Insurance fund share: 10% of seized collateral.
(define-constant INSURANCE-FUND-BPS u1000)

;; Price scale from oracle.
(define-constant PRICE-SCALE u100000000) ;; 10^8

;; ── sBTC token ────────────────────────────────────────────────────────────────
(define-constant SBTC-TOKEN .sbtc-token)

;; ── State ─────────────────────────────────────────────────────────────────────

;; Insurance fund accumulation (sBTC sats).
(define-data-var insurance-fund uint u0)

;; Total liquidations ever executed.
(define-data-var total-liquidations uint u0)

;; Total sBTC ever seized.
(define-data-var total-seized uint u0)

;; Pause flag (set by governance).
(define-data-var engine-paused bool false)

;; Configurable keeper reward (governance can adjust).
(define-data-var keeper-reward-bps uint KEEPER-REWARD-BPS)

;; Configurable insurance fund bps.
(define-data-var insurance-fund-bps uint INSURANCE-FUND-BPS)

;; ── Internal helpers ─────────────────────────────────────────────────────────

;; Compute PnL for a position (mirrors perpetual-engine logic).
;; Returns signed integer.
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
    (/ (* (to-int size) price-delta) (to-int entry-price))
  )
)

;; Compute accrued funding for a position.
(define-private (compute-funding
    (size uint)
    (is-long bool)
    (funding-at-open int))
  (let (
    (current-index (contract-call? .perpetual-engine get-funding-index))
    (delta (- current-index funding-at-open))
    (funding-amount (/ (* (to-int size) (if (< delta 0) (* delta -1) delta))
                       (to-int PRICE-SCALE)))
  )
    (if is-long
      (* funding-amount -1)
      funding-amount
    )
  )
)

;; Net collateral after PnL and funding.
(define-private (effective-collateral
    (collateral uint)
    (pnl int)
    (funding int))
  (let ((net (+ (to-int collateral) pnl funding)))
    (if (< net 0) u0 (to-uint net))
  )
)

;; Health factor in basis points.
(define-private (health-factor (eff-collateral uint) (size uint))
  (if (is-eq size u0)
    u10000
    (/ (* eff-collateral u10000) size)
  )
)

;; ── Core liquidation function (permissionless) ────────────────────────────────

;; Liquidate an undercollateralised position.
;;
;; Anyone can call this on any trader's position.
;; Keepers are economically incentivised by the KEEPER-REWARD-BPS payout.
;;
;; Parameters:
;;   trader      — owner of the position
;;   position-id — position to liquidate
(define-public (liquidate (trader principal) (position-id uint))
  (begin
    (asserts! (not (var-get engine-paused)) ERR-ENGINE-PAUSED)
    ;; Prevent self-liquidation abuse (keeper shouldn't also be the trader,
    ;; but we allow it with a note — keepers are incentivised, not penalised).
    ;; Left as soft check: uncomment to enforce strict separation:
    ;; (asserts! (not (is-eq tx-sender trader)) ERR-SELF-LIQUIDATION)

    ;; 1. Get safe, fresh BTC price.
    (let ((mark-price (try! (contract-call? .oracle-adapter get-btc-price))))

      ;; 2. Fetch position from perpetual-engine.
      (let ((pos (unwrap!
                    (contract-call? .perpetual-engine get-position trader position-id)
                    ERR-POSITION-NOT-FOUND)))

        (asserts! (not (get is-liquidated pos)) ERR-ALREADY-LIQUIDATED)

        ;; 3. Compute health.
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
          (hf      (health-factor eff-col (get size pos)))
        )
          ;; 4. Gate: position must be unhealthy.
          (asserts! (< hf MIN-COLLATERAL-RATIO-BPS) ERR-NOT-LIQUIDATABLE)

          ;; 5. Seize collateral from vault.
          (let (
            (seized     (get collateral pos))
            (keeper-cut (/ (* seized (var-get keeper-reward-bps)) u10000))
            (ins-cut    (/ (* seized (var-get insurance-fund-bps)) u10000))
            (trader-remainder
              (if (> seized (+ keeper-cut ins-cut))
                (- seized (+ keeper-cut ins-cut))
                u0))
          )
            (asserts! (> seized u0) ERR-ZERO-COLLATERAL)

            ;; 6. Release collateral from vault to this contract.
            (try! (contract-call? .collateral-vault
              release-collateral trader seized (as-contract tx-sender)))

            ;; 7. Pay keeper.
            (if (> keeper-cut u0)
              (try! (as-contract
                (contract-call? SBTC-TOKEN transfer keeper-cut tx-sender tx-sender none)))
              true
            )

            ;; 8. Hold insurance fund share (stays in this contract).
            (var-set insurance-fund (+ (var-get insurance-fund) ins-cut))

            ;; 9. Return any remainder to trader.
            (if (> trader-remainder u0)
              (try! (as-contract
                (contract-call? SBTC-TOKEN transfer trader-remainder tx-sender trader none)))
              true
            )

            ;; 10. Mark position closed in perpetual-engine + rebalance hedge.
            (try! (contract-call? .perpetual-engine
              mark-liquidated trader position-id))

            ;; 11. Update stats.
            (var-set total-liquidations (+ (var-get total-liquidations) u1))
            (var-set total-seized (+ (var-get total-seized) seized))

            (print {
              event:            "liquidation",
              keeper:           tx-sender,
              trader:           trader,
              position-id:      position-id,
              mark-price:       mark-price,
              entry-price:      (get entry-price pos),
              seized:           seized,
              keeper-cut:       keeper-cut,
              insurance-cut:    ins-cut,
              trader-remainder: trader-remainder,
              health-factor:    hf,
              pnl:              pnl,
              funding:          funding
            })
            (ok {
              seized:           seized,
              keeper-reward:    keeper-cut,
              trader-remainder: trader-remainder
            })
          )
        )
      )
    )
  )
)

;; ── Batch liquidation (gas-efficient for keepers) ─────────────────────────────

;; Attempt to liquidate up to 10 positions in one transaction.
;; Failed individual liquidations are skipped (position healthy or already closed).
(define-public (liquidate-batch
    (targets (list 10 { trader: principal, position-id: uint })))
  (begin
    (asserts! (not (var-get engine-paused)) ERR-ENGINE-PAUSED)
    (ok (map liquidate-one targets))
  )
)

(define-private (liquidate-one
    (target { trader: principal, position-id: uint }))
  (match (liquidate (get trader target) (get position-id target))
    result (some result)
    err-val none
  )
)

;; ── Check if a position is currently liquidatable (read-only preview) ─────────

(define-read-only (is-liquidatable (trader principal) (position-id uint) (mark-price uint))
  (match (contract-call? .perpetual-engine get-position trader position-id)
    pos
      (if (get is-liquidated pos)
        false
        (let (
          (pnl     (compute-pnl
                      (get size pos) (get entry-price pos) mark-price (get is-long pos)))
          (funding (compute-funding
                      (get size pos) (get is-long pos) (get funding-index-at-open pos)))
          (eff-col (effective-collateral (get collateral pos) pnl funding))
          (hf      (health-factor eff-col (get size pos)))
        )
          (< hf MIN-COLLATERAL-RATIO-BPS)
        )
      )
    false
  )
)

;; ── Governance: adjust liquidation parameters ─────────────────────────────────

(define-public (set-keeper-reward-bps (new-bps uint))
  (begin
    (asserts!
      (contract-call? .starstacks-core is-extension contract-caller)
      ERR-UNAUTHORIZED)
    ;; Cap at 20% to prevent abuse.
    (asserts! (<= new-bps u2000) ERR-UNAUTHORIZED)
    (var-set keeper-reward-bps new-bps)
    (print { event: "keeper-reward-updated", bps: new-bps })
    (ok true)
  )
)

(define-public (set-insurance-fund-bps (new-bps uint))
  (begin
    (asserts!
      (contract-call? .starstacks-core is-extension contract-caller)
      ERR-UNAUTHORIZED)
    (asserts! (<= new-bps u3000) ERR-UNAUTHORIZED)
    (var-set insurance-fund-bps new-bps)
    (print { event: "insurance-fund-bps-updated", bps: new-bps })
    (ok true)
  )
)

(define-public (set-paused (paused bool))
  (begin
    (asserts!
      (contract-call? .starstacks-core is-extension contract-caller)
      ERR-UNAUTHORIZED)
    (var-set engine-paused paused)
    (ok true)
  )
)

;; Governance withdrawal of insurance fund (e.g., to cover bad debt).
(define-public (withdraw-insurance (amount uint) (recipient principal))
  (begin
    (asserts!
      (contract-call? .starstacks-core is-extension contract-caller)
      ERR-UNAUTHORIZED)
    (asserts! (<= amount (var-get insurance-fund)) ERR-ZERO-COLLATERAL)
    (var-set insurance-fund (- (var-get insurance-fund) amount))
    (try! (as-contract
      (contract-call? SBTC-TOKEN transfer amount tx-sender recipient none)))
    (print { event: "insurance-withdrawn", amount: amount, recipient: recipient })
    (ok true)
  )
)

;; ── Read-only queries ─────────────────────────────────────────────────────────

(define-read-only (get-insurance-fund)     (var-get insurance-fund))
(define-read-only (get-total-liquidations) (var-get total-liquidations))
(define-read-only (get-total-seized)       (var-get total-seized))
(define-read-only (get-keeper-reward-bps)  (var-get keeper-reward-bps))
(define-read-only (get-insurance-bps)      (var-get insurance-fund-bps))
