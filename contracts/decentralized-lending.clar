;; Title: Decentralized Lending Protocol
;; Summary: A secure lending protocol enabling sBTC-collateralized loans with liquidation mechanisms
;; Description: This contract implements a lending protocol where users can:
;;   - Deposit sBTC as collateral
;;   - Borrow against their collateral
;;   - Repay loans
;;   - Participate in liquidations of under-collateralized positions
;; The protocol maintains a minimum collateralization ratio and includes
;; safety mechanisms like pause functionality and liquidation thresholds.

;; Error Codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INSUFFICIENT-BALANCE (err u101))
(define-constant ERR-INSUFFICIENT-COLLATERAL (err u102))
(define-constant ERR-INVALID-AMOUNT (err u103))
(define-constant ERR-ALREADY-INITIALIZED (err u104))
(define-constant ERR-NOT-INITIALIZED (err u105))
(define-constant ERR-LIQUIDATION-FAILED (err u106))

;; Protocol Parameters
(define-constant MIN-COLLATERAL-RATIO u150)  ;; 150% minimum collateralization ratio
(define-constant MAX-INTEREST-RATE u10000)  ;; 100% in basis points
(define-constant MIN-INTEREST-RATE u100)    ;; 1% in basis points
(define-constant MAX-LIQUIDATION-THRESHOLD u9500)  ;; 95% in basis points
(define-constant MIN-LIQUIDATION-THRESHOLD u7000)  ;; 70% in basis points
(define-constant MAX-REWARD-MULTIPLIER u120)  ;; 120% maximum reward multiplier

;; Protocol State
(define-data-var contract-owner principal tx-sender)
(define-data-var protocol-paused bool false)
(define-data-var total-deposits uint u0)
(define-data-var total-borrows uint u0)
(define-data-var interest-rate uint u500)  ;; 5% APR in basis points
(define-data-var liquidation-threshold uint u8000)  ;; 80% threshold in basis points
(define-data-var allowed-token principal 'SP000000000000000000002Q6VF78.token)


;; Storage Maps
(define-map user-deposits 
    { user: principal } 
    { amount: uint }
)

(define-map user-borrows 
    { user: principal } 
    { 
        amount: uint, 
        collateral: uint 
    }
)

(define-map liquidator-rewards 
    { liquidator: principal } 
    { amount: uint }
)

;; SIP-010 Fungible Token Interface
(define-trait sip-010-trait
    (
        (transfer (uint principal principal (optional (buff 34))) (response bool uint))
        (get-balance (principal) (response uint uint))
    )
)

;; Authorization
(define-private (is-contract-owner)
    (is-eq tx-sender (var-get contract-owner))
)

;; Validate token contract
(define-private (is-valid-token (token-contract <sip-010-trait>))
    (is-eq (contract-of token-contract) (var-get allowed-token))
)

;; Safe arithmetic operations
(define-private (safe-subtract (a uint) (b uint))
    (ok (if (>= a b) (- a b) u0))
)

(define-private (safe-add (a uint) (b uint))
    (let ((sum (+ a b)))
        (asserts! (>= sum a) (err u401))  ;; Check for overflow
        (ok sum)
    )
)

;; Safe multiplication with overflow check
(define-private (safe-multiply (a uint) (b uint))
    (let ((product (* a b)))
        (asserts! (or (is-eq a u0) (is-eq (/ product a) b)) (err u402))  ;; Check for overflow
        (ok product)
    )
)

;; Core Protocol Functions

;; Initialize the protocol with the specified token contract
(define-public (initialize (token-contract <sip-010-trait>))
    (begin
        (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
        (ok true)
    )
)

;; Deposit sBTC as collateral
(define-public (deposit-collateral (token-contract <sip-010-trait>) (amount uint))
    (let
        (
            (sender tx-sender)
            (current-deposit (default-to { amount: u0 } (map-get? user-deposits { user: sender })))
        )
        (asserts! (> amount u0) ERR-INVALID-AMOUNT)
        (asserts! (not (var-get protocol-paused)) ERR-NOT-INITIALIZED)
        (asserts! (is-valid-token token-contract) ERR-NOT-AUTHORIZED)
        
        (match (contract-call? token-contract transfer amount sender (as-contract tx-sender) none)
            success
                (begin
                    (map-set user-deposits
                        { user: sender }
                        { amount: (+ amount (get amount current-deposit)) }
                    )
                    (var-set total-deposits (+ (var-get total-deposits) amount))
                    (ok true)
                )
            error (err u101)
        )
    )
)

;; Borrow against deposited collateral
(define-public (borrow (token-contract <sip-010-trait>) (amount uint))
    (let
        (
            (sender tx-sender)
            (user-deposit (default-to { amount: u0 } (map-get? user-deposits { user: sender })))
            (user-borrow (default-to { amount: u0, collateral: u0 } (map-get? user-borrows { user: sender })))
            (collateral-value (get amount user-deposit))
            (borrow-value (+ amount (get amount user-borrow)))
        )
        (asserts! (> amount u0) ERR-INVALID-AMOUNT)
        (asserts! (not (var-get protocol-paused)) ERR-NOT-INITIALIZED)
        (asserts! (is-collateral-sufficient collateral-value borrow-value) ERR-INSUFFICIENT-COLLATERAL)
        
        (map-set user-borrows
            { user: sender }
            { amount: borrow-value, collateral: collateral-value }
        )
        (var-set total-borrows (+ (var-get total-borrows) amount))
        (ok true)
    )
)

;; Repay borrowed amount
(define-public (repay (token-contract <sip-010-trait>) (amount uint))
    (let
        (
            (sender tx-sender)
            (user-borrow (default-to { amount: u0, collateral: u0 } (map-get? user-borrows { user: sender })))
            (borrow-amount (get amount user-borrow))
        )
        (asserts! (>= borrow-amount amount) ERR-INVALID-AMOUNT)
        (asserts! (is-valid-token token-contract) ERR-NOT-AUTHORIZED)
        
        (match (contract-call? token-contract transfer amount sender (as-contract tx-sender) none)
            success
                (begin
                    (map-set user-borrows
                        { user: sender }
                        { amount: (- borrow-amount amount), collateral: (get collateral user-borrow) }
                    )
                    (var-set total-borrows (- (var-get total-borrows) amount))
                    (ok true)
                )
			error (err u101)

        )
    )
)

;; Liquidation Functions

;; Liquidate an under-collateralized position
(define-public (liquidate (token-contract <sip-010-trait>) (user principal) (amount uint))
    (let
        (
            (liquidator tx-sender)
            (user-borrow (default-to { amount: u0, collateral: u0 } (map-get? user-borrows { user: user })))
            (borrow-amount (get amount user-borrow))
            (collateral-amount (get collateral user-borrow))
        )
        (asserts! (is-valid-token token-contract) ERR-NOT-AUTHORIZED)
        (asserts! (can-liquidate user borrow-amount collateral-amount) ERR-LIQUIDATION-FAILED)
        (asserts! (<= amount borrow-amount) ERR-INVALID-AMOUNT)
        
        (match (contract-call? token-contract transfer amount liquidator (as-contract tx-sender) none)
            success
                (begin
                    (let
                        (
                            (reward (calculate-liquidation-reward amount collateral-amount))
                            (current-rewards (default-to { amount: u0 } (map-get? liquidator-rewards { liquidator: liquidator })))
                        )
                        (map-set liquidator-rewards
                            { liquidator: liquidator }
                            { amount: (+ (get amount current-rewards) reward) }
                        )
                        (map-set user-borrows
                            { user: user }
                            { amount: (- borrow-amount amount), collateral: (- collateral-amount reward) }
                        )
                        (ok true)
                    )
                )
            error (err u101)
        )
    )
)

;; Claim accumulated liquidation rewards
(define-public (claim-rewards (token-contract <sip-010-trait>))
    (let
        (
            (liquidator tx-sender)
            (rewards (default-to { amount: u0 } (map-get? liquidator-rewards { liquidator: liquidator })))
            (reward-amount (get amount rewards))
        )
        (asserts! (> reward-amount u0) ERR-INSUFFICIENT-BALANCE)
        
        (map-set liquidator-rewards
            { liquidator: liquidator }
            { amount: u0 }
        )
        (ok true)
    )
)