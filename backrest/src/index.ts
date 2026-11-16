import { DurableObject } from "cloudflare:workers";

// The Worker is a read-only proxy in front of Backrest. Cloudflare Access is
// the outer gate and Backrest's password is the inner one, but neither is the
// whole story: Backrest has no read-only role, so the proxy itself refuses
// every request that could reconfigure it, and it also strips the repository
// password and R2 credentials from the config it serves.

const PORT = 9898;
const READY_TIMEOUT_MS = 3 * 60 * 1000;
const INDEX_TIMEOUT_MS = 10 * 60 * 1000;
const POLL_MS = 1000;
// Applied to internal calls only. The proxied response is a stream that may
// run for four hours, so it is never given a timeout.
const RPC_TIMEOUT_MS = 30 * 1000;
// The platform caps the inactivity timeout at six hours. A four-hour restore
// stream keeps the Durable Object active on its own, so this only decides how
// long an idle instance survives between sessions.
const INACTIVITY_TIMEOUT_MS = 6 * 60 * 60 * 1000;

// The reader surface. Everything else — SetConfig, AddRepo, RemoveRepo,
// Backup, Forget, DoRepoTask, Restore, RunCommand, Cancel, ClearHistory,
// PathAutocomplete, SetupSftp, GeneratePairingToken, HashPassword — is refused
// at the edge of the container. SetConfig alone could set auth.disabled and
// drop the repository; RunCommand is arbitrary restic.
const ALLOWED_RPCS = new Set([
	"GetConfig",
	"GetOperations",
	"GetOperationEvents",
	"GetLogs",
	"GetSummaryDashboard",
	"GetDownloadURL",
	"ListSnapshots",
	"ListSnapshotFiles",
]);

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
	// Set to "1" to include internal failure detail in 503 bodies. Off by
	// default so a repository URI or restic error never reaches a caller.
	BACKREST_DEBUG?: string;
}

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const stub = env.BACKREST.get(env.BACKREST.idFromName("recovery"));
		return stub.fetch(request);
	},
};

function jsonError(status: number, error: string, detail?: string): Response {
	const body = detail === undefined ? { error } : { error, detail };
	return new Response(JSON.stringify(body), {
		status,
		headers: { "content-type": "application/json", "cache-control": "no-store" },
	});
}

function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null;
}

// Backrest's GetConfig returns repo passwords and restic environment (the R2
// key pair) verbatim; its sanitizer only masks user hashes and the multihost
// key. The reader never needs either, so they are removed here.
function redactConfig(body: string): string {
	let parsed: unknown;
	try {
		parsed = JSON.parse(body);
	} catch {
		return body;
	}
	if (!isRecord(parsed)) return body;
	if (Array.isArray(parsed.repos)) {
		for (const repo of parsed.repos) {
			if (isRecord(repo)) {
				delete repo.password;
				delete repo.env;
			}
		}
	}
	if (isRecord(parsed.auth) && Array.isArray(parsed.auth.users)) {
		for (const user of parsed.auth.users) {
			if (isRecord(user)) user.passwordBcrypt = "********";
		}
	}
	return JSON.stringify(parsed);
}

function onlyVerified(body: string): string {
	let parsed: unknown;
	try {
		parsed = JSON.parse(body);
	} catch {
		return body;
	}
	if (!isRecord(parsed) || !Array.isArray(parsed.snapshots)) return body;
	parsed.snapshots = parsed.snapshots.filter(
		(snapshot) =>
			isRecord(snapshot) && Array.isArray(snapshot.tags) && snapshot.tags.includes("verified"),
	);
	return JSON.stringify(parsed);
}

export class Backrest extends DurableObject<Env> {
	private ready = false;
	private booting: Promise<void> | undefined;
	private starting: Promise<void> | undefined;

	constructor(ctx: DurableObjectState, env: Env) {
		super(ctx, env);
		const container = this.ctx.container;
		// A Durable Object restart keeps the running container but loses the
		// timeout and the readiness flag, so both are re-established here.
		if (container?.running) {
			void ctx.blockConcurrencyWhile(() =>
				container.setInactivityTimeout(INACTIVITY_TIMEOUT_MS),
			);
			void ctx.waitUntil(this.watch(container));
		}
	}

	private container(): Container | undefined {
		return this.ctx.container;
	}

	private assertConfigured(): void {
		const missing = [
			"BACKREST_INSTANCE",
			"BACKREST_REPO_ID",
			"BACKREST_REPO_URI",
			"BACKREST_REPO_GUID",
			"BACKREST_OPERATOR_USER",
			"BACKREST_OPERATOR_BCRYPT",
			"BACKREST_BOOTSTRAP_USER",
			"BACKREST_BOOTSTRAP_BCRYPT",
			"BACKREST_BOOTSTRAP_PASSWORD",
			"RESTIC_PASSWORD",
			"R2_ACCESS_KEY_ID",
			"R2_SECRET_ACCESS_KEY",
		].filter((key) => !this.env[key as keyof Env]);
		if (missing.length > 0) {
			throw new Error(`missing configuration: ${missing.join(", ")}`);
		}
		if (!/^[0-9a-f]{64}$/.test(this.env.BACKREST_REPO_GUID)) {
			throw new Error("BACKREST_REPO_GUID must be the 64-character restic repository id");
		}
		for (const key of ["BACKREST_OPERATOR_BCRYPT", "BACKREST_BOOTSTRAP_BCRYPT"] as const) {
			if (!/^[A-Za-z0-9+/]{40,}={0,2}$/.test(this.env[key])) {
				throw new Error(`${key} must be base64 bcrypt, not a plaintext password`);
			}
		}
	}

	private containerEnv(): Record<string, string> {
		const env = this.env;
		return {
			BACKREST_INSTANCE: env.BACKREST_INSTANCE,
			BACKREST_REPO_ID: env.BACKREST_REPO_ID,
			BACKREST_REPO_URI: env.BACKREST_REPO_URI,
			BACKREST_REPO_GUID: env.BACKREST_REPO_GUID,
			RESTIC_PASSWORD: env.RESTIC_PASSWORD,
			R2_ACCESS_KEY_ID: env.R2_ACCESS_KEY_ID,
			R2_SECRET_ACCESS_KEY: env.R2_SECRET_ACCESS_KEY,
			BACKREST_OPERATOR_USER: env.BACKREST_OPERATOR_USER,
			BACKREST_OPERATOR_BCRYPT: env.BACKREST_OPERATOR_BCRYPT,
			BACKREST_BOOTSTRAP_USER: env.BACKREST_BOOTSTRAP_USER,
			BACKREST_BOOTSTRAP_BCRYPT: env.BACKREST_BOOTSTRAP_BCRYPT,
		};
	}

	private async watch(container: Container): Promise<void> {
		try {
			await container.monitor();
			console.log("backrest container exited");
		} catch (error) {
			console.error("backrest container failed", error);
		} finally {
			this.ready = false;
			this.booting = undefined;
			this.starting = undefined;
		}
	}

	private async ensureStarted(): Promise<Container> {
		const container = this.container();
		if (!container) {
			throw new Error("no container is bound to this Durable Object");
		}
		if (container.running) return container;

		this.starting ??= (async () => {
			container.start({
				image: container.images.backrest,
				instance: "standard-2",
				enableInternet: true,
				env: this.containerEnv(),
			});
			await container.setInactivityTimeout(INACTIVITY_TIMEOUT_MS);
			this.ctx.waitUntil(this.watch(container));
		})().finally(() => {
			this.starting = undefined;
		});
		await this.starting;
		return container;
	}

	private async containerFetch(
		container: Container,
		path: string,
		init: RequestInit,
		timeoutMs: number,
	): Promise<Response> {
		return container.getTcpPort(PORT).fetch(`http://container${path}`, {
			...init,
			signal: AbortSignal.timeout(timeoutMs),
		});
	}

	// There is no health endpoint, so "listening" is any HTTP response at all,
	// including the 401 an unauthenticated request gets.
	private async waitForHttp(container: Container): Promise<void> {
		const deadline = Date.now() + READY_TIMEOUT_MS;
		let lastError = "no response";
		while (Date.now() < deadline) {
			try {
				await this.containerFetch(container, "/", { method: "GET" }, RPC_TIMEOUT_MS);
				return;
			} catch (error) {
				lastError = String(error);
				await sleep(POLL_MS);
			}
		}
		throw new Error(`backrest did not accept connections within ${READY_TIMEOUT_MS}ms: ${lastError}`);
	}

	private async rpc(container: Container, method: string, body: unknown): Promise<unknown> {
		const credentials = btoa(
			`${this.env.BACKREST_BOOTSTRAP_USER}:${this.env.BACKREST_BOOTSTRAP_PASSWORD}`,
		);
		const response = await this.containerFetch(
			container,
			`/v1.Backrest/${method}`,
			{
				method: "POST",
				headers: {
					authorization: `Basic ${credentials}`,
					"content-type": "application/json",
				},
				body: JSON.stringify(body),
			},
			RPC_TIMEOUT_MS,
		);
		const text = await response.text();
		if (!response.ok) {
			throw new Error(`${method} failed with ${response.status}: ${text.slice(0, 512)}`);
		}
		return text === "" ? {} : JSON.parse(text);
	}

	private async liveSnapshotIds(container: Container): Promise<string[]> {
		const list = (await this.rpc(container, "ListSnapshots", {
			repoId: this.env.BACKREST_REPO_ID,
		})) as { snapshots?: Array<{ id?: string }> };
		return (list.snapshots ?? []).map((snapshot) => snapshot.id ?? "").filter(Boolean);
	}

	private async indexedSnapshotIds(container: Container): Promise<Set<string>> {
		const list = (await this.rpc(container, "GetOperations", {
			selector: { repoGuid: this.env.BACKREST_REPO_GUID },
			lastN: 500,
		})) as {
			operations?: Array<{ snapshotId?: string; operationIndexSnapshot?: unknown }>;
		};
		const ids = new Set<string>();
		for (const operation of list.operations ?? []) {
			if (operation.operationIndexSnapshot !== undefined && operation.snapshotId) {
				ids.add(operation.snapshotId);
			}
		}
		return ids;
	}

	// Every wake starts from an empty data directory: the operation log holds
	// no index operations and GetDownloadURL cannot mint a URL without one.
	// TASK_INDEX_SNAPSHOTS is a one-off task with no operation of its own, so
	// the task id is useless; readiness is the indexed set catching up with the
	// live snapshot list.
	private async reindex(container: Container): Promise<void> {
		const live = await this.liveSnapshotIds(container);
		if (live.length === 0) return;

		await this.rpc(container, "DoRepoTask", {
			repoId: this.env.BACKREST_REPO_ID,
			task: "TASK_INDEX_SNAPSHOTS",
		});

		const deadline = Date.now() + INDEX_TIMEOUT_MS;
		while (Date.now() < deadline) {
			const indexed = await this.indexedSnapshotIds(container);
			if (live.every((id) => indexed.has(id))) return;
			await sleep(POLL_MS);
		}
		throw new Error(
			`index did not complete within ${INDEX_TIMEOUT_MS}ms (${live.length} snapshots live)`,
		);
	}

	private async ensureReady(): Promise<Container> {
		const container = await this.ensureStarted();
		if (this.ready) return container;

		this.booting ??= (async () => {
			await this.waitForHttp(container);
			await this.reindex(container);
			this.ready = true;
		})().finally(() => {
			this.booting = undefined;
		});
		await this.booting;
		return container;
	}

	private async isVerified(
		container: Container,
		operationId: string,
	): Promise<boolean> {
		const ops = (await this.rpc(container, "GetOperations", {
			selector: { ids: [operationId] },
			lastN: 1,
		})) as { operations?: Array<{ snapshotId?: string }> };
		const snapshotId = ops.operations?.[0]?.snapshotId;
		if (!snapshotId) return false;
		const list = (await this.rpc(container, "ListSnapshots", {
			repoId: this.env.BACKREST_REPO_ID,
		})) as { snapshots?: Array<{ id?: string; tags?: string[] }> };
		return (list.snapshots ?? []).some(
			(snapshot) => snapshot.id === snapshotId && (snapshot.tags ?? []).includes("verified"),
		);
	}

	private guard(url: URL, method: string): Response | undefined {
		const rpc = /^\/v1\.([A-Za-z]+)\/([A-Za-z]+)$/.exec(url.pathname);
		if (!rpc) {
			// Static assets, the SPA, and signed /download/<jwt>/ streams.
			if (url.pathname === "/metrics") return jsonError(403, "read-only reader");
			if (method !== "GET" && method !== "HEAD") {
				return jsonError(405, "read-only reader");
			}
			return undefined;
		}
		const [, service, name] = rpc;
		if (service === "Authentication") {
			return name === "Login" ? undefined : jsonError(403, "read-only reader");
		}
		if (service !== "Backrest") return jsonError(404, "not found");
		if (!ALLOWED_RPCS.has(name)) {
			return jsonError(403, "read-only reader", `${name} is not available on this instance`);
		}
		if (method !== "POST") return jsonError(405, "read-only reader");
		return undefined;
	}

	async fetch(request: Request): Promise<Response> {
		const url = new URL(request.url);
		try {
			const refused = this.guard(url, request.method);
			if (refused) return refused;

			this.assertConfigured();
			const container = await this.ensureReady();

			// GetDownloadURL signs any indexed operation; only verified
			// snapshots are eligible. The op id is read from a clone so the
			// request body is still available to the proxy.
			if (url.pathname === "/v1.Backrest/GetDownloadURL") {
				const payload = (await request.clone().json()) as { opId?: string | number };
				const opId = String(payload.opId ?? "");
				if (opId === "" || !(await this.isVerified(container, opId))) {
					return jsonError(409, "snapshot is not verified");
				}
			}

			const proxied = new Request(`http://container${url.pathname}${url.search}`, request);
			// Passed through unbuffered. When the client disconnects this fetch
			// is cancelled, Backrest's request context is cancelled, and the
			// restic dump it started is killed.
			const response = await container.getTcpPort(PORT).fetch(proxied);

			if (
				url.pathname === "/v1.Backrest/ListSnapshots" ||
				url.pathname === "/v1.Backrest/GetConfig"
			) {
				const body = await response.text();
				const transformed =
					url.pathname === "/v1.Backrest/ListSnapshots" ? onlyVerified(body) : redactConfig(body);
				return new Response(transformed, {
					status: response.status,
					headers: {
						"content-type": "application/json",
						"cache-control": "no-store",
					},
				});
			}

			return response;
		} catch (error) {
			const detail = error instanceof Error ? error.message : String(error);
			console.error("backrest proxy failure", detail);
			return jsonError(
				503,
				"backrest unavailable",
				this.env.BACKREST_DEBUG === "1" ? detail : undefined,
			);
		}
	}
}
