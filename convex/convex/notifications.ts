import {
	mutation,
	internalAction,
	internalQuery,
} from "./_generated/server";
import { v } from "convex/values";
import { internal } from "./_generated/api";

const GUEST_DEVICE_ID_REGEX = /^[0-9a-fA-F-]{36}$/;

// ---------------------------------------------------------------------------
// Public mutation: register an APNs push token for the current user/device
// ---------------------------------------------------------------------------
export const registerPushToken = mutation({
	args: {
		apnsToken: v.string(),
		guestDeviceId: v.optional(v.string()),
	},
	handler: async (ctx, args) => {
		const token = args.apnsToken.trim();
		if (!token) {
			throw new Error("APNs token is required.");
		}

		const identity = await ctx.auth.getUserIdentity();
		const tokenIdentifier = identity?.tokenIdentifier;
		const guestDeviceId = args.guestDeviceId?.trim();

		if (guestDeviceId && !GUEST_DEVICE_ID_REGEX.test(guestDeviceId)) {
			throw new Error("Invalid guest device id.");
		}
		if (!tokenIdentifier && !guestDeviceId) {
			throw new Error("Authentication or guest device ID required.");
		}

		const now = Date.now();

		// Upsert by APNs token — one row per physical device token.
		const existing = await ctx.db
			.query("pushTokens")
			.withIndex("by_apnsToken", (q) => q.eq("apnsToken", token))
			.first();

		if (existing) {
			await ctx.db.patch(existing._id, {
				tokenIdentifier: tokenIdentifier ?? existing.tokenIdentifier,
				guestDeviceId: guestDeviceId ?? existing.guestDeviceId,
				updatedAt: now,
			});
			return { id: existing._id };
		}

		const id = await ctx.db.insert("pushTokens", {
			tokenIdentifier,
			guestDeviceId,
			apnsToken: token,
			createdAt: now,
			updatedAt: now,
		});

		return { id };
	},
});

// ---------------------------------------------------------------------------
// Internal query: look up the host's APNs push token
// ---------------------------------------------------------------------------
export const getHostPushToken = internalQuery({
	args: {
		hostTokenIdentifier: v.optional(v.string()),
		hostGuestDeviceId: v.optional(v.string()),
	},
	handler: async (ctx, args) => {
		if (args.hostTokenIdentifier) {
			const row = await ctx.db
				.query("pushTokens")
				.withIndex("by_tokenIdentifier", (q) =>
					q.eq("tokenIdentifier", args.hostTokenIdentifier!),
				)
				.first();
			if (row) return row.apnsToken;
		}

		if (args.hostGuestDeviceId) {
			const row = await ctx.db
				.query("pushTokens")
				.withIndex("by_guestDeviceId", (q) =>
					q.eq("guestDeviceId", args.hostGuestDeviceId!),
				)
				.first();
			if (row) return row.apnsToken;
		}

		return null;
	},
});

// ---------------------------------------------------------------------------
// Internal query: verify the participant's payment is still pending
// ---------------------------------------------------------------------------
export const getPaymentState = internalQuery({
	args: {
		receiptCode: v.string(),
		participantKey: v.string(),
	},
	handler: async (ctx, args) => {
		const receipt = await ctx.db
			.query("receipts")
			.withIndex("by_shareCode", (q) => q.eq("shareCode", args.receiptCode))
			.first();
		if (!receipt) return null;

		const participant = await ctx.db
			.query("receiptParticipants")
			.withIndex("by_receipt_participantKey", (q) =>
				q
					.eq("receiptId", receipt._id)
					.eq("participantKey", args.participantKey),
			)
			.first();
		if (!participant) return null;

		return {
			paymentStatus: participant.paymentStatus,
			paymentMethod: participant.paymentMethod,
			paymentAmount: participant.paymentAmount,
			receiptIsActive: receipt.isActive !== false,
		};
	},
});

// ---------------------------------------------------------------------------
// Internal action: send an APNs push notification to the host
// ---------------------------------------------------------------------------
const PAYMENT_METHOD_LABELS: Record<string, string> = {
	venmo: "Venmo",
	cash_app: "Cash App",
	zelle: "Zelle",
	cash_apple_pay: "Cash / Apple Pay",
};

export const sendPaymentNotification = internalAction({
	args: {
		receiptCode: v.string(),
		participantKey: v.string(),
		guestName: v.string(),
		amount: v.number(),
		paymentMethod: v.string(),
		hostTokenIdentifier: v.optional(v.string()),
		hostGuestDeviceId: v.optional(v.string()),
	},
	handler: async (ctx, args) => {
		// 1. Verify payment is still pending with the same method.
		const state = await ctx.runQuery(
			internal.notifications.getPaymentState,
			{
				receiptCode: args.receiptCode,
				participantKey: args.participantKey,
			},
		);

		if (
			!state ||
			!state.receiptIsActive ||
			state.paymentStatus !== "pending" ||
			state.paymentMethod !== args.paymentMethod
		) {
			// Payment state changed during the delay — skip notification.
			return;
		}

		// 2. Look up the host's push token.
		const apnsToken = await ctx.runQuery(
			internal.notifications.getHostPushToken,
			{
				hostTokenIdentifier: args.hostTokenIdentifier,
				hostGuestDeviceId: args.hostGuestDeviceId,
			},
		);

		if (!apnsToken) {
			console.log(
				`[Notifications] No push token found for host (receipt ${args.receiptCode})`,
			);
			return;
		}

		// 3. Build the notification payload.
		const methodLabel =
			PAYMENT_METHOD_LABELS[args.paymentMethod] ?? args.paymentMethod;
		const amountFormatted = `$${args.amount.toFixed(2)}`;
		const title = "Payment Incoming";
		const body = `${args.guestName} is paying you ${amountFormatted} via ${methodLabel}. Tap to confirm.`;

		const payload = {
			aps: {
				alert: { title, body },
				sound: "default",
				"mutable-content": 1,
			},
			receiptCode: args.receiptCode,
			participantKey: args.participantKey,
			guestName: args.guestName,
			amount: args.amount,
			paymentMethod: args.paymentMethod,
		};

		// 4. Send via APNs HTTP/2 API.
		await sendAPNsPush(apnsToken, payload);
	},
});

// ---------------------------------------------------------------------------
// APNs HTTP/2 push helper
// ---------------------------------------------------------------------------

async function sendAPNsPush(
	deviceToken: string,
	payload: Record<string, unknown>,
): Promise<void> {
	const teamId = process.env.APNS_TEAM_ID;
	const keyId = process.env.APNS_KEY_ID;
	const privateKeyPem = process.env.APNS_PRIVATE_KEY;
	const bundleId = process.env.APNS_BUNDLE_ID ?? "com.splt.money";
	const useSandbox = process.env.APNS_USE_SANDBOX === "true";

	if (!teamId || !keyId || !privateKeyPem) {
		console.log(
			"[APNs] Missing APNS_TEAM_ID, APNS_KEY_ID, or APNS_PRIVATE_KEY — skipping push.",
		);
		return;
	}

	const jwt = await generateAPNsJWT(teamId, keyId, privateKeyPem);

	const host = useSandbox
		? "https://api.sandbox.push.apple.com"
		: "https://api.push.apple.com";

	const url = `${host}/3/device/${deviceToken}`;

	const response = await fetch(url, {
		method: "POST",
		headers: {
			authorization: `bearer ${jwt}`,
			"apns-topic": bundleId,
			"apns-push-type": "alert",
			"apns-priority": "10",
			"content-type": "application/json",
		},
		body: JSON.stringify(payload),
	});

	if (!response.ok) {
		const text = await response.text();
		console.error(
			`[APNs] Push failed (${response.status}): ${text} — token: ${deviceToken.slice(0, 8)}…`,
		);
	} else {
		console.log(
			`[APNs] Push sent to ${deviceToken.slice(0, 8)}… (${response.status})`,
		);
	}
}

// ---------------------------------------------------------------------------
// APNs JWT (ES256) generation using Web Crypto
// ---------------------------------------------------------------------------

async function generateAPNsJWT(
	teamId: string,
	keyId: string,
	privateKeyPem: string,
): Promise<string> {
	// Strip PEM envelope and whitespace.
	const pemBody = privateKeyPem
		.replace(/-----BEGIN PRIVATE KEY-----/, "")
		.replace(/-----END PRIVATE KEY-----/, "")
		.replace(/\s/g, "");

	const keyBytes = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));

	const cryptoKey = await crypto.subtle.importKey(
		"pkcs8",
		keyBytes.buffer,
		{ name: "ECDSA", namedCurve: "P-256" },
		false,
		["sign"],
	);

	const header = base64url(
		JSON.stringify({ alg: "ES256", kid: keyId, typ: "JWT" }),
	);
	const claims = base64url(
		JSON.stringify({ iss: teamId, iat: Math.floor(Date.now() / 1000) }),
	);

	const signingInput = new TextEncoder().encode(`${header}.${claims}`);
	const rawSignature = await crypto.subtle.sign(
		{ name: "ECDSA", hash: "SHA-256" },
		cryptoKey,
		signingInput,
	);

	const signature = base64url(rawSignature);
	return `${header}.${claims}.${signature}`;
}

function base64url(input: string | ArrayBuffer): string {
	let raw: string;
	if (typeof input === "string") {
		raw = btoa(input);
	} else {
		raw = btoa(String.fromCharCode(...new Uint8Array(input)));
	}
	return raw.replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}
