import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const VERSION = "1.2.28";
const here = path.dirname(fileURLToPath(import.meta.url));
const LOOPBACK = new Set(["127.0.0.1", "localhost", "::1", "[::1]"]);
const ID = /^[A-Za-z0-9._-]{1,200}$/;
const BACKGROUND = /^background(?:-[1-9][0-9]*)?\.png$/;

function parseArgs(argv) {
  const result = {
    mode: "watch",
    port: 9346,
    browserId: null,
    timeoutMs: 60000,
    screenshot: null,
    background: "background.png",
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--watch") result.mode = "watch";
    else if (arg === "--once") result.mode = "once";
    else if (arg === "--verify") result.mode = "verify";
    else if (arg === "--remove") result.mode = "remove";
    else if (arg === "--sidebar-regression") result.mode = "sidebar-regression";
    else if (arg === "--terminal-regression") result.mode = "terminal-regression";
    else if (arg === "--self-test") result.mode = "self-test";
    else if (arg === "--port") result.port = Number(argv[++index]);
    else if (arg === "--browser-id") result.browserId = argv[++index];
    else if (arg === "--timeout-ms") result.timeoutMs = Number(argv[++index]);
    else if (arg === "--screenshot") result.screenshot = path.resolve(argv[++index]);
    else if (arg === "--background") result.background = argv[++index];
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!Number.isInteger(result.port) || result.port < 1024 || result.port > 65535) throw new Error("Invalid port");
  if (!Number.isInteger(result.timeoutMs) || result.timeoutMs < 500 || result.timeoutMs > 120000) throw new Error("Invalid timeout");
  if (result.mode !== "self-test" && (!result.browserId || !ID.test(result.browserId))) {
    throw new Error("A valid --browser-id is required");
  }
  if (!BACKGROUND.test(result.background)) throw new Error("Invalid background");
  return result;
}

function checkedWebSocketUrl(value, port, kind, expectedId = null) {
  const url = new URL(value);
  const match = url.pathname.match(new RegExp(`^/devtools/${kind}/([A-Za-z0-9._-]{1,200})$`));
  if (url.protocol !== "ws:" || !LOOPBACK.has(url.hostname) || Number(url.port) !== port ||
      url.username || url.password || url.search || url.hash || !match ||
      (expectedId !== null && match[1] !== expectedId)) {
    throw new Error("Rejected an unexpected CDP WebSocket URL");
  }
  return url.href;
}

async function cdpJson(port, resource) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 2500);
  try {
    const response = await fetch(`http://127.0.0.1:${port}${resource}`, { redirect: "error", signal: controller.signal });
    if (!response.ok) throw new Error(`CDP returned HTTP ${response.status}`);
    return await response.json();
  } finally {
    clearTimeout(timer);
  }
}

async function assertBrowserIdentity(options) {
  const version = await cdpJson(options.port, "/json/version");
  checkedWebSocketUrl(version.webSocketDebuggerUrl, options.port, "browser", options.browserId);
}

async function targets(options) {
  await assertBrowserIdentity(options);
  const items = await cdpJson(options.port, "/json/list");
  return items.filter((item) => {
    if (item?.type !== "page" || typeof item.url !== "string" || !item.url.startsWith("app://") || !ID.test(item.id)) return false;
    try {
      checkedWebSocketUrl(item.webSocketDebuggerUrl, options.port, "page", item.id);
      return true;
    } catch {
      return false;
    }
  });
}

class Session {
  constructor(target, port) {
    this.ws = new WebSocket(checkedWebSocketUrl(target.webSocketDebuggerUrl, port, "page", target.id));
    this.nextId = 1;
    this.pending = new Map();
  }

  async open() {
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("CDP connection timed out")), 5000);
      this.ws.addEventListener("open", () => { clearTimeout(timer); resolve(); }, { once: true });
      this.ws.addEventListener("error", () => { clearTimeout(timer); reject(new Error("CDP connection failed")); }, { once: true });
    });
    this.ws.addEventListener("message", (event) => {
      let message;
      try { message = JSON.parse(String(event.data)); } catch { return; }
      if (!message.id) return;
      const waiter = this.pending.get(message.id);
      if (!waiter) return;
      clearTimeout(waiter.timer);
      this.pending.delete(message.id);
      if (message.error) waiter.reject(new Error(message.error.message));
      else waiter.resolve(message.result);
    });
    return this;
  }

  send(method, params = {}, timeoutMs = 10000) {
    return new Promise((resolve, reject) => {
      const id = this.nextId++;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP command timed out: ${method}`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }

  async evaluate(expression) {
    const response = await this.send("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
      userGesture: false,
    });
    if (response.exceptionDetails) {
      throw new Error(response.exceptionDetails.exception?.description ?? response.exceptionDetails.text);
    }
    return response.result?.value;
  }

  close() {
    for (const waiter of this.pending.values()) {
      clearTimeout(waiter.timer);
      waiter.reject(new Error("CDP session closed"));
    }
    this.pending.clear();
    try { this.ws.close(); } catch {}
  }
}

async function installInPage(cssText, artDataUrl, version) {
  const STATE = "__CODEX_PICTURE_BACKGROUND__";
  const STYLE_ID = "codex-picture-background-style";
  const ROOT_CLASS = "codex-picture-background";
  const MAIN_SELECTOR = 'main.main-surface, main[class*="_MainContentSurface_"]';
  const domDeadline = Date.now() + 30000;
  while (!document.documentElement && Date.now() < domDeadline) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  if (!document.documentElement) throw new Error("Codex DOM root did not become available");
  const previous = window[STATE];
  const isAvatarOverlay = new URL(location.href).searchParams.get("initialRoute") === "/avatar-overlay";
  if (isAvatarOverlay) {
    previous?.cleanup?.();
    document.documentElement.classList.remove(ROOT_CLASS);
    document.documentElement.style.removeProperty("--codex-picture-art");
    document.getElementById(STYLE_ID)?.remove();
    return {
      installed: false,
      skipped: true,
      reason: "avatar-overlay",
      version,
      main: false,
      sidebar: false,
    };
  }
  if (previous?.version === version && document.getElementById(STYLE_ID)) {
    previous.ensure();
    return {
      installed: true,
      version,
      reused: true,
      main: Boolean(document.querySelector(MAIN_SELECTOR)),
      sidebar: Boolean(document.querySelector("aside.app-shell-left-panel")),
    };
  }
  previous?.cleanup?.();

  const comma = artDataUrl.indexOf(",");
  const binary = atob(artDataUrl.slice(comma + 1));
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  const mime = /^data:([^;,]+)/.exec(artDataUrl)?.[1] || "image/png";
  const artUrl = URL.createObjectURL(new Blob([bytes], { type: mime }));
  let observer;
  let timer;
  let schedule;

  const ensure = () => {
    const root = document.documentElement;
    if (!root) return;
    root.classList.add(ROOT_CLASS);
    root.style.setProperty("--codex-picture-art", `url("${artUrl}")`);
    let style = document.getElementById(STYLE_ID);
    if (!style) {
      style = document.createElement("style");
      style.id = STYLE_ID;
      (document.head || root).appendChild(style);
    }
    if (style.textContent !== cssText) style.textContent = cssText;
  };

  const cleanup = () => {
    if (window[STATE]?.version !== version) return false;
    observer?.disconnect();
    clearInterval(timer);
    clearTimeout(schedule);
    document.documentElement?.classList.remove(ROOT_CLASS);
    document.documentElement?.style.removeProperty("--codex-picture-art");
    document.getElementById(STYLE_ID)?.remove();
    URL.revokeObjectURL(artUrl);
    delete window[STATE];
    return true;
  };

  observer = new MutationObserver(() => {
    clearTimeout(schedule);
    schedule = setTimeout(ensure, 100);
  });
  observer.observe(document.documentElement, { childList: true, subtree: true });
  timer = setInterval(ensure, 4000);
  window[STATE] = { version, ensure, cleanup, observer, timer, artUrl };
  ensure();
  return {
    installed: true,
    version,
    reused: false,
    main: Boolean(document.querySelector(MAIN_SELECTOR)),
    sidebar: Boolean(document.querySelector("aside.app-shell-left-panel")),
  };
}

const removeExpression = `(() => {
  const state = window.__CODEX_PICTURE_BACKGROUND__;
  const removed = state?.cleanup?.() ?? false;
  document.documentElement?.classList.remove("codex-picture-background");
  document.documentElement?.style.removeProperty("--codex-picture-art");
  document.getElementById("codex-picture-background-style")?.remove();
  return { removed };
})()`;

async function loadPayload(background, version) {
  const css = await fs.readFile(path.join(here, "background.css"), "utf8");
  const image = await fs.readFile(path.join(here, background));
  if (!css.includes("codex-picture-background") || image.length < 1024) throw new Error("Background assets are invalid");
  const artDataUrl = `data:image/png;base64,${image.toString("base64")}`;
  return `(${installInPage.toString()})(${JSON.stringify(css)},${JSON.stringify(artDataUrl)},${JSON.stringify(version)})`;
}

async function applyToTarget(target, options, expression) {
  const session = await new Session(target, options.port).open();
  try {
    return await session.evaluate(expression);
  } finally {
    session.close();
  }
}

async function applyAll(options, expression) {
  const appTargets = await targets(options);
  let applied = 0;
  for (const target of appTargets) {
    try {
      const result = await applyToTarget(target, options, expression);
      if (result?.installed) applied += 1;
    } catch (error) {
      process.stderr.write(`Target ${target.id}: ${error.message}\n`);
    }
  }
  return applied;
}

async function verify(options, version) {
  const deadline = Date.now() + options.timeoutMs;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      const appTargets = await targets(options);
      for (const target of appTargets) {
        const session = await new Session(target, options.port).open();
        try {
          const status = await session.evaluate(`(() => {
            const main = document.querySelector('main.main-surface, main[class*="_MainContentSurface_"]');
            return {
              installed: document.documentElement.classList.contains("codex-picture-background"),
              style: Boolean(document.getElementById("codex-picture-background-style")),
              state: window.__CODEX_PICTURE_BACKGROUND__?.version ?? null,
              main: Boolean(main),
              sidebar: Boolean(document.querySelector("aside.app-shell-left-panel")),
              bodyBackground: getComputedStyle(document.body).backgroundImage,
              mainBackground: main ? getComputedStyle(main).backgroundImage : null
            };
          })()`);
          if (status.installed && status.style && status.state === version && status.main) {
            if (options.screenshot) {
              await session.send("Page.enable");
              const capture = await session.send("Page.captureScreenshot", { format: "png", fromSurface: true }, 30000);
              await fs.writeFile(options.screenshot, Buffer.from(capture.data, "base64"));
            }
            process.stdout.write(`${JSON.stringify(status)}\n`);
            return true;
          }
        } finally {
          session.close();
        }
      }
    } catch (error) { lastError = error; }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  if (lastError) process.stderr.write(`Verification detail: ${lastError.message}\n`);
  return false;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const payloadVersion = `${VERSION}:${options.background}`;
  if (options.mode === "self-test") {
    await loadPayload(options.background, payloadVersion);
    process.stdout.write(`SELF_TEST_OK version=${payloadVersion}\n`);
    return;
  }
  if (options.mode === "remove") {
    const appTargets = await targets(options);
    for (const target of appTargets) {
      try { await applyToTarget(target, options, removeExpression); } catch {}
    }
    return;
  }
  if (options.mode === "sidebar-regression") {
    const appTargets = await targets(options);
    for (const target of appTargets) {
      const session = await new Session(target, options.port).open();
      try {
        const result = await session.evaluate(`(async () => {
          const aside = document.querySelector("aside.app-shell-left-panel");
          if (!aside?.parentNode) return { tested: false, reason: "sidebar-not-present" };
          const parent = aside.parentNode;
          const next = aside.nextSibling;
          aside.remove();
          await new Promise((resolve) => setTimeout(resolve, 350));
          window.__CODEX_PICTURE_BACKGROUND__?.ensure?.();
          const persisted = document.documentElement.classList.contains("codex-picture-background") &&
            Boolean(document.getElementById("codex-picture-background-style"));
          parent.insertBefore(aside, next);
          return { tested: true, persisted };
        })()`);
        process.stdout.write(`${JSON.stringify(result)}\n`);
        if (result.tested && !result.persisted) throw new Error("Background disappeared without the sidebar");
        return;
      } finally {
        session.close();
      }
    }
    throw new Error("No Codex page was available for the sidebar regression test");
  }
  if (options.mode === "terminal-regression") {
    const appTargets = await targets(options);
    for (const target of appTargets) {
      const session = await new Session(target, options.port).open();
      try {
        const result = await session.evaluate(`(async () => {
          const bottomSelector = '[data-app-shell-focus-area="bottom-panel"]';
          let bottom = document.querySelector(bottomSelector);
          if (!bottom) {
            const toggle = [...document.querySelectorAll('button[aria-label]')].find((button) =>
              /bottom panel|底部面板/i.test(button.getAttribute('aria-label') || '')
            );
            toggle?.click();
            const deadline = Date.now() + 5000;
            while (!bottom && Date.now() < deadline) {
              await new Promise((resolve) => setTimeout(resolve, 100));
              bottom = document.querySelector(bottomSelector);
            }
          }
          const tabs = bottom?.querySelector('[data-app-shell-tabs="true"]');
          const terminal = bottom?.querySelector('[data-codex-terminal="true"]');
          const xterm = terminal?.querySelector('.terminal.xterm');
          if (!bottom || !tabs || !terminal || !xterm) {
            return { tested: false, reason: 'current-terminal-shell-not-present' };
          }
          const alpha = (color) => {
            const match = color.match(/rgba?\\([^/]+(?:\\/|,)\\s*([0-9.]+)\\s*\\)/);
            return match ? Number(match[1]) : color === 'transparent' ? 0 : 1;
          };
          const layers = [];
          for (let node = terminal; node && node !== bottom; node = node.parentElement) {
            const style = getComputedStyle(node);
            if (alpha(style.backgroundColor) > 0.01 || style.backgroundImage !== 'none') {
              layers.push({
                tag: node.tagName,
                className: typeof node.className === 'string' ? node.className : '',
                focusArea: node.getAttribute('data-app-shell-focus-area'),
                tabs: node.getAttribute('data-app-shell-tabs'),
                tabPanel: node.getAttribute('data-app-shell-tab-panel-controller'),
                terminal: node.getAttribute('data-codex-terminal'),
                color: style.backgroundColor,
                image: style.backgroundImage,
              });
            }
          }
          const status = {
            tested: true,
            skin: document.documentElement.classList.contains('codex-picture-background'),
            tabsBackground: getComputedStyle(tabs).backgroundColor,
            terminalBackground: getComputedStyle(terminal).backgroundColor,
            xtermBackground: getComputedStyle(xterm).backgroundColor,
            paintedLayers: layers,
          };
          status.passed = status.skin && layers.length === 1 && layers[0].tabs === 'true' &&
            alpha(status.tabsBackground) > 0.3 && alpha(status.tabsBackground) < 0.8 &&
            alpha(status.terminalBackground) === 0 && alpha(status.xtermBackground) === 0;
          return status;
        })()`);
        process.stdout.write(`${JSON.stringify(result)}\n`);
        if (!result.tested) continue;
        if (!result.passed) throw new Error("Bottom terminal background regression failed");
        return;
      } finally {
        session.close();
      }
    }
    throw new Error("No Codex page was available for the terminal regression test");
  }
  const payload = await loadPayload(options.background, payloadVersion);
  if (options.mode === "once") {
    const deadline = Date.now() + options.timeoutMs;
    let lastTargetCount = -1;
    let lastError = null;
    let lastReportedError = "";
    while (Date.now() < deadline) {
      try {
        const appTargets = await targets(options);
        lastError = null;
        lastReportedError = "";
        if (appTargets.length !== lastTargetCount) {
          process.stdout.write(`targets=${appTargets.length}\n`);
          lastTargetCount = appTargets.length;
        }
        let ready = 0;
        for (const target of appTargets) {
          try {
            const result = await applyToTarget(target, options, payload);
            process.stdout.write(`${JSON.stringify(result)}\n`);
            // Electron can expose an app:// target before the primary UI has
            // mounted. Keep polling so a renderer replacement or late mount
            // during startup receives the payload too.
            if (result?.installed && result.main) ready += 1;
          } catch (error) {
            process.stderr.write(`Target ${target.id}: ${error.message}\n`);
          }
        }
        if (ready) return;
      } catch (error) {
        // Recent Codex/Electron builds briefly restart the debugging endpoint
        // between browser creation and the first primary page. Treat that as a
        // startup race rather than aborting the whole launch.
        lastError = error;
        if (error.message !== lastReportedError) {
          process.stderr.write(`Waiting for Codex debugging target: ${error.message}\n`);
          lastReportedError = error.message;
        }
      }
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
    if (lastError) process.stderr.write(`Injection detail: ${lastError.message}\n`);
    throw new Error("No Codex page accepted the background payload before the timeout");
  }
  if (options.mode === "verify") {
    if (!await verify(options, payloadVersion)) throw new Error("Background verification timed out");
    return;
  }

  process.stdout.write(`Codex Picture Background watcher ${VERSION}\n`);
  let lastError = "";
  while (true) {
    try {
      const count = await applyAll(options, payload);
      if (count > 0) lastError = "";
    } catch (error) {
      if (error.message !== lastError) process.stderr.write(`${error.message}\n`);
      lastError = error.message;
    }
    await new Promise((resolve) => setTimeout(resolve, 1200));
  }
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exitCode = 1;
});
