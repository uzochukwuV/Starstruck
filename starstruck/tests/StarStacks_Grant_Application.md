# StarStacks Perpetual Market — Stacks Endowment Getting Started Application

---

## Step 1: Applicant Identity

- **Applicant type:** Individual
- **Jurisdiction:** US
- **Legal name:** victor ezealor
- **Primary contact name:** victor ezealor
- **Primary contact email:** vic.ezealor@gmail.com
- **Primary contact role:** Founder

---

## Step 2: Project

- **Project name:** StarStacks Perpetual Market
- **Website or repo:** *(add if available)*
- **Primary category:** DeFi
- **Secondary category:** DeFi - Trading

**Project Description:**

StarStacks is a perpetual futures DEX on Stacks that hedges only the *net* directional imbalance between longs and shorts — using **sBTC as the settlement and collateral asset** and **Pyth Network's `pyth-oracle-v4`** for on-chain BTC/USD pricing.

**Core Contracts (10 deployed):**

| Contract | Purpose |
|----------|---------|
| `starstacks-core.clar` | ExecutorDAO core; owns all extension authorization |
| `oracle-adapter.clar` | Wraps Pyth BTC/USD feed with staleness gate (≤5 BTC blocks) |
| `collateral-vault.clar` | sBTC custody + **Dual Stacking rewards integration** |
| `sbtc-dex.clar` | Constant-product AMM for internal hedge swaps |
| `perpetual-engine.clar` | Positions, net OI tracking, funding rate accumulation |
| `liquidation-engine.clar` | Permissionless liquidation + keeper rewards |
| Governance proposals (5) | Upgrade and parameter adjustment via DAO |

**Key Innovations:**

1. **Net OI Hedging**: Only hedges the *imbalance* between longs and shorts, not every trade — 10-100x more capital efficient than alternatives.

2. **Dual Stacking Integration**: Our `collateral-vault` is enrolled in Stacks' `dual-stacking-v2` as a DeFi protocol. When traders post sBTC collateral, the vault's balance is snapshotted each cycle. sBTC stacking yield flows back to traders proportionally — they earn yield on idle collateral while holding leveraged positions.

3. **Pyth Oracle**: Real-time BTC/USD prices via Pyth's pull model. Keepers relay VAA price updates permissionlessly. Liquidations require fresh prices (≤5 Bitcoin blocks old).

This grant funds completing the hedge loop — from scaffold to working testnet deployment with live Pyth oracle integration.

---

## Step 3: Audience and Ecosystem Fit

**Primary audience:**
Stacks DeFi traders who want leveraged BTC exposure without leaving the Bitcoin L2 stack, and LPs looking for sBTC-denominated yield beyond passive holding.

**Audience segmentation:**
1. sBTC holders seeking active yield instead of idle custody
2. Stacks-native traders currently going to centralized or other-chain venues for perps
3. Other Stacks DeFi builders who could plug into the internal hedge engine later

**Why Stacks?**

Three unique capabilities make StarStacks possible only on Stacks:

1. **sBTC**: Native Bitcoin-backed settlement asset — LP collateral carries Bitcoin's security, not a bridge's.

2. **Pyth `pyth-oracle-v4`**: Live BTC/USD oracle deployed on Stacks mainnet/testnet. Our keepers relay VAA price updates permissionlessly — no oracle infrastructure to run.

3. **Dual Stacking**: Stacks' `dual-stacking-v2` lets DeFi protocols snapshot balances for sBTC stacking rewards. Our vault is enrolled as a DeFi protocol — traders earn yield on collateral while holding leveraged positions.

**Maintenance plan:**
I'm the lead technical builder and will maintain the protocol personally for at least 6 months post-grant, with public GitHub issue tracking and milestone updates shared on the Stacks forum. A co-founder handles marketing and community management, including the launch push.

**Ecosystem fit:**
Directly targets this cycle's DeFi & Perps theme with a capital-efficiency angle (hedging the net, not the gross) that's novel even outside Stacks, while anchoring the differentiator — sBTC and Pyth — to things that only exist because of Stacks.

---

## Step 4: Risk and Prior History

**Referral source:** *(fill in — e.g. Stacks Discord, hackathon, None)*

**Risk disclosure:**

1. **Net exposure delta**: Between hedge rebalances, the protocol carries unhedged net OI. Mitigation: tight rebalance threshold + hard cap on net exposure size enforced before any trade.

2. **Oracle manipulation**: Pyth prices could lag. Mitigation: 5-BTC-block staleness gate on liquidations; sanity checks ($1,000–$10M BTC price bounds).

3. **Dual Stacking timing**: Rewards accrue per cycle; traders may not claim immediately. Mitigation: reward-per-share accounting (ERC-4626 style) ensures proportional distribution.

4. **Testnet only**: This grant produces unaudited, testnet-only code — no real funds at risk. Mainnet launch (self-funded, post-grant) follows only after full testnet validation and audit.

**Prior grants:** None.

**Prior Stacks work:**
Built a lending protocol on Stacks during a hackathon — hands-on experience with Clarity, sBTC, and Stacks DeFi patterns prior to this project. *(Add project name/link if available.)*

---

## Step 5: Track and Qualification

- **Track:** Getting Started
- **Requested amount:** $7,000 USD

---

## Step 6: Track-Specific Context (Getting Started)

**What are you proposing to explore or build?**
A working net-exposure hedge engine for a Stacks perpetual DEX — the mechanism, not the whole exchange — proven end-to-end on testnet.

**What user or ecosystem problem motivates the project?**

1. **Capital inefficiency**: Existing perp DEX designs force LPs to hold the full notional of every trade as inventory risk. StarStacks hedges only the net imbalance — if 80% longs and 20% shorts, LPs only hedge the 60% delta.

2. **No yield on collateral**: Traders posting sBTC collateral earn nothing while positions are open. Dual Stacking integration changes this — traders passively earn sBTC stacking yield.

3. **Fragmented liquidity**: Stacks DeFi needs native perp infrastructure. StarStacks brings leveraged trading with Bitcoin-backed settlement.

**Why is Stacks the right environment for this work?**
sBTC as native hedge/settlement collateral, and live Pyth oracle access, are the two ingredients this design needs — both already exist on Stacks specifically.

**What have you already validated, prototyped, or learned?**

- **10 contracts validated** with `clarinet check` — syntax passing, ready for devnet
- **Architecture specified** in `CONTRACT_ANALYSIS.md` — full contract flow documented
- **Pyth integration planned** — `oracle-adapter.clar` wraps `pyth-oracle-v4` with staleness gate
- **Dual Stacking integration designed** — `collateral-vault.clar` implements reward-per-share accounting for stacking yield distribution

Not yet deployed or tested on-chain — this grant funds that step.

**Who will do the work and what experience do they bring?**
Solo technical build by me, an independent blockchain developer with prior Stacks hackathon experience (built a lending protocol on Stacks) plus a track record across Solana and EVM DeFi/perp protocols, including a deployed Solana prediction-market AMM and hackathon wins (Seedify/BNB Chain). A co-founder handles marketing and community, leading the launch push in the final week.

**What is the smallest useful outcome this grant should produce?**

The full hedge loop + Dual Stacking integration:
- Open/close positions → net OI tracking → hedge rebalance → internal oracle-priced swap
- sBTC collateral earns stacking yield via Dual Stacking integration
- All live on Stacks testnet with live Pyth BTC/USD oracle

**What evidence will show the concept is worth continuing?**

1. Public testnet demo showing net OI correctly computed and hedged against live Pyth BTC/USD prices
2. Dual Stacking yield flowing to traders with collateral posted
3. Short demo video published
4. At least one external (non-founder) wallet completing a full open→close trade cycle

**What dependencies or risks could affect delivery?**

1. **Pyth `pyth-oracle-v4`**: Beta integration must remain stable on testnet
2. **Dual Stacking**: Depends on `dual-stacking-v2` contract availability on testnet
3. **sBTC**: Requires sBTC minting capability on testnet for testing

No major blocking dependencies — all three are live on Stacks testnet.

**What support from the Stacks ecosystem would help?**
Clarity/Pyth integration feedback from the Hiro or Pyth dev community if available.

**How will you share progress or learnings publicly?**
Public GitHub repo with milestone updates, posted to the Stacks forum.

**What happens after the grant if the work succeeds?**
Mainnet launch, self-funded, with me as the first LP to seed initial liquidity — positioning this grant as the bridge from scaffolded contracts to a derisked, testnet-proven hedge mechanism before real capital goes on-chain. Longer term: full liquidation flow hardening, fee distribution, and a path to audit.

**Any other context reviewers should consider?**
This is a 5-week build sprint: weeks 1–3 cover core hedge loop deployment, week 4 covers liquidation flow and demo UI, week 5 covers public demo, launch prep, and marketing (led by co-founder).

---

## Step 7: Compliance Readiness

- [x] I have reviewed the Vouched ID requirements and will be able to complete the required KYC through Vouched if selected.

---

## Step 8: Milestones

### Milestone 1 — Hedge Engine Live on Testnet
- **Target date:** ~3 weeks from grant start
- **Description:** 
  - **Week 1**: Deploy core contracts to Stacks testnet — `starstacks-core`, `oracle-adapter`, `collateral-vault`, `sbtc-dex`, `perpetual-engine`
  - **Week 2**: Integrate live Pyth `pyth-oracle-v4` BTC/USD feeds via VAA relay; wire `perpetual-engine` → `oracle-adapter` for price fetching
  - **Week 3**: End-to-end test: open/close positions correctly trigger net OI recalculation and hedge swaps via `sbtc-dex`
- **Success criteria:** Full hedge loop (position open/close → OI tracking → hedge rebalance → internal oracle-priced swap) deployed and functioning on Stacks testnet, verifiable via public GitHub repo and on-chain testnet transactions.
- **Payment percent:** 50%
- **Amount, USD:** $3,500

### Milestone 2 — Dual Stacking + Liquidation + Public Demo
- **Target date:** ~5 weeks from grant start
- **Description:**
  - **Week 4**: Enroll `collateral-vault` in `dual-stacking-v2`; implement liquidation flow with keeper rewards; build minimal demo UI
  - **Week 5**: Public demo video, Dual Stacking yield demonstration, open external testnet access, begin marketing push (led by co-founder)
- **Success criteria:** Liquidation flow live on testnet; Dual Stacking rewards distributing correctly; public demo video published; at least one external (non-founder) testnet wallet completes a full open→close cycle.
- **Payment percent:** 50%
- **Amount, USD:** $3,500
- **Final adoption metric:** ≥1 external testnet wallet completing a full trade lifecycle, plus Dual Stacking yield demonstration as a unique signal.

---

## Step 9: Confirm and Submit

- [x] I confirm the information is accurate.
- [x] I understand grants are milestone-based and subject to KYC/KYB readiness, grant agreement execution, and final milestone adoption/usage evidence.

---

### Notes / fields you still need to fill in before submitting:
- Website or repo URL (Step 2)
- Referral source (Step 4)
- Prior Stacks hackathon project name/link, if you have one (Step 4)
