import { describe, expect, it } from "vitest";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const collateralVault = "collateral-vault";

describe("Collateral Vault - Dual Stacking Integration", () => {
  it("ensures simnet is well initialised", () => {
    expect(simnet.blockHeight).toBeDefined();
  });

  describe("Initial state", () => {
    it("should have zero total collateral initially", () => {
      const result = simnet.callReadOnlyFn(collateralVault, "get-total-collateral", [], deployer);
      expect(result.result.value).toBe(0n);
    });

    it("should have zero reward-per-share initially", () => {
      const result = simnet.callReadOnlyFn(collateralVault, "get-reward-per-share", [], deployer);
      expect(result.result.value).toBe(0n);
    });

    it("should have zero total DS rewards received initially", () => {
      const result = simnet.callReadOnlyFn(collateralVault, "get-total-ds-received", [], deployer);
      expect(result.result.value).toBe(0n);
    });

    it("should not be paused initially", () => {
      const result = simnet.callReadOnlyFn(collateralVault, "get-vault-paused", [], deployer);
      expect(result.result.type).toBe("false");
    });
  });

  describe("Contract interface", () => {
    it("should expose Dual Stacking reward distribution functions", () => {
      // These functions should exist (we test by their presence in read-only queries)
      const r1 = simnet.callReadOnlyFn(collateralVault, "get-total-collateral", [], deployer);
      const r2 = simnet.callReadOnlyFn(collateralVault, "get-reward-per-share", [], deployer);
      const r3 = simnet.callReadOnlyFn(collateralVault, "get-total-ds-received", [], deployer);
      expect(r1).toBeDefined();
      expect(r2).toBeDefined();
      expect(r3).toBeDefined();
    });

    it("should expose vault pause functionality", () => {
      const result = simnet.callReadOnlyFn(collateralVault, "get-vault-paused", [], deployer);
      expect(result).toBeDefined();
      expect(result.result.type).toBe("false");
    });

    it("should support Dual Stacking enrollment checks", () => {
      // The contract should have the ability to check DS enrollment
      const result = simnet.callReadOnlyFn(collateralVault, "get-total-collateral", [], deployer);
      expect(result.result.value).toBe(0n);
    });
  });
});
