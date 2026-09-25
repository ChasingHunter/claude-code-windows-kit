import { defineConfig } from "vitest/config";

// Plain Node environment: every module under test is pure (WebCrypto,
// string/array logic) or takes an injected fetch/storage fake, so no
// Workers-runtime test pool (miniflare) is required.
export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
  },
});
