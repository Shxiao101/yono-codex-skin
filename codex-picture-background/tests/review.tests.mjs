// Code Review injection contract: target ownership, iframe context, crop and removal.
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import vm from "node:vm";
import { test } from "node:test";

const source = (await fs.readFile(new URL("../injector.mjs", import.meta.url), "utf8"))
  .replace(/^import .*;\r?\n/gm, "")
  .replace(/^const here = .*;\r?\n/m, "")
  .replace(/main\(\)\.catch\([\s\S]*$/, "");
const options = { port: 9346, browserId: "browser" };
const target = (id, type, url) => ({ id, type, url, webSocketDebuggerUrl: `ws://127.0.0.1:9346/devtools/page/${id}` });
const app = target("app", "page", "app://-/index.html");
const review = target("review", "webview", "codex-sandbox://mcp-app-example.web-sandbox.oaiusercontent.com/#review");

const settings = target("settings", "webview", review.url + "-settings");
const views = [{ title: "Code Review", src: review.url }, { title: "Code Review settings", src: settings.url }];

function harness({ items = [app, review], ready = true } = {}) {
  const calls = [];
  class MockSession {
    constructor(target) { this.target = target; }
    async open() { return this; }
    async send(method, params) {
      calls.push({ method, params });
      if (method === "Page.getFrameTree") return { frameTree: { childFrames: ready ? [{ frame: { id: "inner", name: "root" } }] : [] } };
      if (method === "Page.createIsolatedWorld") return { executionContextId: 42 };
    }
    async evaluate(expression) {
      calls.push({ expression, target: this.target.id, context: this.contextId });
      if (expression.includes(".map((view) => view.src)")) return views.filter(view => expression.includes(`title="${view.title}"`)).map(view => view.src);
      if (expression.includes("const view =")) return { width: 1536, height: 912, x: 340, y: 96, position: "50% 50%" };
      return { installed: expression === "install", removed: expression !== "install" };
    }
    close() { calls.push({ closed: this.target.id }); }
  }
  const context = vm.createContext({ URL, setTimeout, clearTimeout, AbortController, MockSession,
    fetch: async (url) => ({ ok: true, json: async () => url.endsWith("/json/version")
      ? { webSocketDebuggerUrl: "ws://127.0.0.1:9346/devtools/browser/browser" } : items }),
  });
  vm.runInContext(source + '\nSession = MockSession; globalThis.api = { targets, applyToTarget, removeExpression };', context);
  return { ...context.api, calls };
}

test("only the host-owned Code Review sandbox joins existing app/Figma targets", async () => {
  const figma = target("figma", "iframe", "https://www.figma.com/integrations/mcp-app");
  const h = harness({ items: [app, review, settings, figma,
    target("other-mcp", "webview", review.url + "-other"),
    target("browser", "webview", "https://chatgpt.com/"),
    target("stale", "other", review.url),
  ] });
  assert.deepEqual(Array.from(await h.targets(options), t => t.id), ["app", "review", "settings", "figma"]);
});

test("installs and aligns the named inner iframe in a reusable isolated world", async () => {
  const h = harness();
  await h.applyToTarget(review, options, "install", [app, review]);
  const world = h.calls.find(c => c.method === "Page.createIsolatedWorld");
  assert.equal(world.params.frameId, "inner");
  assert.equal(world.params.worldName, "codex-picture-background");
  const inner = h.calls.filter(c => c.target === "review");
  assert.equal(inner.length, 2);
  assert.ok(inner.every(c => c.context === 42));
  assert.ok(inner[1].expression.includes("alignFrameInPage"));
  assert.ok(h.calls.some(c => c.expression?.includes(JSON.stringify(review.url))));
  assert.ok(h.calls.some(c => c.closed === "review"));
});

test("settings use their own inner iframe and matching host crop", async () => {
  const h = harness();
  await h.applyToTarget(settings, options, "install", [app, settings]);
  const inner = h.calls.filter(c => c.target === "settings");
  assert.equal(inner.length, 2);
  assert.ok(inner.every(c => c.context === 42));
  assert.ok(h.calls.some(c => c.expression?.includes('title="Code Review settings"') &&
    c.expression.includes(JSON.stringify(settings.url))));
});

test("removes from the same iframe world rather than the sandbox wrapper", async () => {
  const h = harness();
  await h.applyToTarget(review, options, h.removeExpression, [app, review]);
  const cleanup = h.calls.filter(c => c.expression);
  assert.equal(cleanup.length, 1);
  assert.equal(cleanup[0].context, 42);
  assert.ok(cleanup[0].expression.includes("codex-picture-review"));
});

test("waits for the root iframe instead of skinning an empty sandbox", async () => {
  const h = harness({ ready: false });
  const result = await h.applyToTarget(review, options, "install", [app, review]);
  assert.equal(result.reason, "review-frame-not-ready");
  assert.equal(h.calls.filter(c => c.expression).length, 0);
  assert.ok(h.calls.some(c => c.closed === "review"));
});
