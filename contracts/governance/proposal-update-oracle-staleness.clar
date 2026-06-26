;; governance/proposal-update-oracle-staleness.clar
;; ─────────────────────────────────────────────────────────────────────────────
;; Example Governance Proposal: Update Oracle Max Price Age
;;
;; This contract IS the proposal. It implements proposal-trait.
;; Submitted to starstacks-core.execute() by any authorized extension.
;;
;; Effect: Updates the oracle adapter's maximum acceptable price age
;;         from the default (5 blocks) to 8 blocks.
;;
;; Governance flow:
;;   1. This contract is deployed by a governance participant.
;;   2. An authorized extension calls: (contract-call? .starstacks-core execute .this-proposal tx-sender)
;;   3. Core verifies extension auth, marks proposal executed, calls execute().
;;   4. execute() runs with core-level authority.
;; ─────────────────────────────────────────────────────────────────────────────

(impl-trait .proposal-trait.proposal-trait)

(define-constant NEW-MAX-AGE u8) ;; 8 Bitcoin blocks ≈ 80 minutes

(define-public (execute (sender principal))
  (begin
    ;; Update oracle staleness window.
    (try! (contract-call? .oracle-adapter set-max-price-age (some NEW-MAX-AGE)))

    (print {
      event:       "proposal-executed",
      proposal:    "update-oracle-staleness",
      sender:      sender,
      new-max-age: NEW-MAX-AGE,
      block:       block-height
    })
    (ok true)
  )
)
