import { describe, expect, it } from "vitest";
import { hmacSha256Hex, verifyBearer, verifyWebhookSignature } from "../src/security";

describe("verifyBearer", () => {
  it("accepts a matching bearer token", () => {
    expect(verifyBearer("Bearer s3cr3t", "s3cr3t")).toBe(true);
  });

  it("rejects a wrong token", () => {
    expect(verifyBearer("Bearer wrong", "s3cr3t")).toBe(false);
  });

  it("rejects a missing header", () => {
    expect(verifyBearer(null, "s3cr3t")).toBe(false);
    expect(verifyBearer(undefined, "s3cr3t")).toBe(false);
  });

  it("rejects a header without the Bearer prefix", () => {
    expect(verifyBearer("s3cr3t", "s3cr3t")).toBe(false);
  });

  it("rejects when the configured secret is empty", () => {
    expect(verifyBearer("Bearer anything", "")).toBe(false);
  });
});

describe("verifyWebhookSignature", () => {
  const secret = "app-secret-value";
  const body = JSON.stringify({ hello: "world" });

  it("accepts a correctly computed signature", async () => {
    const hex = await hmacSha256Hex(body, secret);
    expect(await verifyWebhookSignature(body, `sha256=${hex}`, secret)).toBe(true);
  });

  it("rejects a tampered body", async () => {
    const hex = await hmacSha256Hex(body, secret);
    expect(await verifyWebhookSignature(body + "x", `sha256=${hex}`, secret)).toBe(false);
  });

  it("rejects a wrong secret", async () => {
    const hex = await hmacSha256Hex(body, "different-secret");
    expect(await verifyWebhookSignature(body, `sha256=${hex}`, secret)).toBe(false);
  });

  it("rejects a missing header", async () => {
    expect(await verifyWebhookSignature(body, null, secret)).toBe(false);
  });

  it("rejects a header without the sha256= prefix", async () => {
    const hex = await hmacSha256Hex(body, secret);
    expect(await verifyWebhookSignature(body, hex, secret)).toBe(false);
  });
});
