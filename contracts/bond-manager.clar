;; Bondix Bond Manager Contract
;; Manages bond lifecycle, payments, and investor interactions for tokenized municipal bonds

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-UNAUTHORIZED (err u200))
(define-constant ERR-INVALID-PARAMETERS (err u201))
(define-constant ERR-BOND-NOT-FOUND (err u202))
(define-constant ERR-INSUFFICIENT-BALANCE (err u203))
(define-constant ERR-PAYMENT-NOT-DUE (err u204))
(define-constant ERR-BOND-MATURED (err u205))
(define-constant ERR-INVALID-TRANSFER (err u206))
(define-constant ERR-PAYMENT-FAILED (err u207))
(define-constant ERR-BOND-NOT-MATURE (err u208))

;; Payment frequency in blocks (approximately 6 months)
(define-constant PAYMENT-FREQUENCY u26280)
;; Grace period for payments (approximately 30 days)
(define-constant GRACE-PERIOD u4380)
;; Secondary market fee percentage (1%)
(define-constant MARKET-FEE-RATE u100)

;; Data Variables
(define-data-var total-bonds-managed uint u0)
(define-data-var contract-paused bool false)
(define-data-var emergency-mode bool false)

;; Data Maps
;; Bond payment schedules
(define-map payment-schedules
  { bond-id: uint }
  {
    next-payment-date: uint,
    payment-amount: uint,
    payments-made: uint,
    total-payments-due: uint,
    payment-frequency: uint
  }
)

;; Interest payment history
(define-map payment-history
  { bond-id: uint, payment-id: uint }
  {
    payment-date: uint,
    amount-paid: uint,
    recipients: uint,
    payment-type: (string-utf8 20)
  }
)

;; Secondary market orders
(define-map market-orders
  { order-id: uint }
  {
    seller: principal,
    bond-id: uint,
    amount: uint,
    price-per-unit: uint,
    order-date: uint,
    active: bool,
    filled: bool
  }
)

;; Bond transfer records
(define-map transfer-history
  { transfer-id: uint }
  {
    bond-id: uint,
    from: principal,
    to: principal,
    amount: uint,
    transfer-date: uint,
    transfer-price: uint
  }
)

;; Bond redemption requests
(define-map redemption-requests
  { bond-id: uint, holder: principal }
  {
    amount: uint,
    request-date: uint,
    processed: bool,
    redemption-value: uint
  }
)

;; Data Variables for tracking
(define-data-var next-payment-id uint u1)
(define-data-var next-order-id uint u1)
(define-data-var next-transfer-id uint u1)

;; Private Functions

;; Calculate interest payment amount
(define-private (calculate-interest-payment (bond-id uint) (holder-amount uint))
  (match (contract-call? .bond-issuer get-bond-info bond-id)
    bond-info
      (let (
        (face-value (get face-value bond-info))
        (interest-rate (get interest-rate bond-info))
        (total-supply (get total-supply bond-info))
      )
        ;; Calculate proportional interest: (holder-amount / total-supply) * (face-value * interest-rate / 2)
        (/ (* (* holder-amount face-value) interest-rate) (* total-supply u20000))
      )
    u0
  )
)

;; Check if payment is due
(define-private (is-payment-due (bond-id uint))
  (match (map-get? payment-schedules { bond-id: bond-id })
    schedule-data
      (>= burn-block-height (get next-payment-date schedule-data))
    false
  )
)

;; Check if bond has matured
(define-private (is-bond-mature (bond-id uint))
  (match (contract-call? .bond-issuer get-bond-info bond-id)
    bond-info
      (>= burn-block-height (get maturity-date bond-info))
    false
  )
)

;; Update payment schedule after payment
(define-private (update-payment-schedule (bond-id uint))
  (match (map-get? payment-schedules { bond-id: bond-id })
    current-schedule
      (let (
        (payments-made (+ (get payments-made current-schedule) u1))
        (next-payment (+ (get next-payment-date current-schedule) (get payment-frequency current-schedule)))
      )
        (map-set payment-schedules
          { bond-id: bond-id }
          (merge current-schedule {
            next-payment-date: next-payment,
            payments-made: payments-made
          })
        )
      )
    false
  )
)

;; Validate market order parameters
(define-private (validate-order (bond-id uint) (amount uint) (price uint))
  (and
    (> amount u0)
    (> price u0)
    (is-some (contract-call? .bond-issuer get-bond-info bond-id))
  )
)

;; Public Functions

;; Initialize payment schedule for a bond
(define-public (initialize-payment-schedule (bond-id uint))
  (let (
    (bond-info (unwrap! (contract-call? .bond-issuer get-bond-info bond-id) ERR-BOND-NOT-FOUND))
    (issue-date (get issue-date bond-info))
    (maturity-date (get maturity-date bond-info))
    (face-value (get face-value bond-info))
    (interest-rate (get interest-rate bond-info))
  )
    (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
    (asserts! (is-eq tx-sender (get issuer bond-info)) ERR-UNAUTHORIZED)
    
    (let (
      (bond-duration (- maturity-date issue-date))
      (total-payments (/ bond-duration PAYMENT-FREQUENCY))
      (payment-amount (/ (* face-value interest-rate) (* total-payments u10000)))
    )
      (map-set payment-schedules
        { bond-id: bond-id }
        {
          next-payment-date: (+ issue-date PAYMENT-FREQUENCY),
          payment-amount: payment-amount,
          payments-made: u0,
          total-payments-due: total-payments,
          payment-frequency: PAYMENT-FREQUENCY
        }
      )
      
      (var-set total-bonds-managed (+ (var-get total-bonds-managed) u1))
      (ok true)
    )
  )
)

;; Process interest payment to all bondholders
(define-public (process-interest-payment (bond-id uint) (holders (list 100 principal)))
  (let (
    (payment-id (var-get next-payment-id))
    (bond-info (unwrap! (contract-call? .bond-issuer get-bond-info bond-id) ERR-BOND-NOT-FOUND))
  )
    (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
    (asserts! (is-eq tx-sender (get issuer bond-info)) ERR-UNAUTHORIZED)
    (asserts! (is-payment-due bond-id) ERR-PAYMENT-NOT-DUE)
    (asserts! (not (is-bond-mature bond-id)) ERR-BOND-MATURED)
    
    ;; Record payment in history
    (map-set payment-history
      { bond-id: bond-id, payment-id: payment-id }
      {
        payment-date: burn-block-height,
        amount-paid: (get payment-amount (unwrap! (map-get? payment-schedules { bond-id: bond-id })
                              ERR-BOND-NOT-FOUND
                     )),
        recipients: (len holders),
        payment-type: u"INTEREST"
      }
    )
    
    ;; Update payment schedule
    (update-payment-schedule bond-id)
    
    ;; Increment payment ID
    (var-set next-payment-id (+ payment-id u1))
    
    (ok payment-id)
  )
)

;; Create secondary market sell order
(define-public (create-sell-order (bond-id uint) (amount uint) (price-per-unit uint))
  (let (
    (order-id (var-get next-order-id))
    (holding (unwrap! (contract-call? .bond-issuer get-bond-holding bond-id tx-sender)
                      ERR-INSUFFICIENT-BALANCE))
  )
    (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
    (asserts! (validate-order bond-id amount price-per-unit) ERR-INVALID-PARAMETERS)
    (asserts! (>= (get amount holding) amount) ERR-INSUFFICIENT-BALANCE)
    (asserts! (not (is-bond-mature bond-id)) ERR-BOND-MATURED)
    
    (map-set market-orders
      { order-id: order-id }
      {
        seller: tx-sender,
        bond-id: bond-id,
        amount: amount,
        price-per-unit: price-per-unit,
        order-date: burn-block-height,
        active: true,
        filled: false
      }
    )
    
    (var-set next-order-id (+ order-id u1))
    (ok order-id)
  )
)

;; Execute secondary market purchase
(define-public (execute-market-purchase (order-id uint))
  (let (
    (order (unwrap! (map-get? market-orders { order-id: order-id }) ERR-INVALID-PARAMETERS))
    (transfer-id (var-get next-transfer-id))
    (total-price (* (get amount order) (get price-per-unit order)))
    (market-fee (/ (* total-price MARKET-FEE-RATE) u10000))
  )
    (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
    (asserts! (get active order) ERR-INVALID-PARAMETERS)
    (asserts! (not (get filled order)) ERR-INVALID-PARAMETERS)
    (asserts! (not (is-eq tx-sender (get seller order))) ERR-INVALID-TRANSFER)
    
    ;; Record transfer
    (map-set transfer-history
      { transfer-id: transfer-id }
      {
        bond-id: (get bond-id order),
        from: (get seller order),
        to: tx-sender,
        amount: (get amount order),
        transfer-date: burn-block-height,
        transfer-price: total-price
      }
    )
    
    ;; Mark order as filled
    (map-set market-orders
      { order-id: order-id }
      (merge order { filled: true, active: false })
    )
    
    (var-set next-transfer-id (+ transfer-id u1))
    (ok transfer-id)
  )
)

;; Request bond redemption at maturity
(define-public (request-redemption (bond-id uint) (amount uint))
  (let (
    (bond-info (unwrap! (contract-call? .bond-issuer get-bond-info bond-id) ERR-BOND-NOT-FOUND))
    (holding (unwrap! (contract-call? .bond-issuer get-bond-holding bond-id tx-sender)
                      ERR-INSUFFICIENT-BALANCE))
    (redemption-value (* amount (get face-value bond-info)))
  )
    (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
    (asserts! (is-bond-mature bond-id) ERR-BOND-NOT-MATURE)
    (asserts! (>= (get amount holding) amount) ERR-INSUFFICIENT-BALANCE)
    (asserts! (> amount u0) ERR-INVALID-PARAMETERS)
    
    (map-set redemption-requests
      { bond-id: bond-id, holder: tx-sender }
      {
        amount: amount,
        request-date: burn-block-height,
        processed: false,
        redemption-value: redemption-value
      }
    )
    
    (ok redemption-value)
  )
)

;; Read-only Functions

;; Get payment schedule for a bond
(define-read-only (get-payment-schedule (bond-id uint))
  (map-get? payment-schedules { bond-id: bond-id })
)

;; Get payment history for a bond
(define-read-only (get-payment-history (bond-id uint) (payment-id uint))
  (map-get? payment-history { bond-id: bond-id, payment-id: payment-id })
)

;; Get market order details
(define-read-only (get-market-order (order-id uint))
  (map-get? market-orders { order-id: order-id })
)

;; Get transfer history
(define-read-only (get-transfer-record (transfer-id uint))
  (map-get? transfer-history { transfer-id: transfer-id })
)

;; Get redemption request
(define-read-only (get-redemption-request (bond-id uint) (holder principal))
  (map-get? redemption-requests { bond-id: bond-id, holder: holder })
)

;; Check if bond payment is due
(define-read-only (check-payment-due (bond-id uint))
  (is-payment-due bond-id)
)

;; Get total bonds managed
(define-read-only (get-total-bonds-managed)
  (var-get total-bonds-managed)
)

;; Get next available IDs
(define-read-only (get-next-payment-id)
  (var-get next-payment-id)
)

(define-read-only (get-next-order-id)
  (var-get next-order-id)
)

;; Admin Functions

;; Toggle contract pause
(define-public (toggle-pause)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (var-set contract-paused (not (var-get contract-paused)))
    (ok (var-get contract-paused))
  )
)

;; Emergency mode toggle
(define-public (toggle-emergency-mode)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (var-set emergency-mode (not (var-get emergency-mode)))
    (ok (var-get emergency-mode))
  )
)

