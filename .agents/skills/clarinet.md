# Clarinet Development Skill

## Overview
Clarinet is a development framework and Clarity runtime for Stacks smart contract development. It provides syntax checking, type checking, linting, REPL console, debugging, and devnet support.

## Installation
```bash
wget -nv https://github.com/stx-labs/clarinet/releases/latest/download/clarinet-linux-x64-glibc.tar.gz -O clarinet-linux-x64.tar.gz
tar -xf clarinet-linux-x64.tar.gz
chmod +x ./clarinet
mv ./clarinet /usr/local/bin
```

## Key Commands

### Project Setup
```bash
clarinet new <project-name>  # Create new project
clarinet contracts new <name>  # Generate new contract
```

### Validation & Analysis
```bash
clarinet check  # Syntax, type checking, and lint
clarinet lsp   # Language Server for IDE support
clarinet dap   # Debug Adapter for breakpoints
clarinet format # Format clarity code
```

### Local Development
```bash
clarinet console  # REPL for interactive testing
clarinet devnet start  # Start local devnet
clarinet devnet stop   # Stop devnet
```

### Testing
```bash
npm install
npm test
```

## Project Structure
```
project/
├── Clarinet.toml      # Project manifest
├── contracts/         # Clarity smart contracts
│   ├── governance/    # Governance traits and proposals
│   ├── core/          # Core contracts
│   └── periphery/     # Peripheral contracts
├── settings/          # Network configs
│   ├── Devnet.toml    # Local devnet settings
│   ├── Testnet.toml   # Testnet settings
│   └── Mainnet.toml   # Mainnet settings
├── tests/             # TypeScript tests
└── .vscode/           # VSCode settings
```

## Clarinet.toml Example
```toml
[project]
name = "project-name"
description = "Project description"
clarity_version = 3
epoch = "3.0"

[contracts.my-contract]
path = "contracts/my-contract.clar"
```

## Common Patterns

### DeFi Lending Pattern
```clarity
(define-map deposits { owner: principal } { amount: uint })

(define-public (deposit (amount uint))
  (let ((balance (default-to u0 (get amount (map-get? deposits { owner: tx-sender })))))
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (map-set deposits { owner: tx-sender } { amount: (+ balance amount) })
    (ok true)))
```

### Batch Transfer Pattern
```clarity
(define-private (send-stx (recipient { to: principal, ustx: uint }))
  (stx-transfer? (get ustx recipient) tx-sender (get to recipient)))

(define-private (check-err (result (response bool uint)) (prior (response bool uint)))
  (match prior ok-value result err-value (err err-value)))
```

### Pyth Oracle Integration
```clarity
;; Read BTC price from Pyth (scaled by 10^8)
(contract-call? .pyth-oracle-v4 get-btc-price)

;; Price staleness check
(constant MAX-PRICE-AGE-BLOCKS u5)  ;; ~50 minutes
```

### Proof of Transfer (PoX) Integration
```clarity
;; Register for stacking via pox-4
(contract-call? .pox-4 stack-stx amount unlock-burn-height)
```

## Error Handling
```clarity
(define-constant ERR_NOT_OWNER (err u100))
(define-constant ERR_INSUFFICIENT_FUNDS (err u101))

(define-public (withdraw (amount uint))
  (let ((balance (default-to u0 (get amount (map-get? balances { owner: tx-sender })))))
    (asserts! (>= balance amount) ERR_INSUFFICIENT_FUNDS)
    (map-set balances { owner: tx-sender } { amount: (- balance amount) })
    (try! (stx-transfer? amount tx-sender tx-sender))
    (ok true)))
```

## Network Mnemonics
Use valid 24-word BIP39 mnemonics for test accounts:
```toml
[accounts.deployer]
mnemonic = "twice kind fence tip vanish import flora remix screen family comfortable generate exit official native arcade commit steel smell mock agent team crucial swim crowd"
balance = 100000000
```

## Debugging Tips
1. Use `clarinet console` for interactive testing
2. Enable VSCode extension for inline errors
3. Use `clarinet format` for consistent code style
4. Check with `clarinet check` before committing

## External Resources
- Docs: https://docs.stacks.co/clarinet
- GitHub: https://github.com/stx-labs/clarinet
- Clarity Reference: https://docs.stacks.co/references/clarityref
