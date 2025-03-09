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