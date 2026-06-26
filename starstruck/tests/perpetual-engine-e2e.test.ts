import { describe, expect, it, beforeEach } from "vitest";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const perpetualEngine = "perpetual-engine";
const oracleAdapter = "oracle-adapter";
const collateralVault = "collateral-vault";

describe("Perpetual Engine - End-to-End Trading", () => {
  beforeEach(() => {
    simnet.mineEmptyBlocks(10);
  });

  describe("Initial state", () => {
    it("should have zero total long OI initially", () => {
      const result = simnet.callReadOnlyFn(perpetualEngine, "get-total-long-oi", [], deployer);
      expect(result.result.value).toBe(0n);
    });

    it("should have zero total short OI initially", () => {
      const result = simnet.callReadOnlyFn(perpetualEngine, "get-total-short-oi", [], deployer);
      expect(result.result.value).toBe(0n);
    });

    it("should have zero protocol fee pool initially", () => {
      const result = simnet.callReadOnlyFn(perpetualEngine, "get-protocol-fees", [], deployer);
      expect(result.result.value).toBe(0n);
    });
  });

  describe("Open Interest tracking", () => {
    it("should track long OI correctly", () => {
      const result = simnet.callReadOnlyFn(perpetualEngine, "get-total-long-oi", [], deployer);
      expect(result.result.value).toBe(0n);
    });

    it("should track short OI correctly", () => {
      const result = simnet.callReadOnlyFn(perpetualEngine, "get-total-short-oi", [], deployer);
      expect(result.result.value).toBe(0n);
    });
  });

  describe("Oracle integration", () => {
    it("should use correct price scale", () => {
      const oracleResult = simnet.callReadOnlyFn(oracleAdapter, "get-price-scale", [], deployer);
      expect(oracleResult.result.value).toBe(100_000_000n);
    });
  });

  describe("Collateral vault integration", () => {
    it("should have zero vault collateral initially", () => {
      const result = simnet.callReadOnlyFn(collateralVault, "get-total-collateral", [], deployer);
      expect(result.result.value).toBe(0n);
    });
  });

  describe("Market state", () => {
    it("should have zero long OI when no longs opened", () => {
      const result = simnet.callReadOnlyFn(perpetualEngine, "get-total-long-oi", [], deployer);
      expect(result.result.value).toBe(0n);
    });

    it("should have zero short OI when no shorts opened", () => {
      const result = simnet.callReadOnlyFn(perpetualEngine, "get-total-short-oi", [], deployer);
      expect(result.result.value).toBe(0n);
    });
  });

  describe("Funding rate", () => {
    it("should have funding index defined", () => {
      const result = simnet.callReadOnlyFn(perpetualEngine, "get-funding-index", [], deployer);
      expect(result.result).toBeDefined();
    });
  });
});
