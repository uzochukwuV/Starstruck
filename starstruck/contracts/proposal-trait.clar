;; proposal-trait.clar
;; StarStacks Governance Base trait all upgrade proposals must implement.
;; Inspired by the ExecutorDAO pattern: proposals ARE smart contracts.

(define-trait proposal-trait
  (
    ;; Called by starstacks-core when a proposal is executed.
    ;; sender is the principal that triggered the execution.
    ;; Must return (ok true) on success.
    (execute (principal) (response bool uint))
  )
)
