;; extensiontrait.clar
;; Any contract that acts as an authorized StarStacks extension must implement this.
;; The core uses this to verify callback legitimacy.

(define-trait extension-trait
  (
    ;; Called by core to verify the extension is still operational.
    ;; Returns (ok true) if healthy.
    (callback (principal (buff 34)) (response bool uint))
  )
)
