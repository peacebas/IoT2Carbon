;; IoT2Carbon - Autonomous Carbon Sequestration Verification Network
;; Smart contract for real-time carbon footprint tracking and tokenized offset trading

;; Constants
(define-constant PROTOCOL_ADMIN tx-sender)
(define-constant ERR_ACCESS_DENIED (err u100))
(define-constant ERR_INVALID_PROBE (err u101))
(define-constant ERR_INSUFFICIENT_METRICS (err u102))
(define-constant ERR_TOKEN_NOT_FOUND (err u103))
(define-constant ERR_INVALID_QUANTITY (err u104))
(define-constant ERR_TRANSACTION_FAILED (err u105))

;; Data Variables
(define-data-var next-token-sequence uint u1)
(define-data-var next-probe-sequence uint u1)

;; Data Maps
(define-map environmental-probes 
    uint 
    {
        controller: principal,
        probe-category: (string-ascii 64),
        geographic-coordinates: (string-ascii 128),
        carbon-threshold: uint,
        operational: bool,
        authenticated: bool
    }
)

(define-map atmospheric-measurements
    {probe-sequence: uint, measurement-epoch: uint}
    {
        carbon-offset: uint,
        ambient-temperature: uint,
        moisture-level: uint,
        validated: bool
    }
)

(define-map offset-tokens
    uint
    {
        holder: principal,
        token-weight: uint,
        originating-probe: uint,
        generation-epoch: uint,
        market-value: uint,
        tradeable: bool,
        certified: bool
    }
)

(define-map participant-portfolios principal uint)

;; Private Functions
(define-private (is-protocol-admin)
    (is-eq tx-sender PROTOCOL_ADMIN)
)

;; Public Functions

;; Deploy new environmental monitoring probe
(define-public (deploy-probe (probe-category (string-ascii 64)) (geographic-coordinates (string-ascii 128)) (carbon-threshold uint))
    (let
        (
            (probe-sequence (var-get next-probe-sequence))
        )
        (map-set environmental-probes probe-sequence
            {
                controller: tx-sender,
                probe-category: probe-category,
                geographic-coordinates: geographic-coordinates,
                carbon-threshold: carbon-threshold,
                operational: true,
                authenticated: false
            }
        )
        (var-set next-probe-sequence (+ probe-sequence u1))
        (ok probe-sequence)
    )
)

;; Authenticate probe (protocol admin only)
(define-public (authenticate-probe (probe-sequence uint))
    (begin
        (asserts! (is-protocol-admin) ERR_ACCESS_DENIED)
        (match (map-get? environmental-probes probe-sequence)
            probe-metadata
            (begin
                (map-set environmental-probes probe-sequence
                    (merge probe-metadata {authenticated: true})
                )
                (ok true)
            )
            ERR_INVALID_PROBE
        )
    )
)

;; Record atmospheric measurement
(define-public (record-measurement (probe-sequence uint) (carbon-offset uint) (ambient-temperature uint) (moisture-level uint))
    (let
        (
            (probe-metadata-opt (map-get? environmental-probes probe-sequence))
            (measurement-epoch (unwrap-panic (get-block-info? time (- block-height u1))))
        )
        (match probe-metadata-opt
            probe-metadata
            (begin
                (asserts! (is-eq (get controller probe-metadata) tx-sender) ERR_ACCESS_DENIED)
                (asserts! (get operational probe-metadata) ERR_INVALID_PROBE)
                (map-set atmospheric-measurements 
                    {probe-sequence: probe-sequence, measurement-epoch: measurement-epoch}
                    {
                        carbon-offset: carbon-offset,
                        ambient-temperature: ambient-temperature,
                        moisture-level: moisture-level,
                        validated: (get authenticated probe-metadata)
                    }
                )
                ;; Automatic token minting when threshold exceeded
                (if (>= carbon-offset (get carbon-threshold probe-metadata))
                    (match (mint-offset-token probe-sequence carbon-offset)
                        success (ok true)
                        error (err error)
                    )
                    (ok true)
                )
            )
            ERR_INVALID_PROBE
        )
    )
)

;; Mint carbon offset tokens
(define-private (mint-offset-token (probe-sequence uint) (carbon-quantity uint))
    (let
        (
            (token-sequence (var-get next-token-sequence))
            (probe-metadata-opt (map-get? environmental-probes probe-sequence))
            (generation-epoch (unwrap-panic (get-block-info? time (- block-height u1))))
        )
        (match probe-metadata-opt
            probe-metadata
            (let
                (
                    (token-weight (/ carbon-quantity u1000)) ;; 1 token per 1000 units carbon offset
                    (holder (get controller probe-metadata))
                )
                (map-set offset-tokens token-sequence
                    {
                        holder: holder,
                        token-weight: token-weight,
                        originating-probe: probe-sequence,
                        generation-epoch: generation-epoch,
                        market-value: u0,
                        tradeable: false,
                        certified: (get authenticated probe-metadata)
                    }
                )
                ;; Update participant portfolio
                (map-set participant-portfolios holder 
                    (+ (default-to u0 (map-get? participant-portfolios holder)) token-weight)
                )
                (var-set next-token-sequence (+ token-sequence u1))
                (ok token-sequence)
            )
            ERR_INVALID_PROBE
        )
    )
)

;; List offset tokens for trading
(define-public (list-token-for-trade (token-sequence uint) (market-value uint))
    (match (map-get? offset-tokens token-sequence)
        token-metadata
        (begin
            (asserts! (is-eq (get holder token-metadata) tx-sender) ERR_ACCESS_DENIED)
            (asserts! (> market-value u0) ERR_INVALID_QUANTITY)
            (map-set offset-tokens token-sequence
                (merge token-metadata {market-value: market-value, tradeable: true})
            )
            (ok true)
        )
        ERR_TOKEN_NOT_FOUND
    )
)

;; Acquire carbon offset tokens
(define-public (acquire-offset-token (token-sequence uint))
    (match (map-get? offset-tokens token-sequence)
        token-metadata
        (let
            (
                (current-holder (get holder token-metadata))
                (market-value (get market-value token-metadata))
                (token-weight (get token-weight token-metadata))
            )
            (asserts! (get tradeable token-metadata) ERR_INVALID_QUANTITY)
            (asserts! (not (is-eq current-holder tx-sender)) ERR_ACCESS_DENIED)
            
            ;; Transfer STX payment (simplified - production requires proper STX transfer)
            ;; Update token ownership
            (map-set offset-tokens token-sequence
                (merge token-metadata {holder: tx-sender, tradeable: false, market-value: u0})
            )
            
            ;; Update participant portfolios
            (map-set participant-portfolios current-holder
                (- (default-to u0 (map-get? participant-portfolios current-holder)) token-weight)
            )
            (map-set participant-portfolios tx-sender
                (+ (default-to u0 (map-get? participant-portfolios tx-sender)) token-weight)
            )
            
            (ok true)
        )
        ERR_TOKEN_NOT_FOUND
    )
)

;; Read-only functions

(define-read-only (get-probe-metadata (probe-sequence uint))
    (map-get? environmental-probes probe-sequence)
)

(define-read-only (get-atmospheric-measurement (probe-sequence uint) (measurement-epoch uint))
    (map-get? atmospheric-measurements {probe-sequence: probe-sequence, measurement-epoch: measurement-epoch})
)

(define-read-only (get-offset-token (token-sequence uint))
    (map-get? offset-tokens token-sequence)
)

(define-read-only (get-participant-portfolio (participant principal))
    (default-to u0 (map-get? participant-portfolios participant))
)

(define-read-only (get-next-token-sequence)
    (var-get next-token-sequence)
)

(define-read-only (get-next-probe-sequence)
    (var-get next-probe-sequence)
)