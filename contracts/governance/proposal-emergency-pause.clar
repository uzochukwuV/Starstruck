;; governance/proposal-emergency-pause.clar
;; ─────────────────────────────────────────────────────────────────────────────
;; Emergency Governance Proposal: Pause All Protocol Components
;;
;; Used in response to a security incident or oracle failure.
;; Pauses: perpetual-engine, sbtc-dex, collateral-vault, liquidation-engine.
;;
;; To unpause, deploy and execute proposal-unpause.clar.
;; ─────────────────────────────────────────────────────────────────────────────

(impl-trait .proposal-trait.proposal-trait)

(define-public (execute (sender principal))
  (begin
    (try! (contract-call? .perpetual-engine   set-paused true))
    (try! (contract-call? .sbtc-dex           set-paused true))
    (try! (contract-call? .collateral-vault   set-paused true))
    (try! (contract-call? .liquidation-engine set-paused true))

    (print {
      event:    "proposal-executed",
      proposal: "emergency-pause",
      sender:   sender,
      block:    block-height
    })
    (ok true)
  )
)
