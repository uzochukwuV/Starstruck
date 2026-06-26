;; starstacks-core.clar
;; ─────────────────────────────────────────────────────────────────────────────
;; StarStacks Protocol Core
;;
;; The single source of truth for authorization in the StarStacks ecosystem.
;; Responsibilities:
;;   1. Maintain a registry of authorized extension contracts.
;;   2. Execute governance proposals (which are themselves smart contracts).
;;   3. Bootstrap the protocol with an initial set of extensions.
;;
;; All state-changing operations in child contracts must call back to
;; `is-extension` or `is-self` before proceeding.
;;
;; Design: ExecutorDAO pattern — proposals are contracts, extensions give form.
;; ─────────────────────────────────────────────────────────────────────────────

(use-trait proposal-trait  .proposal-trait.proposal-trait)
(use-trait extension-trait .extension-trait.extension-trait)

;; ── Error codes ──────────────────────────────────────────────────────────────
(define-constant ERR-UNAUTHORIZED          (err u1000))
(define-constant ERR-ALREADY-EXECUTED      (err u1001))
(define-constant ERR-INVALID-EXTENSION     (err u1002))
(define-constant ERR-NOT-INITIALIZED       (err u1003))
(define-constant ERR-ALREADY-INITIALIZED   (err u1004))
(define-constant ERR-EXTENSION-NOT-FOUND   (err u1005))

;; ── State ─────────────────────────────────────────────────────────────────────

;; Whether the protocol has been bootstrapped.
(define-data-var initialized bool false)

;; The founding deployer — only used during bootstrap, then relinquished.
(define-data-var deployer principal tx-sender)

;; Registry of authorized extension contracts.
;; value: true = active, false = revoked (kept for audit trail).
(define-map extensions principal bool)

;; Proposals that have already been executed (replay protection).
(define-map executed-proposals principal uint) ;; principal → block-height

;; ── Authorization helpers ────────────────────────────────────────────────────

;; True if the caller IS this contract acting on its own behalf.
(define-private (is-self)
  (is-eq tx-sender (as-contract tx-sender))
)

;; True if contract-caller is a currently active extension.
(define-read-only (is-extension (who principal))
  (default-to false (map-get? extensions who))
)

;; Gate used by all privileged internal operations:
;; Must be called by this contract itself OR an active extension.
(define-private (is-self-or-extension)
  (ok (asserts!
        (or (is-self) (is-extension contract-caller))
        ERR-UNAUTHORIZED))
)

;; ── Bootstrap ────────────────────────────────────────────────────────────────

;; Called once by the deployer to register the initial set of extension
;; contracts.  After this call `initialized` is true and the deployer loses
;; all special privileges.
(define-public (initialize
    (perpetual-engine     principal)
    (sbtc-dex             principal)
    (oracle-adapter       principal)
    (liquidation-engine   principal)
    (collateral-vault     principal))
  (begin
    (asserts! (not (var-get initialized)) ERR-ALREADY-INITIALIZED)
    (asserts! (is-eq tx-sender (var-get deployer)) ERR-UNAUTHORIZED)

    ;; Register each extension.
    (map-set extensions perpetual-engine   true)
    (map-set extensions sbtc-dex           true)
    (map-set extensions oracle-adapter     true)
    (map-set extensions liquidation-engine true)
    (map-set extensions collateral-vault   true)

    ;; Emit bootstrap event for indexers.
    (print {
      event:              "bootstrap",
      perpetual-engine:   perpetual-engine,
      sbtc-dex:           sbtc-dex,
      oracle-adapter:     oracle-adapter,
      liquidation-engine: liquidation-engine,
      collateral-vault:   collateral-vault,
      block:              block-height
    })

    (var-set initialized true)
    (ok true)
  )
)

;; ── Proposal execution ───────────────────────────────────────────────────────

;; Execute a governance proposal contract.
;; Any active extension may submit a proposal; the proposal must not have
;; already been executed.
(define-public (execute (proposal <proposal-trait>) (sender principal))
  (begin
    (try! (is-self-or-extension))
    (asserts!
      (map-insert executed-proposals (contract-of proposal) block-height)
      ERR-ALREADY-EXECUTED)

    (print {
      event:    "execute-proposal",
      proposal: (contract-of proposal),
      sender:   sender,
      block:    block-height
    })

    ;; Run proposal logic as this contract so it has core-level authority.
    (as-contract (contract-call? proposal execute sender))
  )
)

;; ── Extension management (called from proposals) ─────────────────────────────

;; Enable a new extension or re-enable a revoked one.
(define-public (set-extension (extension principal) (enabled bool))
  (begin
    (try! (is-self-or-extension))
    (print {
      event:     "set-extension",
      extension: extension,
      enabled:   enabled,
      block:     block-height
    })
    (ok (map-set extensions extension enabled))
  )
)

;; Convenience: enable multiple extensions atomically (useful in proposals).
(define-public (set-extensions (extension-list (list 10 { extension: principal, enabled: bool })))
  (begin
    (try! (is-self-or-extension))
    (ok (map set-extension-entry extension-list))
  )
)

(define-private (set-extension-entry (entry { extension: principal, enabled: bool }))
  (begin
    (print {
      event:     "set-extension",
      extension: (get extension entry),
      enabled:   (get enabled entry),
      block:     block-height
    })
    (map-set extensions (get extension entry) (get enabled entry))
  )
)

;; ── Read-only queries ────────────────────────────────────────────────────────

(define-read-only (get-initialized)       (var-get initialized))
(define-read-only (get-deployer)          (var-get deployer))
(define-read-only (get-extension-status (who principal))
  (default-to false (map-get? extensions who))
)
(define-read-only (get-executed-at (proposal principal))
  (map-get? executed-proposals proposal)
)
