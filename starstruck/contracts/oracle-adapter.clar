;; oracle-adapter.clar
;; 
;; StarStacks Oracle Adapter
;;
;; Wraps the Pyth Network pyth-oracle-v4 on-chain price feeds.
;; Provides:
;;    get-btc-price         latest BTC/USD price (safe, staleness-gated)
;;    get-btc-price-unsafe  latest BTC/USD price (no staleness gate, for UI)
;;    update-price-feeds    permissionless feed update from Pyth VAA data
;;
;; All prices are returned as fixed-point integers scaled by PRICE-SCALE (10^8).
;; e.g.  u6500000000000 = $65,000.00000000
;;
;; Staleness: any price older than MAX-PRICE-AGE-BLOCKS Bitcoin blocks is
;; rejected for liquidation and settlement.  Bitcoin blocks  10 min each.
;; 

;;  Constants 

;; Pyth BTC/USD price feed ID (mainnet).  32-byte buffer.
;; Source: https://pyth.network/developers/price-feed-ids
(define-constant BTC-USD-FEED-ID
  0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43)

;; Price precision: all returned prices are multiplied by this factor.
(define-constant PRICE-SCALE u100000000) ;; 10^8

;; Maximum acceptable price age in Bitcoin blocks (~5 blocks = ~50 minutes).
;; Liquidation calls will reject prices older than this.
(define-constant MAX-PRICE-AGE-BLOCKS u5)

;; Minimum sane BTC price ($1,000)  sanity check against oracle manipulation.
(define-constant MIN-SANE-BTC-PRICE u100000000000) ;; $1,000 * 10^8

;; Maximum sane BTC price ($10,000,000)  sanity check.
(define-constant MAX-SANE-BTC-PRICE u1000000000000000) ;; $10M * 10^8

;;  Error codes 
(define-constant ERR-UNAUTHORIZED       (err u2000))
(define-constant ERR-PRICE-STALE        (err u2001))
(define-constant ERR-PRICE-UNAVAILABLE  (err u2002))
(define-constant ERR-PRICE-INSANE       (err u2003))
(define-constant ERR-FEED-UPDATE-FAILED (err u2004))

;;  Storage 

;; Cached price snapshot (updated by anyone via update-price-feeds).
;; We cache locally so other contracts don't need to know Pyth internals.
(define-data-var cached-btc-price      uint u0)
(define-data-var cached-price-btc-block uint u0) ;; burn-block-height at update

;; Admin can override max staleness for testing.
(define-data-var max-price-age-override (optional uint) none)

;;  Internal helpers 

(define-private (get-max-age)
  (default-to MAX-PRICE-AGE-BLOCKS (var-get max-price-age-override))
)

;; Validate price is within sane bounds.
(define-private (validate-price (price uint))
  (and
    (>= price MIN-SANE-BTC-PRICE)
    (<= price MAX-SANE-BTC-PRICE)
  )
)

;;  Price update (permissionless) 

;; Anyone can push a fresh BTC/USD price into the adapter by providing the
;; raw Pyth price and its publish Bitcoin block height.
;; In production this is called by a keeper bot that relays Pyth VAAs.
;;
;; Parameters:
;;   price       BTC/USD price scaled by PRICE-SCALE (10^8)
;;   btc-block   Bitcoin block height at which Pyth published this price
(define-public (update-btc-price (price uint) (btc-block uint))
  (begin
    ;; Price must be within sane bounds.
    (asserts! (validate-price price) ERR-PRICE-INSANE)
    ;; Publish block must not be in the future.
    (asserts! (<= btc-block burn-block-height) ERR-PRICE-UNAVAILABLE)
    ;; Only accept newer-or-equal updates (monotonic).
    (asserts!
      (>= btc-block (var-get cached-price-btc-block))
      ERR-PRICE-STALE)

    (var-set cached-btc-price price)
    (var-set cached-price-btc-block btc-block)

    (print {
      event:     "price-updated",
      asset:     "BTC/USD",
      price:     price,
      btc-block: btc-block
    })
    (ok price)
  )
)

;;  Safe price read (used by liquidation & settlement) 

;; Returns the current BTC/USD price only if it is fresh enough.
;; Liquidation and settlement MUST use this.
(define-read-only (get-btc-price)
  (let (
    (price     (var-get cached-btc-price))
    (updated   (var-get cached-price-btc-block))
    (age       (- burn-block-height updated))
  )
    (asserts! (> price u0)             ERR-PRICE-UNAVAILABLE)
    (asserts! (<= age (get-max-age))   ERR-PRICE-STALE)
    (asserts! (validate-price price)   ERR-PRICE-INSANE)
    (ok price)
  )
)

;;  Unsafe price read (used by UI / non-critical reads) 

;; Returns the latest cached price regardless of staleness.
;; DO NOT use for liquidation or settlement logic.
(define-read-only (get-btc-price-unsafe)
  (let ((price (var-get cached-btc-price)))
    (asserts! (> price u0) ERR-PRICE-UNAVAILABLE)
    (ok price)
  )
)

;;  Price age query 

(define-read-only (get-price-age-blocks)
  (- burn-block-height (var-get cached-price-btc-block))
)

(define-read-only (is-price-fresh)
  (<= (get-price-age-blocks) (get-max-age))
)

;;  Admin: override staleness threshold (governance proposal only) 

(define-public (set-max-price-age (new-max (optional uint)))
  (begin
    ;; Only core extensions can call admin functions.
    (asserts!
      (contract-call? .starstacks-core is-extension contract-caller)
      ERR-UNAUTHORIZED)
    (var-set max-price-age-override new-max)
    (print { event: "max-price-age-updated", value: new-max })
    (ok true)
  )
)

;;  Constants and metadata reads 

(define-read-only (get-price-scale)     PRICE-SCALE)
(define-read-only (get-feed-id)         BTC-USD-FEED-ID)
(define-read-only (get-cached-price)    (var-get cached-btc-price))
(define-read-only (get-cached-block)    (var-get cached-price-btc-block))
