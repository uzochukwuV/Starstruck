import { describe, expect, it } from "vitest";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const address1 = accounts.get("wallet_1")!;
const oracleAdapter = "oracle-adapter";

describe("Oracle Adapter - Pyth Integration", () => {
  it("ensures simnet is well initialised", () => {
    expect(simnet.blockHeight).toBeDefined();
  });

  it("should have correct price scale (10^8)", () => {
    const result = simnet.callReadOnlyFn(oracleAdapter, "get-price-scale", [], deployer);
    expect(result).toBeDefined();
    expect(result.result.value).toBe(100000000n);
  });

  it("should have zero cached price initially", () => {
    const result = simnet.callReadOnlyFn(oracleAdapter, "get-cached-price", [], deployer);
    expect(result.result.value).toBe(0n);
  });

  it("should have zero cached block initially", () => {
    const result = simnet.callReadOnlyFn(oracleAdapter, "get-cached-block", [], deployer);
    expect(result.result.value).toBe(0n);
  });

  it("should fail safe price read when no price is cached", () => {
    const result = simnet.callReadOnlyFn(oracleAdapter, "get-btc-price", [], address1);
    expect(result.result.type).toBe("err");
  });

  it("should fail unsafe price read when no price is cached", () => {
    const result = simnet.callReadOnlyFn(oracleAdapter, "get-btc-price-unsafe", [], address1);
    expect(result.result.type).toBe("err");
  });

  it("should have price age based on block height", () => {
    const result = simnet.callReadOnlyFn(oracleAdapter, "get-price-age-blocks", [], deployer);
    expect(result.result.value).toBeGreaterThan(0n);
  });

  it("should not be fresh initially", () => {
    const result = simnet.callReadOnlyFn(oracleAdapter, "is-price-fresh", [], deployer);
    expect(result.result.type).toBe("false");
  });

  it("should have valid feed ID", () => {
    const result = simnet.callReadOnlyFn(oracleAdapter, "get-feed-id", [], deployer);
    expect(result.result.type).toBe("buffer");
  });

  it("should have valid Pyth oracle address", () => {
    const result = simnet.callReadOnlyFn(oracleAdapter, "get-pyth-oracle", [], deployer);
    expect(result.result.type).toBe("contract");
  });

  it("should have valid Pyth storage address", () => {
    const result = simnet.callReadOnlyFn(oracleAdapter, "get-pyth-storage", [], deployer);
    expect(result.result.type).toBe("contract");
  });
});
