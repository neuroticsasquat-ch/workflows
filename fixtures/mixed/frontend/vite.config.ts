import { defineConfig } from "vite";

// Library mode: the fixture is a TS package with no HTML entry.
export default defineConfig({
  build: {
    lib: {
      entry: "src/index.ts",
      formats: ["es"],
      fileName: "index",
    },
  },
});
