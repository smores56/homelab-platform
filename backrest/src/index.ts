import { DurableObject } from "cloudflare:workers";
import { readUint64Field, redactConfigProto } from "./wire";

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

// Connect clients read only `code` and `message` from an error body. Any other
// shape falls back to the HTTP-derived code with an empty message, which is how
// a refused download surfaced as an unknown failure.
function jsonError(status: number, code: string, message: string, detail?: string): Response {
	const body: Record<string, string> = { code, message };
	if (detail !== undefined) body.detail = detail;
	return new Response(JSON.stringify(body), {
		status,
		headers: { "content-type": "application/json", "cache-control": "no-store" },
	});
}

// The Web UI speaks the Connect protocol in protobuf (application/proto) while
// curl and the gate use JSON. op_id is field 1 of GetDownloadURLRequest, and
// int64 ids are decimal strings in protobuf JSON, so both paths produce the
// same text for isVerified().
async function opIdFromRequest(request: Request): Promise<string> {
	const contentType = request.headers.get("content-type") ?? "";
	const body = new Uint8Array(await request.clone().arrayBuffer());
	if (contentType.includes("json")) {
		try {
			const parsed = JSON.parse(new TextDecoder().decode(body)) as { opId?: string | number };
			return String(parsed.opId ?? "");
		} catch {
			return "";
		}
	}
	if (contentType.includes("proto")) return readUint64Field(body, 1) ?? "";
	return "";
}

// The transform is a denylist (Backrest will add fields), so the real secret
// values are the check: if either survives a rewrite, the response is refused.
function containsSecret(
	body: string | Uint8Array,
	secrets: Array<string | undefined>,
): boolean {
	const text = typeof body === "string" ? body : new TextDecoder().decode(body);
	return secrets.some((secret) => secret !== undefined && secret !== "" && text.includes(secret));
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
	private indexing: Promise<void> | undefined;

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

		let indexed = await this.indexedSnapshotIds(container);
		if (live.every((id) => indexed.has(id))) return;

		await this.rpc(container, "DoRepoTask", {
			repoId: this.env.BACKREST_REPO_ID,
			task: "TASK_INDEX_SNAPSHOTS",
		});

		const deadline = Date.now() + INDEX_TIMEOUT_MS;
		let ticks = 0;
		while (Date.now() < deadline) {
			indexed = await this.indexedSnapshotIds(container);
			if (live.every((id) => indexed.has(id))) {
				console.log(`indexed ${live.length} snapshots`);
				return;
			}
			if (++ticks % 10 === 0) {
				console.log(`indexing: ${indexed.size}/${live.length} snapshots indexed`);
			}
			await sleep(POLL_MS);
		}
		throw new Error(
			`index did not complete within ${INDEX_TIMEOUT_MS}ms (${live.length} snapshots live)`,
		);
	}

	// A backup can land while the reader is awake, and a download URL needs an
	// index operation for that snapshot. Listing snapshots therefore schedules a
	// bounded, single-flight refresh instead of waiting for the next wake.
	private ensureIndexed(container: Container): Promise<void> {
		this.indexing ??= this.reindex(container).finally(() => {
			this.indexing = undefined;
		});
		return this.indexing;
	}

	private async configMatches(container: Container): Promise<boolean> {
		try {
			const config = (await this.rpc(container, "GetConfig", {})) as {
				repos?: Array<{ guid?: string; uri?: string }>;
			};
			const repo = config.repos?.[0];
			return (
				repo?.guid === this.env.BACKREST_REPO_GUID && repo?.uri === this.env.BACKREST_REPO_URI
			);
		} catch (error) {
			// A container started with older secrets answers 401 here; treat that
			// as stale too, because the running config cannot be repaired.
			console.warn("config probe failed", String(error));
			return false;
		}
	}

	private async waitUntilStopped(container: Container): Promise<void> {
		const deadline = Date.now() + 60_000;
		while (Date.now() < deadline) {
			if (!container.running) return;
			await sleep(POLL_MS);
		}
		throw new Error("container did not stop");
	}

	private async ensureReady(): Promise<Container> {
		let container = await this.ensureStarted();
		if (this.ready) return container;

		this.booting ??= (async () => {
			await this.waitForHttp(container);
			// A deployment changes the repository and secrets, but a container
			// survives a deploy with the config it was started with. Reusing it
			// would index and list the wrong repository forever.
			if (!(await this.configMatches(container))) {
				console.warn("running container has a stale configuration; restarting it");
				container.destroy();
				await this.waitUntilStopped(container);
				this.starting = undefined;
				container = await this.ensureStarted();
				await this.waitForHttp(container);
				// The replaced instance may still be reported as running for a
				// moment; wait for the new config instead of failing the request.
				const deadline = Date.now() + 60_000;
				while (!(await this.configMatches(container))) {
					if (Date.now() >= deadline) {
						throw new Error("container kept a stale configuration after a restart");
					}
					await sleep(POLL_MS);
				}
			}
			console.log("container ready; indexing snapshots");
			await this.reindex(container);
			console.log("reader ready");
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
			if (url.pathname === "/metrics") {
				return jsonError(403, "permission_denied", "read-only reader");
			}
			if (method !== "GET" && method !== "HEAD") {
				return jsonError(405, "permission_denied", "read-only reader");
			}
			return undefined;
		}
		const [, service, name] = rpc;
		if (service === "Authentication") {
			return name === "Login"
				? undefined
				: jsonError(403, "permission_denied", "read-only reader");
		}
		if (service !== "Backrest") return jsonError(404, "unimplemented", "not found");
		if (!ALLOWED_RPCS.has(name)) {
			return jsonError(
				403,
				"permission_denied",
				"read-only reader",
				`${name} is not available on this instance`,
			);
		}
		if (method !== "POST") return jsonError(405, "permission_denied", "read-only reader");
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
				const opId = await opIdFromRequest(request);
				if (opId === "" || !(await this.isVerified(container, opId))) {
					return jsonError(409, "failed_precondition", "snapshot is not verified");
				}
			}

			const proxied = new Request(`http://container${url.pathname}${url.search}`, request);
			// Passed through unbuffered. When the client disconnects this fetch
			// is cancelled, Backrest's request context is cancelled, and the
			// restic dump it started is killed.
			const response = await container.getTcpPort(PORT).fetch(proxied);

			if (url.pathname === "/v1.Backrest/ListSnapshots") {
				this.ctx.waitUntil(
					this.ensureIndexed(container).catch((error) =>
						console.error("index refresh failed", error),
					),
				);
			}

			// Only a successful response is rewritten, in the format the caller
			// asked for. Backrest's own 401 is text/plain: Connect maps that to
			// unauthenticated and shows the login form, but a body relabelled
			// application/json made the client parse "Unauthorized" and fail the
			// whole page before login.
			const contentType = response.headers.get("content-type") ?? "";
			const jsonTransform =
				url.pathname === "/v1.Backrest/ListSnapshots"
					? onlyVerified
					: url.pathname === "/v1.Backrest/GetConfig"
						? redactConfig
						: undefined;
			if (jsonTransform !== undefined && response.ok) {
				const isConfig = url.pathname === "/v1.Backrest/GetConfig";
				let transformed: string | Uint8Array | undefined;
				if (contentType.includes("application/json")) {
					transformed = jsonTransform(await response.text());
				} else if (isConfig && contentType.includes("application/proto")) {
					try {
						transformed = redactConfigProto(new Uint8Array(await response.arrayBuffer()));
					} catch (error) {
						console.error("could not read the protobuf config", String(error));
						return jsonError(503, "unavailable", "backrest unavailable");
					}
				}
				if (transformed !== undefined) {
					// Fail closed: the real secrets are in env, so a transform that
					// ever stops covering a field is caught instead of leaking it.
					if (
						isConfig &&
						containsSecret(transformed, [
							this.env.RESTIC_PASSWORD,
							this.env.R2_SECRET_ACCESS_KEY,
						])
					) {
						console.error("GetConfig redaction did not remove the repository credentials");
						return jsonError(503, "unavailable", "backrest unavailable");
					}
					const headers = new Headers(response.headers);
					headers.set("content-type", contentType);
					headers.set("cache-control", "no-store");
					headers.delete("content-length");
					return new Response(transformed, {
						status: response.status,
						statusText: response.statusText,
						headers,
					});
				}
			}

			return response;
		} catch (error) {
			const detail = error instanceof Error ? error.message : String(error);
			console.error("backrest proxy failure", detail);
			return jsonError(
				503,
				"unavailable",
				"backrest unavailable",
				this.env.BACKREST_DEBUG === "1" ? detail : undefined,
			);
		}
	}
}
