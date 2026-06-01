import js from "@eslint/js";
import globals from "globals";

// Lints the browser JavaScript under static/. The app is a plain (non-module)
// script that talks to the Flask API and draws to a canvas, so it runs with the
// browser globals and a recent ECMAScript level.
export default [
  js.configs.recommended,
  {
    files: ["static/**/*.js"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "script",
      globals: globals.browser,
    },
    rules: {
      // empty `catch {}` blocks are used deliberately for best-effort calls
      "no-empty": ["error", { allowEmptyCatch: true }],
    },
  },
];
