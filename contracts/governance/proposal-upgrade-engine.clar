;; governance/proposal-upgrade-engine.clar
;; ─────────────────────────────────────────────────────────────────────────────
;; Governance Proposal: Upgrade Perpetual Engine to V2
;;
;; Effect:
;;   1. Disables the old perpetual-engine-v1 as an authorized extension.
;;   2. Enables the new perpetual-engine-v2.
;;
;; Note: Existing positions in v1 must be migrated or wound down before
;; disabling v1.  This proposal should be paired with a migration window.
;; ─────────────────────────────────────────────────────────────────────────────

(impl-trait .proposal-trait.proposal-trait)

;; The new engine contract principal (replace with actual address at deploy time).
(define-constant NEW-ENGINE 'SP000000000000000000002Q6VF78.perpetual-engine-v2)

(define-public (execute (sender principal))
  (begin
    ;; Revoke old engine.
    (try! (contract-call? .starstacks-core set-extension .perpetual-engine false))

    ;; Authorize new engine.
    (try! (contract-call? .starstacks-core set-extension NEW-ENGINE true))

    (print {
      event:      "proposal-executed",
      proposal:   "upgrade-engine",
      sender:     sender,
      old-engine: .perpetual-engine,
      new-engine: NEW-ENGINE,
      block:      block-height
    })
    (ok true)
  )
)
