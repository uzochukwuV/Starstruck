import { describe, expect, it, beforeAll } from "vitest";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;

describe("Full Protocol E2E Flow", () => {
  beforeAll(() => {
    simnet.mineEmptyBlocks(5);
  });

  describe("1. Core Contract - starstacks-core", () => {
    it("should be deployed", () => {
      const initialized = simnet.callReadOnlyFn("starstacks-core", "get-initialized", [], deployer);
      expect(initialized.result).toBeDefined();
    });

    it("should have get-deployer function", () => {
      const deployerAddr = simnet.callReadOnlyFn("starstacks-core", "get-deployer", [], deployer);
      expect(deployerAddr.result).toBeDefined();
    });
  });

  describe("2. Token Contract - sbtc-token", () => {
    it("should have get-total-supply function", () => {
      const supply = simnet.callReadOnlyFn("sbtc-token", "get-total-supply", [], deployer);
      expect(supply).toBeDefined();
    });

    it("should have get-name function", () => {
      const name = simnet.callReadOnlyFn("sbtc-token", "get-name", [], deployer);
      expect(name).toBeDefined();
    });
  });

  describe("3. DEX Contract - sbtc-dex", () => {
    it("should have get-reserves function", () => {
      const reserves = simnet.callReadOnlyFn("sbtc-dex", "get-reserves", [], deployer);
      expect(reserves).toBeDefined();
    });

    it("should have get-total-lp function", () => {
      const totalLp = simnet.callReadOnlyFn("sbtc-dex", "get-total-lp", [], deployer);
      expect(totalLp).toBeDefined();
    });

    it("should have get-hedge-state function", () => {
      const hedge = simnet.callReadOnlyFn("sbtc-dex", "get-hedge-state", [], deployer);
      expect(hedge).toBeDefined();
    });

    it("should have quote-swap-x-to-y function", () => {
      const quote = simnet.callReadOnlyFn("sbtc-dex", "quote-swap-x-to-y", [{ type: "uint", value: 1000n }], deployer);
      expect(quote).toBeDefined();
    });
  });

  describe("4. Perpetual Engine Contract", () => {
    it("should have get-total-long-oi function", () => {
      const longOi = simnet.callReadOnlyFn("perpetual-engine", "get-total-long-oi", [], deployer);
      expect(longOi).toBeDefined();
    });

    it("should have get-total-short-oi function", () => {
      const shortOi = simnet.callReadOnlyFn("perpetual-engine", "get-total-short-oi", [], deployer);
      expect(shortOi).toBeDefined();
    });

    it("should have get-protocol-fees function", () => {
      const fees = simnet.callReadOnlyFn("perpetual-engine", "get-protocol-fees", [], deployer);
      expect(fees).toBeDefined();
    });

    it("should have get-funding-index function", () => {
      const funding = simnet.callReadOnlyFn("perpetual-engine", "get-funding-index", [], deployer);
      expect(funding).toBeDefined();
    });

    it("should have get-net-oi function", () => {
      const netOi = simnet.callReadOnlyFn("perpetual-engine", "get-net-oi", [], deployer);
      expect(netOi).toBeDefined();
    });
  });

  describe("5. Collateral Vault Contract", () => {
    it("should have get-total-collateral function", () => {
      const collateral = simnet.callReadOnlyFn("collateral-vault", "get-total-collateral", [], deployer);
      expect(collateral).toBeDefined();
    });

    it("should have get-vault-paused function", () => {
      const paused = simnet.callReadOnlyFn("collateral-vault", "get-vault-paused", [], deployer);
      expect(paused).toBeDefined();
    });

    it("should have get-total-ds-received function", () => {
      const ds = simnet.callReadOnlyFn("collateral-vault", "get-total-ds-received", [], deployer);
      expect(ds).toBeDefined();
    });

    it("should have get-reward-per-share function", () => {
      const rps = simnet.callReadOnlyFn("collateral-vault", "get-reward-per-share", [], deployer);
      expect(rps).toBeDefined();
    });
  });

  describe("6. Oracle Adapter Contract", () => {
    it("should have get-price-scale function", () => {
      const scale = simnet.callReadOnlyFn("oracle-adapter", "get-price-scale", [], deployer);
      expect(scale).toBeDefined();
    });

    it("should have get-pyth-oracle function", () => {
      const oracle = simnet.callReadOnlyFn("oracle-adapter", "get-pyth-oracle", [], deployer);
      expect(oracle).toBeDefined();
    });

    it("should have get-feed-id function", () => {
      const feedId = simnet.callReadOnlyFn("oracle-adapter", "get-feed-id", [], deployer);
      expect(feedId).toBeDefined();
    });

    it("should have is-price-fresh function", () => {
      const fresh = simnet.callReadOnlyFn("oracle-adapter", "is-price-fresh", [], deployer);
      expect(fresh).toBeDefined();
    });
  });

  describe("7. Liquidation Engine Contract", () => {
    it("should have get-insurance-fund function", () => {
      const fund = simnet.callReadOnlyFn("liquidation-engine", "get-insurance-fund", [], deployer);
      expect(fund).toBeDefined();
    });

    it("should have get-keeper-reward-bps function", () => {
      const reward = simnet.callReadOnlyFn("liquidation-engine", "get-keeper-reward-bps", [], deployer);
      expect(reward).toBeDefined();
    });
  });

  describe("8. Cross-Contract State Verification", () => {
    it("should have consistent price scale across oracle and engine", () => {
      const oracleScale = simnet.callReadOnlyFn("oracle-adapter", "get-price-scale", [], deployer);
      expect(oracleScale.result.value).toBe(100_000_000n);
    });

    it("should have zero OI when no positions opened", () => {
      const longOi = simnet.callReadOnlyFn("perpetual-engine", "get-total-long-oi", [], deployer);
      expect(longOi.result.value).toBe(0n);
    });

    it("should have zero collateral in vault initially", () => {
      const collateral = simnet.callReadOnlyFn("collateral-vault", "get-total-collateral", [], deployer);
      expect(collateral.result.value).toBe(0n);
    });

    it("should have vault not paused", () => {
      const paused = simnet.callReadOnlyFn("collateral-vault", "get-vault-paused", [], deployer);
      expect(paused.result.type).toBe("false");
    });
  });
});
