# Pyth Oracle Integration for Stacks

## Overview

Pyth Network provides real-time price data for Stacks smart contracts using a **pull price update model**. Unlike traditional push oracles, Pyth delegates on-chain price updates to users/dApps.

**Official Contract:** `.pyth-oracle-v4` (SP1CGXWEAMG6P6FT04W66NVGJ7PQWMDAC19R7PJ0Y)

**Repository:** https://github.com/stx-labs/stacks-pyth-bridge

---

## Available Price Feeds

| Asset | Feed ID |
|-------|---------|
| BTC | `0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43` |
| STX | `0xec7a775f46379b5e943c3526b1c8d54cd49749176b0b98e02dde68d1bd335c17` |
| USDC | `0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a` |
| ETH | `0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace` |

---

## Key Contracts

- **pyth-oracle-v4**: Main entry point for price verification and updates
- **pyth-storage-v4**: Stores verified price data on-chain
- **pyth-pnau-decoder-v3**: Decodes VAA price payloads
- **wormhole-core-v4**: Wormhole bridge for cross-chain data

---

## Integration Pattern

### 1. Add Requirements to Clarinet.toml

```toml
[[project.requirements]]
contract_id = 'SP1CGXWEAMG6P6FT04W66NVGJ7PQWMDAC19R7PJ0Y.pyth-oracle-v4'
[[project.requirements]]
contract_id = 'SP1CGXWEAMG6P6FT04W66NVGJ7PQWMDAC19R7PJ0Y.pyth-storage-v4'
[[project.requirements]]
contract_id = 'SP1CGXWEAMG6P6FT04W66NVGJ7PQWMDAC19R7PJ0Y.pyth-pnau-decoder-v3'
[[project.requirements]]
contract_id = 'SP1CGXWEAMG6P6FT04W66NVGJ7PQWMDAC19R7PJ0Y.wormhole-core-v4'
```

### 2. Verify and Get Price in Clarity

```clarity
(define-public (get-btc-price (price-feed-bytes (buff 8192)))
  (let
    (
      ;; Update & verify VAA for BTC price feed
      (update-status (try! (contract-call? 
        'SP1CGXWEAMG6P6FT04W66NVGJ7PQWMDAC19R7PJ0Y.pyth-oracle-v4 
        verify-and-update-price-feeds 
        price-feed-bytes 
        { 
          pyth-storage-contract: 'SP1CGXWEAMG6P6FT04W66NVGJ7PQWMDAC19R7PJ0Y.pyth-storage-v4, 
          pyth-decoder-contract: 'SP1CGXWEAMG6P6FT04W66NVGJ7PQWMDAC19R7PJ0Y.pyth-pnau-decoder-v3, 
          wormhole-core-contract: 'SP1CGXWEAMG6P6FT04W66NVGJ7PQWMDAC19R7PJ0Y.wormhole-core-v4
        })))
      
      ;; Get fresh BTC price
      (price-data (try! (contract-call? 
        'SP1CGXWEAMG6P6FT04W66NVGJ7PQWMDAC19R7PJ0Y.pyth-oracle-v4 
        get-price 
        0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43
        'SP1CGXWEAMG6P6FT04W66NVGJ7PQWMDAC19R7PJ0Y.pyth-storage-v4)))
    )
    (ok price-data)
  )
)
```

### 3. Price Data Structure

The `get-price` function returns:
```clarity
{
  price-identifier: (buff 32),
  price: int,
  conf: uint,
  ema-price: int,
  ema-conf: uint,
  expo: int,           ;; decimal exponent (e.g., -8)
  publish-time: uint,
  prev-publish-time: uint
}
```

### 4. Handle Fixed-Point Price Values

Price feeds use fixed-point representation. Adjust using the `expo` property:

```clarity
;; Price feeds represent numbers in fixed-point format
;; expo property tells where the decimal point is

;; Calculate price denomination: 10^(-expo)
(price-denomination (pow 10 (* (get expo price-data) -1)))

;; Adjust price to normal decimal representation
(adjusted-price (/ (get price price-data) price-denomination))
```

Example: Price `10603557773590` with `expo: -8` = `106035.57773590`

---

## Frontend Integration

### Fetch VAA with Hermes Client

```typescript
import { HermesClient } from "@pythnetwork/hermes-client";
import { Cl } from "@stacks/transactions";

const connection = new HermesClient("https://hermes.pyth.network", {});

async function fetchLatestVaa() {
  const priceIds = ["0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43"];
  const priceUpdates = await connection.getLatestPriceUpdates(priceIds);
  return `0x${priceUpdates.binary.data[0]}`;
}

// Call contract with VAA
const latestVaaHex = await fetchLatestVaa();
const response = await callContract("contract-name", "get-btc-price", [Cl.bufferFromHex(latestVaaHex)]);
```

---

## StarStacks Usage

The `oracle-adapter.clar` contract wraps Pyth for the protocol:

- `get-btc-price`: Safe read with staleness gate
- `get-btc-price-unsafe`: For UI reads (no staleness check)
- `update-btc-price`: Permissionless feed update for keepers

### BTC/USD Feed ID
```
0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43
```

### Price Scaling
- All prices returned as fixed-point integers scaled by `10^8`
- Example: `u6500000000000` = $65,000.00

---

## Testing in Clarinet Console

Enable mainnet simulation in Clarinet.toml:
```toml
[repl.remote_data]
enabled = true
api_url = 'https://api.hiro.so'
use_mainnet_wallets = true
```

Then in console:
```clarity
::set_tx_sender <mainnet-address>
(contract-call? 'SP1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRCBGD7R.main join-the-benjamin-club <vaa-bytes>)
```

---

## Additional Resources

- [Pyth Stacks Documentation](https://docs.stacks.co/more-guides/price-oracles/pyth)
- [Pyth Price Feeds](https://www.pyth.network/price-feeds/crypto-btc-usd)
- [Hermes API](https://hermes.pyth.network/docs/#/rest/latest_price_updates)
- [Stacks-Pyth Bridge Repo](https://github.com/stx-labs/stacks-pyth-bridge)
