;; Bondix Bond Issuer Contract
;; Handles government bond issuance and issuer management for tokenized municipal bonds

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-INVALID-PARAMETERS (err u101))
(define-constant ERR-BOND-EXISTS (err u102))
(define-constant ERR-ISSUER-NOT-REGISTERED (err u103))
(define-constant ERR-INSUFFICIENT-FUNDS (err u104))
(define-constant ERR-BOND-NOT-FOUND (err u105))
(define-constant ERR-INVALID-MATURITY (err u106))
(define-constant ERR-INVALID-INTEREST-RATE (err u107))

;; Maximum bond duration in blocks (approximately 30 years)
(define-constant MAX-BOND-DURATION u15768000)
;; Minimum investment amount in microSTX (1 STX)
(define-constant MIN-INVESTMENT-AMOUNT u1000000)
;; Maximum interest rate (20%)
(define-constant MAX-INTEREST-RATE u2000)

;; Data Variables
(define-data-var next-bond-id uint u1)
(define-data-var contract-paused bool false)

;; Data Maps
;; Government issuer registration
(define-map issuers
  { issuer: principal }
  {
    name: (string-utf8 100),
    registration-date: uint,
    credit-rating: uint,
    total-bonds-issued: uint,
    active: bool
  }
)

;; Bond information storage
(define-map bonds
  { bond-id: uint }
  {
    issuer: principal,
    name: (string-utf8 100),
    face-value: uint,
    interest-rate: uint,
    maturity-date: uint,
    issue-date: uint,
    total-supply: uint,
    current-supply: uint,
    bond-type: (string-utf8 50),
    active: bool
  }
)

;; Investor bond holdings
(define-map bond-holdings
  { bond-id: uint, holder: principal }
  {
    amount: uint,
    purchase-date: uint,
    purchase-price: uint
  }
)

;; Bond statistics tracking
(define-map bond-stats
  { bond-id: uint }
  {
    total-investors: uint,
    total-raised: uint,
    interest-paid: uint,
    last-payment-date: uint
  }
)

;; Private Functions

;; Validate issuer registration
(define-private (is-valid-issuer (issuer principal))
  (match (map-get? issuers { issuer: issuer })
    issuer-data (get active issuer-data)
    false
  )
)

;; Validate bond parameters
(define-private (validate-bond-params (face-value uint) (interest-rate uint) (maturity-blocks uint))
  (and
    (> face-value u0)
    (<= interest-rate MAX-INTEREST-RATE)
    (> maturity-blocks (+ burn-block-height u144))
    (<= maturity-blocks (+ burn-block-height MAX-BOND-DURATION))
  )
)

;; Calculate bond value at current time
(define-private (calculate-bond-value (bond-id uint) (amount uint))
  (match (map-get? bonds { bond-id: bond-id })
    bond-data
      (let (
        (face-value (get face-value bond-data))
        (interest-rate (get interest-rate bond-data))
        (maturity-date (get maturity-date bond-data))
        (issue-date (get issue-date bond-data))
      )
        ;; Simple calculation: face-value + accrued interest
        (+ face-value (/ (* face-value interest-rate) u10000))
      )
    u0
  )
)

;; Update issuer statistics
(define-private (update-issuer-stats (issuer principal))
  (match (map-get? issuers { issuer: issuer })
    issuer-data
      (map-set issuers
        { issuer: issuer }
        (merge issuer-data { total-bonds-issued: (+ (get total-bonds-issued issuer-data) u1) })
      )
    false
  )
)

;; Public Functions

;; Register a government issuer
(define-public (register-issuer (issuer principal) (name (string-utf8 100)) (credit-rating uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
    (asserts! (and (> (len name) u0) (<= credit-rating u1000)) ERR-INVALID-PARAMETERS)
    
    (map-set issuers
      { issuer: issuer }
      {
        name: name,
        registration-date: burn-block-height,
        credit-rating: credit-rating,
        total-bonds-issued: u0,
        active: true
      }
    )
    (ok true)
  )
)

;; Issue a new bond
(define-public (issue-bond 
    (name (string-utf8 100))
    (face-value uint)
    (interest-rate uint)
    (maturity-blocks uint)
    (total-supply uint)
    (bond-type (string-utf8 50))
  )
  (let (
    (bond-id (var-get next-bond-id))
    (maturity-date (+ burn-block-height maturity-blocks))
  )
    (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
    (asserts! (is-valid-issuer tx-sender) ERR-ISSUER-NOT-REGISTERED)
    (asserts! (validate-bond-params face-value interest-rate maturity-blocks) ERR-INVALID-PARAMETERS)
    (asserts! (> total-supply u0) ERR-INVALID-PARAMETERS)
    (asserts! (> (len name) u0) ERR-INVALID-PARAMETERS)
    
    ;; Create bond record
    (map-set bonds
      { bond-id: bond-id }
      {
        issuer: tx-sender,
        name: name,
        face-value: face-value,
        interest-rate: interest-rate,
        maturity-date: maturity-date,
        issue-date: burn-block-height,
        total-supply: total-supply,
        current-supply: total-supply,
        bond-type: bond-type,
        active: true
      }
    )
    
    ;; Initialize bond statistics
    (map-set bond-stats
      { bond-id: bond-id }
      {
        total-investors: u0,
        total-raised: u0,
        interest-paid: u0,
        last-payment-date: u0
      }
    )
    
    ;; Update issuer statistics
    (update-issuer-stats tx-sender)
    
    ;; Increment bond ID for next issuance
    (var-set next-bond-id (+ bond-id u1))
    
    (ok bond-id)
  )
)

;; Purchase bond tokens
(define-public (purchase-bond (bond-id uint) (amount uint))
  (let (
    (bond-data (unwrap! (map-get? bonds { bond-id: bond-id }) ERR-BOND-NOT-FOUND))
    (current-holding (default-to { amount: u0, purchase-date: u0, purchase-price: u0 }
                     (map-get? bond-holdings { bond-id: bond-id, holder: tx-sender })))
  )
    (asserts! (not (var-get contract-paused)) ERR-UNAUTHORIZED)
    (asserts! (get active bond-data) ERR-BOND-NOT-FOUND)
    (asserts! (>= (get current-supply bond-data) amount) ERR-INSUFFICIENT-FUNDS)
    (asserts! (>= amount MIN-INVESTMENT-AMOUNT) ERR-INVALID-PARAMETERS)
    (asserts! (>= (get maturity-date bond-data) burn-block-height) ERR-INVALID-MATURITY)
    
    (let (
      (purchase-price (* amount (get face-value bond-data)))
      (new-amount (+ (get amount current-holding) amount))
    )
      ;; Update bond supply
      (map-set bonds
        { bond-id: bond-id }
        (merge bond-data { current-supply: (- (get current-supply bond-data) amount) })
      )
      
      ;; Update or create holding record
      (map-set bond-holdings
        { bond-id: bond-id, holder: tx-sender }
        {
          amount: new-amount,
          purchase-date: burn-block-height,
          purchase-price: purchase-price
        }
      )
      
      ;; Update bond statistics
      (let (
        (current-stats (unwrap! (map-get? bond-stats { bond-id: bond-id }) ERR-BOND-NOT-FOUND))
        (is-new-investor (is-eq (get amount current-holding) u0))
      )
        (map-set bond-stats
          { bond-id: bond-id }
          (merge current-stats {
            total-investors: (if is-new-investor 
                            (+ (get total-investors current-stats) u1)
                            (get total-investors current-stats)),
            total-raised: (+ (get total-raised current-stats) purchase-price)
          })
        )
      )
      
      (ok true)
    )
  )
)

;; Read-only Functions

;; Get bond information
(define-read-only (get-bond-info (bond-id uint))
  (map-get? bonds { bond-id: bond-id })
)

;; Get issuer information
(define-read-only (get-issuer-info (issuer principal))
  (map-get? issuers { issuer: issuer })
)

;; Get bond holdings for a specific holder
(define-read-only (get-bond-holding (bond-id uint) (holder principal))
  (map-get? bond-holdings { bond-id: bond-id, holder: holder })
)

;; Get bond statistics
(define-read-only (get-bond-statistics (bond-id uint))
  (map-get? bond-stats { bond-id: bond-id })
)

;; Get next bond ID
(define-read-only (get-next-bond-id)
  (var-get next-bond-id)
)

;; Admin function to pause contract
(define-public (toggle-contract-pause)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (var-set contract-paused (not (var-get contract-paused)))
    (ok (var-get contract-paused))
  )
)

