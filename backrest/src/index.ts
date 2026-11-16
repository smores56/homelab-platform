import { DurableObject } from "cloudflare:workers";

// The Worker is a thin authenticated-at-the-edge proxy: Cloudflare Access
// covers the whole hostname, and Backrest's own password stays enabled as the
// second layer. Everything interesting happens in the Durable Object, because
// Backrest needs a native restic subprocess and a writable filesystem.

const PORT = 9898;
const READY_TIMEOUT_MS = 5 * 60 * 1000;
const INDEX_TIMEOUT_MS = 20 * 60 * 1000;
const POLL_MS = 1000;

// The platform caps the inactivity timeout at six hours. A four-hour restore
// stream keeps the Durable Object active on its own, so this only decides how
// long an idle instance survives between sessions.
const INACTIVITY_TIMEOUT_MS = 6 * 60 * 60 * 1000;

interface ContainerHandle {
  readonly running: boolean;
  readonly images: Record<string, string>;
  start(options: {
    image: string;
    instance?: string;
    enableInternet: boolean;
    env?: Record<string, string>;
  }): void;
  setInactivityTimeout(durationMs: number): Promise<void>;
  getTcpPort(port: number): {
    fetch(input: string | Request, init?: RequestInit): Promise<Response>;
  };
  monitor(): Promise<void>;
}

export interface Env {
  BACKREST: DurableObjectNamespace;
  BACKREST_INSTANCE: string;
  BACKREST_REPO_ID: string;
  BACKREST_REPO_URI: string;
  BACKREST_REPO_GUID: string;
  BACKREST_OPERATOR_USER: string;
  BACKREST_OPERATOR_BCRYPT: string;
  BACKREST_BOOTSTRAP_USER: string;
  BACKREST_BOOTSTRAP_BCRYPT: string;
  BACKREST_BOOTSTRAP_PASSWORD: string;
  RESTIC_PASSWORD: string;
  R2_ACCESS_KEY_ID: string;
  R2_SECRET_ACCESS_KEY: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const stub = env.BACKREST.get(env.BACKREST.idFromName("recovery"));
    return stub.fetch(request);
  },
};

function jsonError(status: number, error: string, detail: string): Response {
  return new Response(JSON.stringify({ error, detail }), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export class Backrest extends DurableObject<Env> {
  private ready = false;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    const container = this.container();
    // A Durable Object restart keeps the running container but loses the
    // timeout and the readiness flag, so both are re-established here.
    if (container?.running) {
      void ctx.blockConcurrencyWhile(() =>
        container.setInactivityTimeout(INACTIVITY_TIMEOUT_MS),
      );
      void ctx.waitUntil(this.watch(container));
    }
  }

  private container(): ContainerHandle | undefined {
    return (this.ctx as unknown as { container?: ContainerHandle }).container;
  }

  // Deploy-time vars are the only source of the repository location, so a
  // deployment that forgets one must not start with an empty or wrong repo.
  private assertConfigured(): void {
    const missing = (
      [
        "BACKREST_REPO_ID",
        "BACKREST_REPO_URI",
        "BACKREST_REPO_GUID",
        "RESTIC_PASSWORD",
        "R2_ACCESS_KEY_ID",
        "R2_SECRET_ACCESS_KEY",
        "BACKREST_OPERATOR_BCRYPT",
        "BACKREST_BOOTSTRAP_BCRYPT",
        "BACKREST_BOOTSTRAP_PASSWORD",
      ] as const
    ).filter((key) => !this.env[key]);
    if (missing.length > 0) {
      throw new Error(`missing configuration: ${missing.join(", ")}`);
    }
    if (!/^[0-9a-f]{64}$/.test(this.env.BACKREST_REPO_GUID)) {
      throw new Error("BACKREST_REPO_GUID must be the 64-character restic repository id");
    }
  }

  private configJson(): string {
    const env = this.env;
    // Backrest has no read-only authorization role, so the repository is
    // pinned read-only by credential and protected from accidental writes by
    // flags: --no-lock skips the lock directory that a write-denied token
    // cannot create, and --no-cache keeps the restic cache off a 20 GB
    // ephemeral disk. No plans means nothing that writes ever runs.
    return JSON.stringify({
      modno: 0,
      version: 6,
      instance: env.BACKREST_INSTANCE,
      repos: [
        {
          id: env.BACKREST_REPO_ID,
          uri: env.BACKREST_REPO_URI,
          guid: env.BACKREST_REPO_GUID,
          password: env.RESTIC_PASSWORD,
          env: [
            `AWS_ACCESS_KEY_ID=${env.R2_ACCESS_KEY_ID}`,
            `AWS_SECRET_ACCESS_KEY=${env.R2_SECRET_ACCESS_KEY}`,
            "AWS_DEFAULT_REGION=auto",
          ],
          flags: ["--no-lock", "--no-cache"],
          autoUnlock: false,
          autoInitialize: false,
        },
      ],
      plans: [],
      auth: {
        disabled: false,
        users: [
          { name: env.BACKREST_OPERATOR_USER, passwordBcrypt: env.BACKREST_OPERATOR_BCRYPT },
          { name: env.BACKREST_BOOTSTRAP_USER, passwordBcrypt: env.BACKREST_BOOTSTRAP_BCRYPT },
        ],
      },
    });
  }

  private async watch(container: ContainerHandle): Promise<void> {
    try {
      await container.monitor();
      this.ready = false;
      console.log("backrest container exited");
    } catch (error) {
      this.ready = false;
      console.error("backrest container failed", error);
    }
  }

  private async ensureContainer(): Promise<ContainerHandle> {
    const container = this.container();
    if (!container) {
      throw new Error("no container is bound to this Durable Object");
    }
    if (!container.running) {
      container.start({
        image: container.images.backrest,
        instance: "standard-2",
        enableInternet: true,
        env: { BACKREST_CONFIG_JSON: this.configJson() },
      });
      await container.setInactivityTimeout(INACTIVITY_TIMEOUT_MS);
      this.ready = false;
      this.ctx.waitUntil(this.watch(container));
    }
    return container;
  }

  // There is no health endpoint, so "listening" is any HTTP response at all,
  // including the 401 that an unauthenticated request gets.
  private async waitForHttp(container: ContainerHandle): Promise<void> {
    const deadline = Date.now() + READY_TIMEOUT_MS;
    let lastError = "no response";
    while (Date.now() < deadline) {
      try {
        await container.getTcpPort(PORT).fetch("http://container/");
        return;
      } catch (error) {
        lastError = String(error);
        await sleep(POLL_MS);
      }
    }
    throw new Error(`backrest did not accept connections within ${READY_TIMEOUT_MS}ms: ${lastError}`);
  }

  private async rpc(container: ContainerHandle, method: string, body: unknown): Promise<unknown> {
    const credentials = btoa(
      `${this.env.BACKREST_BOOTSTRAP_USER}:${this.env.BACKREST_BOOTSTRAP_PASSWORD}`,
    );
    const response = await container.getTcpPort(PORT).fetch(`http://container/v1.Backrest/${method}`, {
      method: "POST",
      headers: {
        authorization: `Basic ${credentials}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    });
    const text = await response.text();
    if (!response.ok) {
      throw new Error(`${method} failed with ${response.status}: ${text.slice(0, 512)}`);
    }
    return text === "" ? {} : JSON.parse(text);
  }

  // Every wake starts from an empty data directory, so the operation log holds
  // no snapshots and no download URL can be minted until an index task runs.
  // Backrest does not index at startup.
  private async indexSnapshots(container: ContainerHandle): Promise<void> {
    const scheduled = (await this.rpc(container, "DoRepoTask", {
      repoId: this.env.BACKREST_REPO_ID,
      task: "TASK_INDEX_SNAPSHOTS",
    })) as { operationId?: string | number };

    const operationId = String(scheduled.operationId ?? "0");
    if (operationId === "0") {
      throw new Error("index task was not scheduled");
    }

    const deadline = Date.now() + INDEX_TIMEOUT_MS;
    while (Date.now() < deadline) {
      const list = (await this.rpc(container, "GetOperations", {
        selector: { ids: [operationId] },
        lastN: 1,
      })) as { operations?: Array<{ status?: string; displayMessage?: string }> };

      const operation = list.operations?.[0];
      const status = operation?.status ?? "STATUS_UNKNOWN";
      if (status === "STATUS_SUCCESS" || status === "STATUS_WARNING") {
        return;
      }
      if (status === "STATUS_ERROR" || status === "STATUS_SYSTEM_CANCELLED" || status === "STATUS_USER_CANCELLED") {
        throw new Error(`index task ended ${status}: ${operation?.displayMessage ?? ""}`);
      }
      await sleep(POLL_MS);
    }
    throw new Error(`index task did not finish within ${INDEX_TIMEOUT_MS}ms`);
  }

  async fetch(request: Request): Promise<Response> {
    try {
      this.assertConfigured();
      const container = await this.ensureContainer();
      if (!this.ready) {
        await this.waitForHttp(container);
        await this.indexSnapshots(container);
        this.ready = true;
      }
      const url = new URL(request.url);
      const proxied = new Request(`http://container${url.pathname}${url.search}`, request);
      // The response body is passed through unbuffered. When the client
      // disconnects, this fetch is cancelled, Backrest's request context is
      // cancelled, and the restic dump process it started is killed.
      return await container.getTcpPort(PORT).fetch(proxied);
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      return jsonError(503, "backrest unavailable", detail);
    }
  }
}
