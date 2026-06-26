;; collateral-vault.clar
;;
;; StarStacks Collateral Vault
;;
;; Custodies all sBTC collateral posted by traders.
;; Key responsibilities:
;;   1. Accept / release collateral on behalf of perpetual-engine.
;;   2. Track each depositor's share so Dual Stacking rewards are
;;      distributed proportionally when the vault receives sBTC yield.
;;   3. The vault's sBTC balance is tracked by dual-stacking-v2 for
;;      Dual Stacking rewards distribution.
;;
;; Dual Stacking Integration:
;;    The vault is enrolled in dual-stacking-v2 as a DeFi protocol.
;;    Enrollment is done via governance proposal or direct deployer call:
;;      contract-call? dual-stacking enroll <vault-address> <vault-address> none
;;
;;    The vault's sBTC balance is snapshotted each cycle by DS.
;;    When rewards arrive, anyone can call distribute-ds-rewards to fan out.
;;

;;  Error codes
(define-constant ERR-UNAUTHORIZED        (err u3000))
(define-constant ERR-INSUFFICIENT-FUNDS  (err u3001))
(define-constant ERR-ZERO-AMOUNT         (err u3002))
(define-constant ERR-NO-DEPOSIT          (err u3003))
(define-constant ERR-VAULT-LOCKED        (err u3004))
(define-constant ERR-NOTHING-TO-CLAIM    (err u3005))
(define-constant ERR-OVERFLOW            (err u3006))

;;  Precision
;; We track reward-per-share with 18 decimal places to minimize rounding loss.
(define-constant PRECISION u1000000000000000000) ;; 10^18

;;  sBTC contract
;; Mainnet sBTC token contract (SIP-010 fungible token).
(define-constant SBTC-TOKEN 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token)

;;  State

;; Total sBTC held as collateral across all open positions.
(define-data-var total-collateral uint u0)

;; Cumulative sBTC reward per collateral-share unit (scaled by PRECISION).
;; Increases monotonically as DS rewards arrive.
(define-data-var reward-per-share uint u0)

;; Total DS rewards accumulated (for analytics).
(define-data-var total-ds-rewards-received uint u0)

;; Emergency pause flag set by governance proposal only.
(define-data-var vault-paused bool false)

;;  Per-depositor state
;; Each trader who posts collateral has an entry here.
(define-map deposits
  principal  ;; trader
  {
    collateral:       uint, ;; sBTC sats locked in vault
    reward-debt:      uint, ;; reward-per-share at time of last claim/deposit
    pending-rewards:  uint  ;; unclaimed DS rewards (in sBTC sats)
  }
)

;;  Authorization

(define-private (only-engine)
  (ok (asserts!
        (contract-call? .starstacks-core is-extension contract-caller)
        ERR-UNAUTHORIZED))
)

(define-private (not-paused)
  (ok (asserts! (not (var-get vault-paused)) ERR-VAULT-LOCKED))
)

;;  Internal reward accounting

;; Harvest pending rewards for a depositor BEFORE any balance change.
;; This must be called at the start of every state-changing function.
(define-private (harvest (who principal))
  (match (map-get? deposits who)
    entry
      (let (
        (accrued (/ (* (get collateral entry) (var-get reward-per-share)) PRECISION))
        (debt    (/ (* (get collateral entry) (get reward-debt entry)) PRECISION))
        (earned  (if (> accrued debt) (- accrued debt) u0))
      )
        (map-set deposits who (merge entry {
          pending-rewards: (+ (get pending-rewards entry) earned),
          reward-debt:     (var-get reward-per-share)
        }))
      )
    ;; No deposit entry - nothing to harvest.
    true
  )
)

;;  Collateral deposit (called by perpetual-engine)

;; Locks `amount` sBTC as collateral for `trader`.
;; perpetual-engine must have already transferred the sBTC to this contract.
(define-public (deposit-collateral (trader principal) (amount uint))
  (begin
    (try! (not-paused))
    (try! (only-engine))
    (asserts! (> amount u0) ERR-ZERO-AMOUNT)

    ;; Harvest before changing balance.
    (harvest trader)

    (let ((existing (default-to
            { collateral: u0, reward-debt: u0, pending-rewards: u0 }
            (map-get? deposits trader))))
      (map-set deposits trader {
        collateral:      (+ (get collateral existing) amount),
        reward-debt:     (var-get reward-per-share),
        pending-rewards: (get pending-rewards existing)
      })
      (var-set total-collateral (+ (var-get total-collateral) amount))

      (print {
        event:   "collateral-deposited",
        trader:  trader,
        amount:  amount,
        total:   (var-get total-collateral)
      })
      (ok true)
    )
  )
)

;;  Collateral release (called by perpetual-engine on close/liquidation)

;; Releases `amount` sBTC back toward `recipient`.
(define-public (release-collateral (trader principal) (amount uint) (recipient principal))
  (begin
    (try! (only-engine))
    (asserts! (> amount u0) ERR-ZERO-AMOUNT)

    ;; Harvest pending rewards before reducing balance.
    (harvest trader)

    (let ((entry (unwrap! (map-get? deposits trader) ERR-NO-DEPOSIT)))
      (asserts! (>= (get collateral entry) amount) ERR-INSUFFICIENT-FUNDS)

      (map-set deposits trader (merge entry {
        collateral:  (- (get collateral entry) amount),
        reward-debt: (var-get reward-per-share)
      }))
      (var-set total-collateral (- (var-get total-collateral) amount))

      ;; Transfer sBTC to recipient.
      (try! (contract-call? SBTC-TOKEN transfer amount tx-sender recipient none))

      (print {
        event:     "collateral-released",
        trader:    trader,
        amount:    amount,
        recipient: recipient
      })
      (ok true)
    )
  )
)

;;  DS Reward distribution (permissionless)

;; When the Dual Stacking contract distributes rewards, sBTC lands in this vault.
;; Anyone can call this function to distribute rewards proportionally.
;;
;; NOTE: In production, rewards arrive via direct sBTC transfer from dual-stacking.
;; This function calculates how much new sBTC has arrived vs locked collateral
;; and increases the reward-per-share accordingly.
(define-public (distribute-ds-rewards)
  (begin
    (try! (not-paused))
    (let (
      ;; Get actual sBTC balance of this contract
      (vault-balance (unwrap-panic (contract-call? SBTC-TOKEN get-balance tx-sender)))
      (locked        (var-get total-collateral))
      ;; Any sBTC above locked collateral = DS rewards that have landed
      (new-rewards   (if (> vault-balance locked) (- vault-balance locked) u0))
    )
      (asserts! (> new-rewards u0) ERR-NOTHING-TO-CLAIM)
      (asserts! (> locked u0) ERR-NO-DEPOSIT)

      ;; Increase reward-per-share proportionally
      (var-set reward-per-share
        (+ (var-get reward-per-share)
           (/ (* new-rewards PRECISION) locked)))
      (var-set total-ds-rewards-received
        (+ (var-get total-ds-rewards-received) new-rewards))

      (print {
        event:            "ds-rewards-distributed",
        new-rewards:      new-rewards,
        reward-per-share: (var-get reward-per-share),
        total-collateral: locked
      })
      (ok new-rewards)
    )
  )
)

;;  Trader claims their pending DS rewards

(define-public (claim-ds-rewards)
  (begin
    (try! (not-paused))
    (harvest tx-sender)
    (let ((entry (unwrap! (map-get? deposits tx-sender) ERR-NO-DEPOSIT)))
      (let ((reward (get pending-rewards entry)))
        (asserts! (> reward u0) ERR-NOTHING-TO-CLAIM)
        (map-set deposits tx-sender (merge entry { pending-rewards: u0 }))
        (try! (contract-call? SBTC-TOKEN transfer reward tx-sender tx-sender none))
        (print {
          event:  "ds-reward-claimed",
          trader: tx-sender,
          amount: reward
        })
        (ok reward)
      )
    )
  )
)

;;  Emergency pause (governance proposal only)

(define-public (set-paused (paused bool))
  (begin
    (asserts!
      (contract-call? .starstacks-core is-extension contract-caller)
      ERR-UNAUTHORIZED)
    (var-set vault-paused paused)
    (print { event: "vault-pause-state", paused: paused })
    (ok true)
  )
)

;;  Read-only queries

(define-read-only (get-deposit (who principal))
  (map-get? deposits who)
)

(define-read-only (get-total-collateral)    (var-get total-collateral))
(define-read-only (get-reward-per-share)    (var-get reward-per-share))
(define-read-only (get-total-ds-received)   (var-get total-ds-rewards-received))
(define-read-only (get-vault-paused)        (var-get vault-paused))

;; Preview pending rewards for a depositor without mutating state.
(define-read-only (get-pending-rewards (who principal))
  (match (map-get? deposits who)
    entry
      (let (
        (accrued (/ (* (get collateral entry) (var-get reward-per-share)) PRECISION))
        (debt    (/ (* (get collateral entry) (get reward-debt entry))    PRECISION))
      )
        (+
          (get pending-rewards entry)
          (if (> accrued debt) (- accrued debt) u0)
        )
      )
    u0
  )
)
