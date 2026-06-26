;; governance/proposal-update-liquidation-params.clar
;; ─────────────────────────────────────────────────────────────────────────────
;; Example Governance Proposal: Adjust Liquidation Parameters
;;
;; Effect:
;;   • Raises keeper reward from 5% to 7% (700 bps) to attract more keepers.
;;   • Reduces insurance fund share from 10% to 8% (800 bps).
;; ─────────────────────────────────────────────────────────────────────────────

(impl-trait .proposal-trait.proposal-trait)

(define-constant NEW-KEEPER-REWARD-BPS   u700)  ;; 7%
(define-constant NEW-INSURANCE-FUND-BPS  u800)  ;; 8%

(define-public (execute (sender principal))
  (begin
    (try! (contract-call? .liquidation-engine set-keeper-reward-bps NEW-KEEPER-REWARD-BPS))
    (try! (contract-call? .liquidation-engine set-insurance-fund-bps NEW-INSURANCE-FUND-BPS))

    (print {
      event:               "proposal-executed",
      proposal:            "update-liquidation-params",
      sender:              sender,
      new-keeper-bps:      NEW-KEEPER-REWARD-BPS,
      new-insurance-bps:   NEW-INSURANCE-FUND-BPS,
      block:               block-height
    })
    (ok true)
  )
)
