import { mutation, query, MutationCtx, QueryCtx } from "./_generated/server";
import { v } from "convex/values";
import type { Id } from "./_generated/dataModel";

const CODE_LENGTH = 6;
const MAX_CODE_ATTEMPTS = 20;
const GUEST_DEVICE_ID_REGEX = /^[0-9a-fA-F-]{36}$/;
const SHARE_CODE_REGEX = /^\d{6}$/;
const SETTLEMENT_PHASE_CLAIMING = "claiming";
const SETTLEMENT_PHASE_FINALIZED = "finalized";
const PAYMENT_STATUS_PENDING = "pending";
const PAYMENT_STATUS_CONFIRMED = "confirmed";
const ARCHIVE_REASON_MANUAL = "manual";
const ARCHIVE_REASON_AUTO_SETTLED = "auto_settled";
const PAYMENT_METHODS = new Set([
	"venmo",
	"cash_app",
	"zelle",
	"cash_apple_pay",
]);

const receiptItemInput = v.object({
	clientItemId: v.optional(v.string()),
	name: v.string(),
	quantity: v.number(),
	// Accept null from older clients; normalize to undefined before storing.
	price: v.optional(v.union(v.number(), v.null())),
	sortOrder: v.number(),
});

const receiptOwnerArgs = {
	guestDeviceId: v.optional(v.string()),
};

const receiptMetaArgs = {
	receiptTotal: v.optional(v.number()),
	subtotal: v.optional(v.number()),
	tax: v.optional(v.number()),
	gratuity: v.optional(v.number()),
};

type AuthIdentity = {
	tokenIdentifier: string;
	subject: string;
	issuer: string;
	name?: string;
	email?: string;
	pictureUrl?: string;
};

type ReceiptOwner =
	| {
			kind: "authenticated";
			identity: AuthIdentity;
	  }
	| {
			kind: "guest";
			guestDeviceId: string;
	  };

type ReceiptParticipantIdentity = {
	participantKey: string;
	tokenIdentifier?: string;
	guestDeviceId?: string;
	displayName?: string;
};

type NormalizedReceiptItem = {
	clientItemId?: string;
	name: string;
	quantity: number;
	price?: number;
	sortOrder: number;
};

export const create = mutation({
	args: {
		clientReceiptId: v.string(),
		items: v.array(receiptItemInput),
		...receiptMetaArgs,
		...receiptOwnerArgs,
	},
	handler: async (ctx, args) => {
		const owner = await resolveReceiptOwner(ctx, args.guestDeviceId);
		const now = Date.now();

		if (owner.kind === "authenticated") {
			await upsertUserFromIdentity(ctx, owner.identity, now);
		}

		const existing = await findExistingReceiptForOwner(
			ctx,
			owner,
			args.clientReceiptId,
		);
		if (existing) {
			const patchExtraFeesTotal = computeExtraFeesTotal(
				normalizeMoney(args.receiptTotal),
				args.items,
				normalizeMoney(args.tax),
				normalizeMoney(args.gratuity),
			);
			await ctx.db.patch(existing._id, {
				isActive: true,
				settlementPhase: SETTLEMENT_PHASE_CLAIMING,
				finalizedAt: undefined,
				archivedReason: undefined,
				receiptTotal: normalizeMoney(args.receiptTotal),
				subtotal: normalizeMoney(args.subtotal),
				tax: normalizeMoney(args.tax),
				gratuity: normalizeMoney(args.gratuity),
				extraFeesTotal: patchExtraFeesTotal,
				otherFees: computeOtherFees(
					patchExtraFeesTotal,
					normalizeMoney(args.tax),
					normalizeMoney(args.gratuity),
				),
				gratuityPercent: computeGratuityPercent(
					normalizeMoney(args.gratuity),
					normalizeMoney(args.subtotal),
				),
				// Legacy JSON can contain stale shapes from older builds.
				// Clear it so reads come from normalized receiptItems only.
				receiptJson: undefined,
				updatedAt: now,
			});
			await replaceReceiptItems(ctx, existing._id, args.items, now);
			await resetReceiptParticipantsForClaiming(ctx, existing._id, now);

			return {
				id: existing._id,
				code: existing.shareCode,
			};
		}

		const shareCode = await generateUniqueShareCode(ctx);
		const insertExtraFeesTotal = computeExtraFeesTotal(
			normalizeMoney(args.receiptTotal),
			args.items,
			normalizeMoney(args.tax),
			normalizeMoney(args.gratuity),
		);
		const id = await ctx.db.insert("receipts", {
			...(owner.kind === "authenticated"
				? {
						ownerTokenIdentifier: owner.identity.tokenIdentifier,
						ownerSubject: owner.identity.subject,
						ownerIssuer: owner.identity.issuer,
					}
				: {
						guestDeviceId: owner.guestDeviceId,
					}),
			clientReceiptId: args.clientReceiptId,
			shareCode,
			isActive: true,
			settlementPhase: SETTLEMENT_PHASE_CLAIMING,
			receiptTotal: normalizeMoney(args.receiptTotal),
			subtotal: normalizeMoney(args.subtotal),
			tax: normalizeMoney(args.tax),
			gratuity: normalizeMoney(args.gratuity),
			extraFeesTotal: insertExtraFeesTotal,
			otherFees: computeOtherFees(
				insertExtraFeesTotal,
				normalizeMoney(args.tax),
				normalizeMoney(args.gratuity),
			),
			gratuityPercent: computeGratuityPercent(
				normalizeMoney(args.gratuity),
				normalizeMoney(args.subtotal),
			),
			createdAt: now,
			updatedAt: now,
		});
		await replaceReceiptItems(ctx, id, args.items, now);

		return { id, code: shareCode };
	},
});

export const get = query({
	args: {
		code: v.string(),
	},
	handler: async (ctx, args) => {
		const identity = await ctx.auth.getUserIdentity();
		const receipt = await getActiveReceiptByCode(ctx, args.code);
		if (!receipt) {
			return null;
		}

		const items = await loadReceiptItems(
			ctx,
			receipt._id,
			receipt.receiptJson,
			receipt.clientReceiptId,
		);
		return {
			id: receipt._id,
			code: receipt.shareCode,
			clientReceiptId: receipt.clientReceiptId,
			createdAt: receipt.createdAt,
			isActive: receipt.isActive ?? true,
			settlementPhase: receipt.settlementPhase ?? SETTLEMENT_PHASE_CLAIMING,
			archivedReason: receipt.archivedReason,
			receiptTotal: receipt.receiptTotal,
			subtotal: receipt.subtotal,
			tax: receipt.tax,
			gratuity: receipt.gratuity,
			extraFeesTotal: receipt.extraFeesTotal,
			otherFees: receipt.otherFees,
			gratuityPercent: receipt.gratuityPercent,
			canManage:
				identity !== null &&
				identity !== undefined &&
				receipt.ownerTokenIdentifier === identity.tokenIdentifier,
			items,
		};
	},
});

export const join = mutation({
	args: {
		code: v.string(),
		...receiptOwnerArgs,
	},
	handler: async (ctx, args) => {
		const identity = await ctx.auth.getUserIdentity();
		const normalizedGuestDeviceId = normalizeGuestDeviceId(args.guestDeviceId);
		const receipt = await getActiveReceiptByCode(ctx, args.code);
		if (!receipt) {
			return null;
		}

		const now = Date.now();
		if (
			(receipt.settlementPhase ?? SETTLEMENT_PHASE_CLAIMING) !==
			SETTLEMENT_PHASE_FINALIZED
		) {
			const participant = await resolveParticipantIdentityForMutation(
				ctx,
				args.guestDeviceId,
			);
			await upsertReceiptParticipant(ctx, receipt._id, participant, now);
		}

		const items = await loadReceiptItems(
			ctx,
			receipt._id,
			receipt.receiptJson,
			receipt.clientReceiptId,
		);
		return {
			id: receipt._id,
			code: receipt.shareCode,
			clientReceiptId: receipt.clientReceiptId,
			createdAt: receipt.createdAt,
			isActive: receipt.isActive ?? true,
			settlementPhase: receipt.settlementPhase ?? SETTLEMENT_PHASE_CLAIMING,
			archivedReason: receipt.archivedReason,
			receiptTotal: receipt.receiptTotal,
			subtotal: receipt.subtotal,
			tax: receipt.tax,
			gratuity: receipt.gratuity,
			extraFeesTotal: receipt.extraFeesTotal,
			otherFees: receipt.otherFees,
			gratuityPercent: receipt.gratuityPercent,
			canManage:
				(identity !== null &&
					identity !== undefined &&
					receipt.ownerTokenIdentifier === identity.tokenIdentifier) ||
				(identity === null &&
					normalizedGuestDeviceId !== null &&
					receipt.guestDeviceId === normalizedGuestDeviceId),
			items,
		};
	},
});

export const live = query({
	args: {
		code: v.string(),
		...receiptOwnerArgs,
	},
	handler: async (ctx, args) => {
		const receipt = await getActiveReceiptByCode(ctx, args.code);
		if (!receipt) {
			return null;
		}

		const settlementPhase =
			receipt.settlementPhase ?? SETTLEMENT_PHASE_CLAIMING;
		const hostParticipantKey = hostParticipantKeyForReceipt(receipt);
		const [items, participantRows, claims, viewerParticipant] =
			await Promise.all([
				loadReceiptItems(
					ctx,
					receipt._id,
					receipt.receiptJson,
					receipt.clientReceiptId,
				),
				ctx.db
					.query("receiptParticipants")
					.withIndex("by_receipt_joinedAt", (q) =>
						q.eq("receiptId", receipt._id),
					)
					.order("asc")
					.collect(),
				ctx.db
					.query("receiptClaims")
					.withIndex("by_receipt_itemKey", (q) =>
						q.eq("receiptId", receipt._id),
					)
					.collect(),
				resolveParticipantIdentityForQuery(ctx, args.guestDeviceId),
			]);

		const extraFeesTotal =
			receipt.extraFeesTotal ??
			computeExtraFeesTotal(
				receipt.receiptTotal,
				items,
				receipt.tax,
				receipt.gratuity,
			);
		const participantClaimSubtotal = new Map<string, number>();
		const claimedByItemKey = new Map<string, number>();
		const viewerClaimedByItemKey = new Map<string, number>();
		const unitPriceByItemKey = new Map(
			items.map((item, index) => {
				const key = makeItemKey(item, index);
				const unitPrice =
					(item.price ?? 0) / Math.max(1, toPositiveNumber(item.quantity, 1));
				return [key, unitPrice] as const;
			}),
		);

		for (const claim of claims) {
			claimedByItemKey.set(
				claim.itemKey,
				(claimedByItemKey.get(claim.itemKey) ?? 0) + claim.quantity,
			);
			participantClaimSubtotal.set(
				claim.participantKey,
				(participantClaimSubtotal.get(claim.participantKey) ?? 0) +
					claim.quantity * (unitPriceByItemKey.get(claim.itemKey) ?? 0),
			);

			if (
				viewerParticipant?.participantKey &&
				claim.participantKey === viewerParticipant.participantKey
			) {
				viewerClaimedByItemKey.set(
					claim.itemKey,
					(viewerClaimedByItemKey.get(claim.itemKey) ?? 0) + claim.quantity,
				);
			}
		}

		// Use the receipt's authoritative subtotal as the denominator for
		// proportional fee splits. This ensures taxRate = tax / subtotal is
		// consistent for every participant. Fall back to the computed sum of item
		// prices if the receipt doesn't have a stored subtotal.
		const computedItemSubtotal = roundCurrency(
			items.reduce(
				(sum, item) =>
					sum +
					(typeof item.price === "number" && Number.isFinite(item.price)
						? item.price
						: 0),
				0,
			),
		);
		const receiptSubtotal =
			typeof receipt.subtotal === "number" &&
			Number.isFinite(receipt.subtotal) &&
			receipt.subtotal > 0
				? receipt.subtotal
				: computedItemSubtotal;

		const hostPaymentConfig = await resolveHostPaymentConfig(
			ctx,
			receipt.ownerTokenIdentifier,
		);
		const hostDisplayName = await resolveHostDisplayName(
			ctx,
			receipt,
			hostParticipantKey,
			participantRows,
		);
		const settlementTotals = computeParticipantSettlementTotals(
			participantRows,
			participantClaimSubtotal,
			receiptSubtotal,
			extraFeesTotal,
			receipt.tax,
			receipt.gratuity,
			hostParticipantKey,
			hostPaymentConfig.absorbExtraCents,
		);
		const allParticipantsSubmitted =
			participantRows.length > 0 &&
			participantRows.every((participant) => participant.isSubmitted === true);
		const unclaimedItemCount = items.reduce((sum, item, index) => {
			const key = makeItemKey(item, index);
			const claimedQuantity = claimedByItemKey.get(key) ?? 0;
			const remaining = Math.max(0, item.quantity - claimedQuantity);
			return sum + (remaining > 0 ? 1 : 0);
		}, 0);
		const participantProfiles = await resolveParticipantPublicProfiles(
			ctx,
			participantRows,
		);
		const viewerParticipantKey = viewerParticipant?.participantKey;
		const viewerHasParticipantRow =
			viewerParticipantKey !== undefined &&
			participantRows.some(
				(row) => row.participantKey === viewerParticipantKey,
			);
		const viewerRemoved =
			viewerParticipantKey !== undefined && !viewerHasParticipantRow;
		const viewerSettlement =
			viewerParticipantKey && settlementTotals.has(viewerParticipantKey)
				? settlementTotals.get(viewerParticipantKey)
				: null;
		const canViewerPay =
			settlementPhase === SETTLEMENT_PHASE_FINALIZED &&
			viewerParticipantKey !== undefined &&
			viewerParticipantKey !== hostParticipantKey;

		return {
			id: receipt._id,
			code: receipt.shareCode,
			clientReceiptId: receipt.clientReceiptId,
			createdAt: receipt.createdAt,
			isActive: receipt.isActive ?? true,
			settlementPhase,
			archivedReason: receipt.archivedReason,
			receiptTotal: receipt.receiptTotal,
			subtotal: receipt.subtotal,
			tax: receipt.tax,
			gratuity: receipt.gratuity,
			extraFeesTotal,
			otherFees:
				receipt.otherFees ??
				computeOtherFees(
					extraFeesTotal,
					receipt.tax,
					receipt.gratuity,
				),
			gratuityPercent:
				receipt.gratuityPercent ??
				computeGratuityPercent(receipt.gratuity, receipt.subtotal),
			viewerParticipantKey,
			viewerRemoved,
			hostParticipantKey,
			hostDisplayName,
			hostHasPaymentOptions: hostPaymentConfig.hasPaymentOptions,
			hostPaymentOptions: {
				preferredPaymentMethod: hostPaymentConfig.preferredPaymentMethod,
				venmoEnabled: hostPaymentConfig.venmoEnabled,
				venmoUsername: hostPaymentConfig.venmoUsername,
				cashAppEnabled: hostPaymentConfig.cashAppEnabled,
				cashAppCashtag: hostPaymentConfig.cashAppCashtag,
				zelleEnabled: hostPaymentConfig.zelleEnabled,
				zelleContact: hostPaymentConfig.zelleContact,
				cashApplePayEnabled: hostPaymentConfig.cashApplePayEnabled,
			},
			allParticipantsSubmitted,
			unclaimedItemCount,
			participants: participantRows.map((participant) => {
				const profile = participantProfiles.get(participant.participantKey);
				const totals = settlementTotals.get(participant.participantKey) ?? {
					itemSubtotal: 0,
					taxShare: 0,
					gratuityShare: 0,
					extraFeesShare: 0,
					roundingAdjustment: 0,
					totalDue: 0,
				};
			const isHost = participant.participantKey === hostParticipantKey;
			return {
				participantKey: participant.participantKey,
				displayName:
					normalizedDisplayName(participant.displayName) ??
					profile?.name ??
					(isHost
						? "Host"
						: defaultParticipantDisplayName(participant.participantKey)),
				participantEmail: profile?.email,
					avatarUrl: profile?.avatarUrl,
					joinedAt: participant.joinedAt,
					isSubmitted: participant.isSubmitted === true,
					submittedAt: participant.submittedAt,
					paymentStatus: participant.paymentStatus,
					paymentMethod: participant.paymentMethod,
					paymentAmount: participant.paymentAmount,
					itemSubtotal: totals.itemSubtotal,
					taxShare: totals.taxShare,
					gratuityShare: totals.gratuityShare,
					extraFeesShare: totals.extraFeesShare,
					roundingAdjustment: totals.roundingAdjustment,
					totalDue: totals.totalDue,
				};
			}),
			viewerSettlement: viewerSettlement
				? {
						...viewerSettlement,
						canPay: canViewerPay,
						paymentStatus:
							participantRows.find(
								(row) => row.participantKey === viewerParticipantKey,
							)?.paymentStatus ?? undefined,
						paymentMethod:
							participantRows.find(
								(row) => row.participantKey === viewerParticipantKey,
							)?.paymentMethod ?? undefined,
					}
				: null,
			items: items.map((item, index) => {
				const key = makeItemKey(item, index);
				const claimedQuantity = claimedByItemKey.get(key) ?? 0;
				const viewerClaimedQuantity = viewerClaimedByItemKey.get(key) ?? 0;
				const remainingQuantity = Math.max(0, item.quantity - claimedQuantity);

				return {
					key,
					clientItemId: item.clientItemId,
					name: item.name,
					quantity: item.quantity,
					price: item.price,
					sortOrder: item.sortOrder,
					claimedQuantity,
					viewerClaimedQuantity,
					remainingQuantity,
				};
			}),
			hostPaymentQueue: participantRows
				.filter(
					(participant) =>
						participant.participantKey !== hostParticipantKey &&
						(settlementTotals.get(participant.participantKey)?.totalDue ?? 0) >
							0,
				)
				.map((participant) => ({
					participantKey: participant.participantKey,
					displayName:
						normalizedDisplayName(participant.displayName) ??
						participantProfiles.get(participant.participantKey)?.name ??
						defaultParticipantDisplayName(participant.participantKey),
					amountDue:
						settlementTotals.get(participant.participantKey)?.totalDue ?? 0,
					paymentStatus: participant.paymentStatus,
					paymentMethod: participant.paymentMethod,
					paymentAmount: participant.paymentAmount,
				})),
		};
	},
});

export const updateClaim = mutation({
	args: {
		code: v.string(),
		itemKey: v.string(),
		delta: v.number(),
		...receiptOwnerArgs,
	},
	handler: async (ctx, args) => {
		const delta = Math.trunc(args.delta);
		if (delta === 0) {
			return { appliedDelta: 0, quantity: 0 };
		}

		const receipt = await getActiveReceiptByCode(ctx, args.code);
		if (!receipt) {
			throw new Error("Receipt not found.");
		}
		if (receipt.isActive === false) {
			throw new Error("Receipt is archived.");
		}
		if (
			(receipt.settlementPhase ?? SETTLEMENT_PHASE_CLAIMING) ===
			SETTLEMENT_PHASE_FINALIZED
		) {
			throw new Error("This split has already been finalized.");
		}

		const now = Date.now();
		const participant = await resolveParticipantIdentityForMutation(
			ctx,
			args.guestDeviceId,
		);
		await upsertReceiptParticipant(ctx, receipt._id, participant, now);
		const participantRow = await ctx.db
			.query("receiptParticipants")
			.withIndex("by_receipt_participantKey", (q) =>
				q
					.eq("receiptId", receipt._id)
					.eq("participantKey", participant.participantKey),
			)
			.first();
		if (participantRow?.isSubmitted === true) {
			throw new Error("Claims are locked. Unsubmit first.");
		}

		const items = await loadReceiptItems(
			ctx,
			receipt._id,
			receipt.receiptJson,
			receipt.clientReceiptId,
		);
		const targetItem = items.find(
			(item, index) => makeItemKey(item, index) === args.itemKey,
		);
		if (!targetItem) {
			throw new Error("Item not found.");
		}

		const itemClaims = await ctx.db
			.query("receiptClaims")
			.withIndex("by_receipt_itemKey", (q) =>
				q.eq("receiptId", receipt._id).eq("itemKey", args.itemKey),
			)
			.collect();

		const totalClaimed = itemClaims.reduce(
			(sum, claim) => sum + claim.quantity,
			0,
		);
		const existingClaim =
			itemClaims.find(
				(claim) => claim.participantKey === participant.participantKey,
			) ?? null;
		const existingQuantity = existingClaim?.quantity ?? 0;

		let appliedDelta = 0;
		let nextQuantity = existingQuantity;

		if (delta > 0) {
			const available = Math.max(0, targetItem.quantity - totalClaimed);
			appliedDelta = Math.min(delta, available);
			nextQuantity = existingQuantity + appliedDelta;
		} else {
			const requestedDecrease = Math.abs(delta);
			const allowedDecrease = Math.min(requestedDecrease, existingQuantity);
			appliedDelta = -allowedDecrease;
			nextQuantity = existingQuantity - allowedDecrease;
		}

		if (appliedDelta === 0) {
			return { appliedDelta: 0, quantity: existingQuantity };
		}

		if (nextQuantity <= 0) {
			if (existingClaim) {
				await ctx.db.delete(existingClaim._id);
			}
			return { appliedDelta, quantity: 0 };
		}

		if (existingClaim) {
			await ctx.db.patch(existingClaim._id, {
				quantity: nextQuantity,
				updatedAt: now,
			});
		} else {
			await ctx.db.insert("receiptClaims", {
				receiptId: receipt._id,
				itemKey: args.itemKey,
				participantKey: participant.participantKey,
				quantity: nextQuantity,
				updatedAt: now,
			});
		}

		return { appliedDelta, quantity: nextQuantity };
	},
});

export const setSubmissionStatus = mutation({
	args: {
		code: v.string(),
		isSubmitted: v.boolean(),
		...receiptOwnerArgs,
	},
	handler: async (ctx, args) => {
		const receipt = await getActiveReceiptByCode(ctx, args.code);
		if (!receipt) {
			throw new Error("Receipt not found.");
		}
		if (receipt.isActive === false) {
			throw new Error("Receipt is archived.");
		}
		if (
			(receipt.settlementPhase ?? SETTLEMENT_PHASE_CLAIMING) ===
			SETTLEMENT_PHASE_FINALIZED
		) {
			throw new Error("This split has already been finalized.");
		}

		const now = Date.now();
		const participant = await resolveParticipantIdentityForMutation(
			ctx,
			args.guestDeviceId,
		);
		await upsertReceiptParticipant(ctx, receipt._id, participant, now);
		const row = await ctx.db
			.query("receiptParticipants")
			.withIndex("by_receipt_participantKey", (q) =>
				q
					.eq("receiptId", receipt._id)
					.eq("participantKey", participant.participantKey),
			)
			.first();

		if (!row) {
			throw new Error("Participant not found.");
		}

		await ctx.db.patch(row._id, {
			isSubmitted: args.isSubmitted,
			submittedAt: args.isSubmitted ? now : undefined,
			paymentStatus: args.isSubmitted ? row.paymentStatus : undefined,
			paymentMethod: args.isSubmitted ? row.paymentMethod : undefined,
			paymentAmount: args.isSubmitted ? row.paymentAmount : undefined,
			paymentMarkedAt: args.isSubmitted ? row.paymentMarkedAt : undefined,
			paymentConfirmedAt: args.isSubmitted ? row.paymentConfirmedAt : undefined,
			updatedAt: now,
		});

		return { isSubmitted: args.isSubmitted };
	},
});

export const removeParticipant = mutation({
	args: {
		code: v.string(),
		participantKey: v.string(),
		...receiptOwnerArgs,
	},
	handler: async (ctx, args) => {
		const receipt = await getActiveReceiptByCode(ctx, args.code);
		if (!receipt) {
			throw new Error("Receipt not found.");
		}
		if (receipt.isActive === false) {
			throw new Error("Receipt is archived.");
		}
		if (
			(receipt.settlementPhase ?? SETTLEMENT_PHASE_CLAIMING) ===
			SETTLEMENT_PHASE_FINALIZED
		) {
			throw new Error("Participants can't be removed after finalization.");
		}
		await assertOwnerCanManageReceipt(ctx, receipt, args.guestDeviceId);

		const hostParticipantKey = hostParticipantKeyForReceipt(receipt);
		if (hostParticipantKey && args.participantKey === hostParticipantKey) {
			throw new Error("Host can't be removed.");
		}

		const participant = await ctx.db
			.query("receiptParticipants")
			.withIndex("by_receipt_participantKey", (q) =>
				q
					.eq("receiptId", receipt._id)
					.eq("participantKey", args.participantKey),
			)
			.first();
		if (!participant) {
			return { removed: false };
		}

		const claims = await ctx.db
			.query("receiptClaims")
			.withIndex("by_receipt_participantKey", (q) =>
				q
					.eq("receiptId", receipt._id)
					.eq("participantKey", args.participantKey),
			)
			.collect();
		await Promise.all(claims.map((claim) => ctx.db.delete(claim._id)));
		await ctx.db.delete(participant._id);

		return { removed: true };
	},
});

export const finalizeSettlement = mutation({
	args: {
		code: v.string(),
		...receiptOwnerArgs,
	},
	handler: async (ctx, args) => {
		const receipt = await getActiveReceiptByCode(ctx, args.code);
		if (!receipt) {
			throw new Error("Receipt not found.");
		}
		if (receipt.isActive === false) {
			throw new Error("Receipt is archived.");
		}
		await assertOwnerCanManageReceipt(ctx, receipt, args.guestDeviceId);
		if (
			(receipt.settlementPhase ?? SETTLEMENT_PHASE_CLAIMING) ===
			SETTLEMENT_PHASE_FINALIZED
		) {
			return { finalized: true };
		}

		const [items, participants, claims] = await Promise.all([
			loadReceiptItems(
				ctx,
				receipt._id,
				receipt.receiptJson,
				receipt.clientReceiptId,
			),
			ctx.db
				.query("receiptParticipants")
				.withIndex("by_receipt_joinedAt", (q) => q.eq("receiptId", receipt._id))
				.order("asc")
				.collect(),
			ctx.db
				.query("receiptClaims")
				.withIndex("by_receipt_itemKey", (q) => q.eq("receiptId", receipt._id))
				.collect(),
		]);

		if (participants.length === 0) {
			throw new Error("At least one participant is required.");
		}
		if (
			!participants.every((participant) => participant.isSubmitted === true)
		) {
			throw new Error("Everyone needs to submit before finalizing.");
		}

		const claimedByItemKey = new Map<string, number>();
		for (const claim of claims) {
			claimedByItemKey.set(
				claim.itemKey,
				(claimedByItemKey.get(claim.itemKey) ?? 0) + claim.quantity,
			);
		}
		const hasUnclaimedItems = items.some((item, index) => {
			const key = makeItemKey(item, index);
			return Math.max(0, item.quantity - (claimedByItemKey.get(key) ?? 0)) > 0;
		});
		if (hasUnclaimedItems) {
			throw new Error("All items must be fully claimed before finalizing.");
		}

		const hostPaymentConfig = await resolveHostPaymentConfig(
			ctx,
			receipt.ownerTokenIdentifier,
		);
		if (!hostPaymentConfig.hasPaymentOptions) {
			throw new Error("Set up at least one payment option before finalizing.");
		}

		await ctx.db.patch(receipt._id, {
			settlementPhase: SETTLEMENT_PHASE_FINALIZED,
			finalizedAt: Date.now(),
			archivedReason: undefined,
			updatedAt: Date.now(),
		});

		return { finalized: true };
	},
});

export const markPaymentIntent = mutation({
	args: {
		code: v.string(),
		method: v.string(),
		...receiptOwnerArgs,
	},
	handler: async (ctx, args) => {
		const method = args.method.trim();
		if (!PAYMENT_METHODS.has(method)) {
			throw new Error("Unsupported payment method.");
		}

		const receipt = await getActiveReceiptByCode(ctx, args.code);
		if (!receipt) {
			throw new Error("Receipt not found.");
		}
		if (receipt.isActive === false) {
			throw new Error("Receipt is archived.");
		}
		if (
			(receipt.settlementPhase ?? SETTLEMENT_PHASE_CLAIMING) !==
			SETTLEMENT_PHASE_FINALIZED
		) {
			throw new Error("This split isn't finalized yet.");
		}

		const participantIdentity = await resolveParticipantIdentityForMutation(
			ctx,
			args.guestDeviceId,
		);
		const hostParticipantKey = hostParticipantKeyForReceipt(receipt);
		if (
			hostParticipantKey &&
			participantIdentity.participantKey === hostParticipantKey
		) {
			throw new Error("Host doesn't submit payment intents.");
		}

		const [items, participants, claims] = await Promise.all([
			loadReceiptItems(
				ctx,
				receipt._id,
				receipt.receiptJson,
				receipt.clientReceiptId,
			),
			ctx.db
				.query("receiptParticipants")
				.withIndex("by_receipt_joinedAt", (q) => q.eq("receiptId", receipt._id))
				.order("asc")
				.collect(),
			ctx.db
				.query("receiptClaims")
				.withIndex("by_receipt_itemKey", (q) => q.eq("receiptId", receipt._id))
				.collect(),
		]);
		const participantRow = participants.find(
			(participant) =>
				participant.participantKey === participantIdentity.participantKey,
		);
		if (!participantRow) {
			throw new Error("Participant not found.");
		}

		const settlementTotals = await computeParticipantSettlementTotalsFromClaims(
			ctx,
			receipt,
			items,
			participants,
			claims,
		);
		const amountDue =
			settlementTotals.get(participantIdentity.participantKey)?.totalDue ?? 0;
		if (amountDue <= 0) {
			throw new Error("No payment due.");
		}

		await ctx.db.patch(participantRow._id, {
			paymentStatus: PAYMENT_STATUS_PENDING,
			paymentMethod: method,
			paymentAmount: amountDue,
			paymentMarkedAt: Date.now(),
			paymentConfirmedAt: undefined,
			updatedAt: Date.now(),
		});

		return {
			marked: true,
			paymentStatus: PAYMENT_STATUS_PENDING,
			paymentAmount: amountDue,
			paymentMethod: method,
		};
	},
});

export const confirmPayment = mutation({
	args: {
		code: v.string(),
		participantKey: v.string(),
		...receiptOwnerArgs,
	},
	handler: async (ctx, args) => {
		const receipt = await getActiveReceiptByCode(ctx, args.code);
		if (!receipt) {
			throw new Error("Receipt not found.");
		}
		if (receipt.isActive === false) {
			throw new Error("Receipt is archived.");
		}
		await assertOwnerCanManageReceipt(ctx, receipt, args.guestDeviceId);
		if (
			(receipt.settlementPhase ?? SETTLEMENT_PHASE_CLAIMING) !==
			SETTLEMENT_PHASE_FINALIZED
		) {
			throw new Error("This split isn't finalized yet.");
		}

		const [items, participants, claims] = await Promise.all([
			loadReceiptItems(
				ctx,
				receipt._id,
				receipt.receiptJson,
				receipt.clientReceiptId,
			),
			ctx.db
				.query("receiptParticipants")
				.withIndex("by_receipt_joinedAt", (q) => q.eq("receiptId", receipt._id))
				.order("asc")
				.collect(),
			ctx.db
				.query("receiptClaims")
				.withIndex("by_receipt_itemKey", (q) => q.eq("receiptId", receipt._id))
				.collect(),
		]);
		const hostParticipantKey = hostParticipantKeyForReceipt(receipt);
		if (hostParticipantKey && args.participantKey === hostParticipantKey) {
			throw new Error("Host doesn't need payment confirmation.");
		}

		const target = participants.find(
			(participant) => participant.participantKey === args.participantKey,
		);
		if (!target) {
			throw new Error("Participant not found.");
		}

		await ctx.db.patch(target._id, {
			paymentStatus: PAYMENT_STATUS_CONFIRMED,
			paymentConfirmedAt: Date.now(),
			updatedAt: Date.now(),
		});

		const settlementTotals = await computeParticipantSettlementTotalsFromClaims(
			ctx,
			receipt,
			items,
			participants,
			claims,
		);
		const payableParticipants = participants.filter((participant) => {
			if (
				hostParticipantKey &&
				participant.participantKey === hostParticipantKey
			) {
				return false;
			}
			return (
				(settlementTotals.get(participant.participantKey)?.totalDue ?? 0) > 0
			);
		});
		const allGuestsPaid = payableParticipants.every((participant) => {
			if (participant.participantKey === args.participantKey) {
				return true;
			}
			return participant.paymentStatus === PAYMENT_STATUS_CONFIRMED;
		});

		let archived = false;
		if (allGuestsPaid && payableParticipants.length > 0) {
			await ctx.db.patch(receipt._id, {
				isActive: false,
				archivedReason: ARCHIVE_REASON_AUTO_SETTLED,
				updatedAt: Date.now(),
			});
			archived = true;
		}

		return { confirmed: true, archived };
	},
});

export const updateParticipantDisplayName = mutation({
	args: {
		code: v.string(),
		displayName: v.string(),
		...receiptOwnerArgs,
	},
	handler: async (ctx, args) => {
		const receipt = await getActiveReceiptByCode(ctx, args.code);
		if (!receipt) {
			throw new Error("Receipt not found.");
		}
		if (receipt.isActive === false) {
			throw new Error("Receipt is archived.");
		}
		if (
			(receipt.settlementPhase ?? SETTLEMENT_PHASE_CLAIMING) ===
			SETTLEMENT_PHASE_FINALIZED
		) {
			throw new Error("Display names can't be changed after finalization.");
		}

		const now = Date.now();
		const participant = await resolveParticipantIdentityForMutation(
			ctx,
			args.guestDeviceId,
		);
		await upsertReceiptParticipant(ctx, receipt._id, participant, now);

		const newDisplayName =
			normalizedDisplayName(args.displayName) ?? participant.displayName;
		const participantRow = await ctx.db
			.query("receiptParticipants")
			.withIndex("by_receipt_participantKey", (q) =>
				q
					.eq("receiptId", receipt._id)
					.eq("participantKey", participant.participantKey),
			)
			.first();

		if (!participantRow) {
			throw new Error("Participant not found.");
		}

		await ctx.db.patch(participantRow._id, {
			displayName: newDisplayName,
			updatedAt: now,
		});

		return { updated: true };
	},
});

export const listRecent = query({
	args: {
		limit: v.optional(v.number()),
		includeArchived: v.optional(v.boolean()),
		...receiptOwnerArgs,
	},
	handler: async (ctx, args) => {
		const identity = await ctx.auth.getUserIdentity();
		const limit = Math.max(1, Math.min(Math.floor(args.limit ?? 30), 100));
		const includeArchived = args.includeArchived === true;
		const normalizedGuestDeviceId = normalizeGuestDeviceId(args.guestDeviceId);
		const receiptEntries = new Map<
			Id<"receipts">,
			{ receipt: ReceiptRecord; sortKey: number }
		>();

		if (identity) {
			const activeOwnedReceipts = await ctx.db
				.query("receipts")
				.withIndex("by_owner_active_createdAt", (q) =>
					q
						.eq("ownerTokenIdentifier", identity.tokenIdentifier)
						.eq("isActive", true),
				)
				.order("desc")
				.take(limit);
			const archivedOwnedReceipts = includeArchived
				? await ctx.db
						.query("receipts")
						.withIndex("by_owner_active_createdAt", (q) =>
							q
								.eq("ownerTokenIdentifier", identity.tokenIdentifier)
								.eq("isActive", false),
						)
						.order("desc")
						.take(limit)
				: [];
			const ownedReceipts = [...activeOwnedReceipts, ...archivedOwnedReceipts];

			for (const receipt of ownedReceipts) {
				receiptEntries.set(receipt._id, {
					receipt,
					sortKey: receipt.createdAt,
				});
			}

			const participantRows = await ctx.db
				.query("receiptParticipants")
				.withIndex("by_tokenIdentifier_joinedAt", (q) =>
					q.eq("tokenIdentifier", identity.tokenIdentifier),
				)
				.order("desc")
				.take(limit * 3);

			await addReceiptsFromParticipantRows(
				ctx,
				receiptEntries,
				participantRows,
				includeArchived,
			);
		} else {
			if (!normalizedGuestDeviceId) {
				return [];
			}

			const activeOwnedReceipts = await ctx.db
				.query("receipts")
				.withIndex("by_guest_active_createdAt", (q) =>
					q.eq("guestDeviceId", normalizedGuestDeviceId).eq("isActive", true),
				)
				.order("desc")
				.take(limit);
			const archivedOwnedReceipts = includeArchived
				? await ctx.db
						.query("receipts")
						.withIndex("by_guest_active_createdAt", (q) =>
							q
								.eq("guestDeviceId", normalizedGuestDeviceId)
								.eq("isActive", false),
						)
						.order("desc")
						.take(limit)
				: [];
			const ownedReceipts = [...activeOwnedReceipts, ...archivedOwnedReceipts];

			for (const receipt of ownedReceipts) {
				receiptEntries.set(receipt._id, {
					receipt,
					sortKey: receipt.createdAt,
				});
			}

			const participantRows = await ctx.db
				.query("receiptParticipants")
				.withIndex("by_guestDeviceId_joinedAt", (q) =>
					q.eq("guestDeviceId", normalizedGuestDeviceId),
				)
				.order("desc")
				.take(limit * 3);

			await addReceiptsFromParticipantRows(
				ctx,
				receiptEntries,
				participantRows,
				includeArchived,
			);
		}

		const sortedReceipts = Array.from(receiptEntries.values())
			.sort((a, b) => b.sortKey - a.sortKey)
			.slice(0, limit)
			.map((entry) => entry.receipt);

		return await mapReceiptsForQuery(
			ctx,
			sortedReceipts,
			identity?.tokenIdentifier,
			normalizedGuestDeviceId,
		);
	},
});

export const archive = mutation({
	args: {
		clientReceiptId: v.string(),
		...receiptOwnerArgs,
	},
	handler: async (ctx, args) => {
		const owner = await resolveReceiptOwner(ctx, args.guestDeviceId);
		const existing = await findExistingReceiptForOwner(
			ctx,
			owner,
			args.clientReceiptId,
		);

		if (!existing) {
			return { archived: false };
		}

		await ctx.db.patch(existing._id, {
			isActive: false,
			archivedReason: ARCHIVE_REASON_MANUAL,
			updatedAt: Date.now(),
		});

		return { archived: true };
	},
});

export const unarchive = mutation({
	args: {
		clientReceiptId: v.string(),
		...receiptOwnerArgs,
	},
	handler: async (ctx, args) => {
		const owner = await resolveReceiptOwner(ctx, args.guestDeviceId);
		const existing = await findExistingReceiptForOwner(
			ctx,
			owner,
			args.clientReceiptId,
		);

		if (!existing) {
			return { unarchived: false };
		}

		await ctx.db.patch(existing._id, {
			isActive: true,
			archivedReason: undefined,
			updatedAt: Date.now(),
		});

		return { unarchived: true };
	},
});

export const destroy = mutation({
	args: {
		clientReceiptId: v.string(),
		...receiptOwnerArgs,
	},
	handler: async (ctx, args) => {
		const owner = await resolveReceiptOwner(ctx, args.guestDeviceId);
		const existing = await findExistingReceiptForOwner(
			ctx,
			owner,
			args.clientReceiptId,
		);

		if (!existing) {
			return { deleted: false };
		}

		// Delete all claims for this receipt
		const claims = await ctx.db
			.query("receiptClaims")
			.withIndex("by_receipt_itemKey", (q) => q.eq("receiptId", existing._id))
			.collect();
		await Promise.all(claims.map((claim) => ctx.db.delete(claim._id)));

		// Delete all participants for this receipt
		const participants = await ctx.db
			.query("receiptParticipants")
			.withIndex("by_receipt_participantKey", (q) =>
				q.eq("receiptId", existing._id),
			)
			.collect();
		await Promise.all(
			participants.map((participant) => ctx.db.delete(participant._id)),
		);

		// Delete all items for this receipt
		const items = await ctx.db
			.query("receiptItems")
			.withIndex("by_receipt_sortOrder", (q) => q.eq("receiptId", existing._id))
			.collect();
		await Promise.all(items.map((item) => ctx.db.delete(item._id)));

		// Delete the receipt itself
		await ctx.db.delete(existing._id);

		return { deleted: true };
	},
});

export const migrateGuestData = mutation({
	args: {
		guestDeviceId: v.string(),
	},
	handler: async (ctx, args) => {
		const identity = await requireIdentity(ctx);
		const guestDeviceId = normalizeGuestDeviceId(args.guestDeviceId);
		if (!guestDeviceId) {
			throw new Error("Valid guest device id required.");
		}

		const now = Date.now();
		await upsertUserFromIdentity(ctx, identity, now);
		const authParticipantKey = `auth:${identity.tokenIdentifier}`;

		const [guestReceipts, guestParticipants] = await Promise.all([
			ctx.db
				.query("receipts")
				.withIndex("by_guestDeviceId", (q) =>
					q.eq("guestDeviceId", guestDeviceId),
				)
				.collect(),
			ctx.db
				.query("receiptParticipants")
				.withIndex("by_guestDeviceId_joinedAt", (q) =>
					q.eq("guestDeviceId", guestDeviceId),
				)
				.collect(),
		]);

		for (const receipt of guestReceipts) {
			await ctx.db.patch(receipt._id, {
				ownerTokenIdentifier: identity.tokenIdentifier,
				ownerSubject: identity.subject,
				ownerIssuer: identity.issuer,
				guestDeviceId: undefined,
				updatedAt: now,
			});
		}

		const migratedClaimCount = await migrateGuestClaimsToAuthenticated(
			ctx,
			guestParticipants,
			authParticipantKey,
			now,
		);
		const migratedParticipantCount =
			await migrateGuestParticipantsToAuthenticated(
				ctx,
				guestParticipants,
				identity,
				authParticipantKey,
				now,
			);

		return {
			migratedCount: guestReceipts.length,
			migratedReceiptCount: guestReceipts.length,
			migratedParticipantCount,
			migratedClaimCount,
		};
	},
});

type MigratableParticipant = {
	_id: Id<"receiptParticipants">;
	receiptId: Id<"receipts">;
	participantKey: string;
	displayName?: string;
	joinedAt: number;
};

async function migrateGuestClaimsToAuthenticated(
	ctx: MutationCtx,
	guestParticipants: Array<MigratableParticipant>,
	authParticipantKey: string,
	now: number,
) {
	let migratedClaimCount = 0;

	for (const participant of guestParticipants) {
		if (participant.participantKey === authParticipantKey) {
			continue;
		}

		const guestClaims = await ctx.db
			.query("receiptClaims")
			.withIndex("by_receipt_participantKey", (q) =>
				q
					.eq("receiptId", participant.receiptId)
					.eq("participantKey", participant.participantKey),
			)
			.collect();

		for (const claim of guestClaims) {
			const existingAuthClaim = await ctx.db
				.query("receiptClaims")
				.withIndex("by_receipt_itemKey_participantKey", (q) =>
					q
						.eq("receiptId", participant.receiptId)
						.eq("itemKey", claim.itemKey)
						.eq("participantKey", authParticipantKey),
				)
				.first();

			if (existingAuthClaim && existingAuthClaim._id !== claim._id) {
				await ctx.db.patch(existingAuthClaim._id, {
					quantity: existingAuthClaim.quantity + claim.quantity,
					updatedAt: now,
				});
				await ctx.db.delete(claim._id);
			} else {
				await ctx.db.patch(claim._id, {
					participantKey: authParticipantKey,
					updatedAt: now,
				});
			}

			migratedClaimCount += 1;
		}
	}

	return migratedClaimCount;
}

async function migrateGuestParticipantsToAuthenticated(
	ctx: MutationCtx,
	guestParticipants: Array<MigratableParticipant>,
	identity: AuthIdentity,
	authParticipantKey: string,
	now: number,
) {
	let migratedParticipantCount = 0;
	const preferredDisplayName = normalizedDisplayName(identity.name) ?? "You";

	for (const participant of guestParticipants) {
		const existingAuthParticipant = await ctx.db
			.query("receiptParticipants")
			.withIndex("by_receipt_participantKey", (q) =>
				q
					.eq("receiptId", participant.receiptId)
					.eq("participantKey", authParticipantKey),
			)
			.first();

		if (
			existingAuthParticipant &&
			existingAuthParticipant._id !== participant._id
		) {
			const displayName =
				normalizedDisplayName(existingAuthParticipant.displayName) ??
				preferredDisplayName;
			await ctx.db.patch(existingAuthParticipant._id, {
				tokenIdentifier: identity.tokenIdentifier,
				guestDeviceId: undefined,
				displayName,
				joinedAt: Math.min(
					existingAuthParticipant.joinedAt,
					participant.joinedAt,
				),
				updatedAt: now,
			});
			await ctx.db.delete(participant._id);
		} else {
			await ctx.db.patch(participant._id, {
				participantKey: authParticipantKey,
				tokenIdentifier: identity.tokenIdentifier,
				guestDeviceId: undefined,
				displayName: preferredDisplayName,
				updatedAt: now,
			});
		}

		migratedParticipantCount += 1;
	}

	return migratedParticipantCount;
}

type ReceiptRecord = {
	_id: Id<"receipts">;
	shareCode: string;
	clientReceiptId: string;
	createdAt: number;
	isActive?: boolean;
	settlementPhase?: string;
	finalizedAt?: number;
	archivedReason?: string;
	receiptTotal?: number;
	subtotal?: number;
	tax?: number;
	gratuity?: number;
	extraFeesTotal?: number;
	otherFees?: number;
	gratuityPercent?: number;
	ownerTokenIdentifier?: string;
	guestDeviceId?: string;
	receiptJson?: string;
};

async function addReceiptsFromParticipantRows(
	ctx: QueryCtx,
	entries: Map<Id<"receipts">, { receipt: ReceiptRecord; sortKey: number }>,
	rows: Array<{
		receiptId: Id<"receipts">;
		joinedAt: number;
	}>,
	_includeArchived: boolean,
) {
	for (const row of rows) {
		const receipt = await ctx.db.get(row.receiptId);
		// Participants (non-owners) should never see archived/deleted receipts.
		// The includeArchived flag only applies to owned receipts, not joined ones.
		if (!receipt || receipt.isActive === false) {
			continue;
		}

		const sortKey = Math.max(receipt.createdAt, row.joinedAt);
		const existing = entries.get(receipt._id);
		if (!existing || sortKey > existing.sortKey) {
			entries.set(receipt._id, {
				receipt,
				sortKey,
			});
		}
	}
}

async function mapReceiptsForQuery(
	ctx: QueryCtx,
	receipts: Array<ReceiptRecord>,
	viewerTokenIdentifier?: string,
	viewerGuestDeviceId?: string | null,
) {
	return await Promise.all(
		receipts.map(async (receipt) => {
			const items = await loadReceiptItems(
				ctx,
				receipt._id,
				receipt.receiptJson,
				receipt.clientReceiptId,
			);
			return {
				id: receipt._id,
				code: receipt.shareCode,
				clientReceiptId: receipt.clientReceiptId,
				createdAt: receipt.createdAt,
				isActive: receipt.isActive ?? true,
				settlementPhase: receipt.settlementPhase ?? SETTLEMENT_PHASE_CLAIMING,
				finalizedAt: receipt.finalizedAt,
				archivedReason: receipt.archivedReason,
				receiptTotal: receipt.receiptTotal,
				subtotal: receipt.subtotal,
				tax: receipt.tax,
				gratuity: receipt.gratuity,
				extraFeesTotal: receipt.extraFeesTotal,
				otherFees: receipt.otherFees,
				gratuityPercent: receipt.gratuityPercent,
				canManage:
					(viewerTokenIdentifier !== undefined &&
						receipt.ownerTokenIdentifier === viewerTokenIdentifier) ||
					(viewerGuestDeviceId !== null &&
						viewerGuestDeviceId !== undefined &&
						receipt.guestDeviceId === viewerGuestDeviceId),
				items,
			};
		}),
	);
}

async function findExistingReceiptForOwner(
	ctx: MutationCtx,
	owner: ReceiptOwner,
	clientReceiptId: string,
) {
	if (owner.kind === "authenticated") {
		return await ctx.db
			.query("receipts")
			.withIndex("by_owner_clientReceiptId", (q) =>
				q
					.eq("ownerTokenIdentifier", owner.identity.tokenIdentifier)
					.eq("clientReceiptId", clientReceiptId),
			)
			.first();
	}

	return await ctx.db
		.query("receipts")
		.withIndex("by_guest_clientReceiptId", (q) =>
			q
				.eq("guestDeviceId", owner.guestDeviceId)
				.eq("clientReceiptId", clientReceiptId),
		)
		.first();
}

async function resolveReceiptOwner(
	ctx: MutationCtx,
	guestDeviceIdInput?: string,
): Promise<ReceiptOwner> {
	const identity = await ctx.auth.getUserIdentity();
	if (identity) {
		return {
			kind: "authenticated",
			identity,
		};
	}

	const guestDeviceId = normalizeGuestDeviceId(guestDeviceIdInput);
	if (!guestDeviceId) {
		throw new Error("Authentication required.");
	}

	return {
		kind: "guest",
		guestDeviceId,
	};
}

function normalizeGuestDeviceId(value?: string): string | null {
	if (!value) {
		return null;
	}

	const normalized = value.trim().toLowerCase();
	if (!GUEST_DEVICE_ID_REGEX.test(normalized)) {
		return null;
	}

	return normalized;
}

async function getActiveReceiptByCode(
	ctx: MutationCtx | QueryCtx,
	code: string,
): Promise<ReceiptRecord | null> {
	if (!SHARE_CODE_REGEX.test(code)) {
		return null;
	}

	const receipt = await ctx.db
		.query("receipts")
		.withIndex("by_shareCode", (q) => q.eq("shareCode", code))
		.first();

	if (!receipt) {
		return null;
	}

	return receipt;
}

async function resolveParticipantIdentityForMutation(
	ctx: MutationCtx,
	guestDeviceIdInput?: string,
): Promise<ReceiptParticipantIdentity> {
	const identity = await ctx.auth.getUserIdentity();
	if (identity) {
		return {
			participantKey: `auth:${identity.tokenIdentifier}`,
			tokenIdentifier: identity.tokenIdentifier,
			displayName: normalizedDisplayName(identity.name),
		};
	}

	const guestDeviceId = normalizeGuestDeviceId(guestDeviceIdInput);
	if (!guestDeviceId) {
		throw new Error("Authentication required.");
	}

	return {
		participantKey: `guest:${guestDeviceId}`,
		guestDeviceId,
		displayName: "Guest",
	};
}

async function resolveParticipantIdentityForQuery(
	ctx: QueryCtx,
	guestDeviceIdInput?: string,
): Promise<ReceiptParticipantIdentity | null> {
	const identity = await ctx.auth.getUserIdentity();
	if (identity) {
		return {
			participantKey: `auth:${identity.tokenIdentifier}`,
			tokenIdentifier: identity.tokenIdentifier,
			displayName: normalizedDisplayName(identity.name),
		};
	}

	const guestDeviceId = normalizeGuestDeviceId(guestDeviceIdInput);
	if (!guestDeviceId) {
		return null;
	}

	return {
		participantKey: `guest:${guestDeviceId}`,
		guestDeviceId,
		displayName: "Guest",
	};
}

async function upsertReceiptParticipant(
	ctx: MutationCtx,
	receiptId: Id<"receipts">,
	participant: ReceiptParticipantIdentity,
	now: number,
) {
	const existing = await ctx.db
		.query("receiptParticipants")
		.withIndex("by_receipt_participantKey", (q) =>
			q
				.eq("receiptId", receiptId)
				.eq("participantKey", participant.participantKey),
		)
		.first();

	if (existing) {
		await ctx.db.patch(existing._id, {
			tokenIdentifier: participant.tokenIdentifier,
			guestDeviceId: participant.guestDeviceId,
			displayName:
				normalizedDisplayName(existing.displayName) ?? participant.displayName,
			updatedAt: now,
		});
		return;
	}

	await ctx.db.insert("receiptParticipants", {
		receiptId,
		participantKey: participant.participantKey,
		tokenIdentifier: participant.tokenIdentifier,
		guestDeviceId: participant.guestDeviceId,
		displayName: participant.displayName,
		isSubmitted: false,
		joinedAt: now,
		updatedAt: now,
	});
}

async function resetReceiptParticipantsForClaiming(
	ctx: MutationCtx,
	receiptId: Id<"receipts">,
	now: number,
) {
	const participants = await ctx.db
		.query("receiptParticipants")
		.withIndex("by_receipt_joinedAt", (q) => q.eq("receiptId", receiptId))
		.collect();

	await Promise.all(
		participants.map((participant) =>
			ctx.db.patch(participant._id, {
				isSubmitted: false,
				submittedAt: undefined,
				paymentStatus: undefined,
				paymentMethod: undefined,
				paymentAmount: undefined,
				paymentMarkedAt: undefined,
				paymentConfirmedAt: undefined,
				updatedAt: now,
			}),
		),
	);
}

const GENERIC_DISPLAY_NAMES = new Set(["you", "guest", "friend"]);

function normalizedDisplayName(value?: string): string | undefined {
	if (!value) {
		return undefined;
	}

	const trimmed = value.trim();
	if (
		trimmed.length === 0 ||
		GENERIC_DISPLAY_NAMES.has(trimmed.toLowerCase())
	) {
		return undefined;
	}
	return trimmed;
}

function defaultParticipantDisplayName(participantKey: string): string {
	if (participantKey.startsWith("auth:")) {
		return "Friend";
	}

	return "Guest";
}

async function resolveParticipantPublicProfiles(
	ctx: QueryCtx,
	participants: Array<{ participantKey: string; tokenIdentifier?: string }>,
): Promise<Map<string, { name?: string; email?: string; avatarUrl?: string }>> {
	const tokenIdentifiers = Array.from(
		new Set(
			participants
				.map((participant) => participant.tokenIdentifier)
				.filter(
					(tokenIdentifier): tokenIdentifier is string =>
						typeof tokenIdentifier === "string" && tokenIdentifier.length > 0,
				),
		),
	);

	if (tokenIdentifiers.length === 0) {
		return new Map();
	}

	const profilesByToken = new Map<
		string,
		{ name?: string; email?: string; avatarUrl?: string }
	>();
	await Promise.all(
		tokenIdentifiers.map(async (tokenIdentifier) => {
			const user = await ctx.db
				.query("users")
				.withIndex("by_tokenIdentifier", (q) =>
					q.eq("tokenIdentifier", tokenIdentifier),
				)
				.first();
			if (!user) {
				return;
			}

			const avatarUrl = user.pictureStorageId
				? await ctx.storage.getUrl(user.pictureStorageId)
				: user.pictureUrl;
			profilesByToken.set(tokenIdentifier, {
				name: normalizedDisplayName(user.name),
				email: user.email,
				avatarUrl: avatarUrl ?? undefined,
			});
		}),
	);

	const profilesByParticipant = new Map<
		string,
		{ name?: string; email?: string; avatarUrl?: string }
	>();
	for (const participant of participants) {
		if (!participant.tokenIdentifier) {
			continue;
		}
		const profile = profilesByToken.get(participant.tokenIdentifier);
		if (profile) {
			profilesByParticipant.set(participant.participantKey, profile);
		}
	}

	return profilesByParticipant;
}

function makeItemKey(item: NormalizedReceiptItem, index: number): string {
	if (item.clientItemId && item.clientItemId.trim().length > 0) {
		return item.clientItemId;
	}

	return `sort:${item.sortOrder ?? index}`;
}

async function loadReceiptItems(
	ctx: MutationCtx | QueryCtx,
	receiptId: Id<"receipts">,
	legacyReceiptJson?: string,
	clientReceiptId?: string,
): Promise<Array<NormalizedReceiptItem>> {
	const normalizedItems = await ctx.db
		.query("receiptItems")
		.withIndex("by_receipt_sortOrder", (q) => q.eq("receiptId", receiptId))
		.order("asc")
		.collect();

	if (normalizedItems.length > 0) {
		return normalizedItems.map((item) => ({
			clientItemId: item.clientItemId,
			name: item.name,
			quantity: item.quantity,
			price: item.price,
			sortOrder: item.sortOrder,
		}));
	}

	if (!legacyReceiptJson) {
		return [];
	}

	return parseLegacyReceiptItems(legacyReceiptJson, clientReceiptId);
}

function parseLegacyReceiptItems(
	receiptJson: string,
	expectedClientReceiptId?: string,
): Array<NormalizedReceiptItem> {
	try {
		const parsed = JSON.parse(receiptJson) as unknown;
		if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
			return [];
		}

		const payload = parsed as {
			id?: unknown;
			clientReceiptId?: unknown;
			items?: unknown[];
			receipts?: unknown;
		};

		// Guard against aggregate payloads (e.g. entire receipt lists).
		if (Array.isArray(payload.receipts)) {
			return [];
		}

		const payloadClientReceiptId =
			typeof payload.clientReceiptId === "string"
				? payload.clientReceiptId
				: typeof payload.id === "string"
					? payload.id
					: undefined;

		if (
			expectedClientReceiptId &&
			payloadClientReceiptId &&
			payloadClientReceiptId !== expectedClientReceiptId
		) {
			return [];
		}

		const rawItems = Array.isArray(payload.items) ? payload.items : [];
		const normalized = rawItems
			.map((item, index) => normalizeLegacyItem(item, index))
			.filter((item) => item !== null);
		return normalized as Array<NormalizedReceiptItem>;
	} catch {
		return [];
	}
}

function normalizeLegacyItem(raw: unknown, index: number) {
	if (!raw || typeof raw !== "object") {
		return null;
	}

	const value = raw as {
		id?: unknown;
		name?: unknown;
		quantity?: unknown;
		price?: unknown;
	};

	if (typeof value.name !== "string" || value.name.trim().length === 0) {
		return null;
	}

	const quantity = toPositiveNumber(value.quantity, 1);
	const price =
		typeof value.price === "number" && Number.isFinite(value.price)
			? value.price
			: undefined;

	return {
		clientItemId: typeof value.id === "string" ? value.id : undefined,
		name: value.name,
		quantity,
		price,
		sortOrder: index,
	};
}

async function replaceReceiptItems(
	ctx: MutationCtx,
	receiptId: Id<"receipts">,
	items: Array<{
		clientItemId?: string;
		name: string;
		quantity: number;
		price?: number | null;
		sortOrder: number;
	}>,
	now: number,
) {
	const existingItems = await ctx.db
		.query("receiptItems")
		.withIndex("by_receipt_sortOrder", (q) => q.eq("receiptId", receiptId))
		.collect();

	const existingClaims = await ctx.db
		.query("receiptClaims")
		.withIndex("by_receipt_itemKey", (q) => q.eq("receiptId", receiptId))
		.collect();

	await Promise.all([
		...existingItems.map((item) => ctx.db.delete(item._id)),
		...existingClaims.map((claim) => ctx.db.delete(claim._id)),
	]);

	const normalized = items
		.map((item, index) => ({
			clientItemId: item.clientItemId,
			name: item.name.trim(),
			quantity: toPositiveNumber(item.quantity, 1),
			price:
				typeof item.price === "number" && Number.isFinite(item.price)
					? item.price
					: undefined,
			sortOrder: toPositiveNumber(item.sortOrder, index),
		}))
		.filter((item) => item.name.length > 0);

	for (const item of normalized) {
		await ctx.db.insert("receiptItems", {
			receiptId,
			clientItemId: item.clientItemId,
			name: item.name,
			quantity: item.quantity,
			price: item.price,
			sortOrder: item.sortOrder,
			createdAt: now,
		});
	}
}

function toPositiveNumber(value: unknown, fallback: number) {
	if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
		return fallback;
	}
	return value;
}

function normalizeMoney(value?: number | null): number | undefined {
	if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
		return undefined;
	}
	return roundCurrency(value);
}

function roundCurrency(value: number): number {
	return Math.round(value * 100) / 100;
}

function computeExtraFeesTotal(
	receiptTotal: number | undefined,
	items: Array<{ price?: number | null }>,
	tax?: number,
	gratuity?: number,
): number {
	const itemTotal = roundCurrency(
		items.reduce((sum, item) => {
			const lineTotal =
				typeof item.price === "number" && Number.isFinite(item.price)
					? item.price
					: 0;
			return sum + lineTotal;
		}, 0),
	);
	const explicitFees = roundCurrency((tax ?? 0) + (gratuity ?? 0));

	if (typeof receiptTotal === "number" && Number.isFinite(receiptTotal)) {
		return Math.max(0, roundCurrency(receiptTotal - itemTotal));
	}

	return Math.max(0, explicitFees);
}

function computeOtherFees(
	extraFeesTotal: number,
	tax?: number,
	gratuity?: number,
): number | undefined {
	const result = roundCurrency(extraFeesTotal - (tax ?? 0) - (gratuity ?? 0));
	return result >= 0 ? result : undefined;
}

function computeGratuityPercent(
	gratuity?: number,
	subtotal?: number,
): number | undefined {
	if (
		typeof gratuity !== "number" ||
		gratuity <= 0 ||
		typeof subtotal !== "number" ||
		subtotal <= 0
	) {
		return undefined;
	}
	return Math.round((gratuity / subtotal) * 10000) / 100;
}

async function resolveHostDisplayName(
	ctx: QueryCtx | MutationCtx,
	receipt: ReceiptRecord,
	hostParticipantKey: string | undefined,
	participantRows: Array<{ participantKey: string; displayName?: string }>,
): Promise<string | undefined> {
	// Try from participant row first
	if (hostParticipantKey) {
		const hostRow = participantRows.find(
			(p) => p.participantKey === hostParticipantKey,
		);
		const hostRowName = normalizedDisplayName(hostRow?.displayName);
		if (
			hostRowName &&
			hostRowName !== "You" &&
			hostRowName !== "Guest" &&
			hostRowName !== "Friend"
		) {
			return hostRowName;
		}
	}

	// Try from owner user record
	if (receipt.ownerTokenIdentifier) {
		const owner = await ctx.db
			.query("users")
			.withIndex("by_tokenIdentifier", (q) =>
				q.eq("tokenIdentifier", receipt.ownerTokenIdentifier!),
			)
			.first();
		const ownerName = normalizedDisplayName(owner?.name);
		if (ownerName) {
			return ownerName;
		}
	}

	return undefined;
}

function hostParticipantKeyForReceipt(receipt: {
	ownerTokenIdentifier?: string;
	guestDeviceId?: string;
}): string | undefined {
	if (receipt.ownerTokenIdentifier) {
		return `auth:${receipt.ownerTokenIdentifier}`;
	}
	if (receipt.guestDeviceId) {
		return `guest:${receipt.guestDeviceId}`;
	}
	return undefined;
}

async function assertOwnerCanManageReceipt(
	ctx: MutationCtx,
	receipt: ReceiptRecord,
	guestDeviceIdInput?: string,
) {
	const identity = await ctx.auth.getUserIdentity();
	if (identity && receipt.ownerTokenIdentifier === identity.tokenIdentifier) {
		return;
	}

	const normalizedGuestDeviceId = normalizeGuestDeviceId(guestDeviceIdInput);
	if (
		normalizedGuestDeviceId &&
		receipt.guestDeviceId === normalizedGuestDeviceId
	) {
		return;
	}

	throw new Error("Only the host can perform this action.");
}

async function resolveHostPaymentConfig(
	ctx: QueryCtx | MutationCtx,
	ownerTokenIdentifier?: string,
): Promise<{
	hasPaymentOptions: boolean;
	absorbExtraCents: boolean;
	preferredPaymentMethod?: string;
	venmoEnabled: boolean;
	venmoUsername?: string;
	cashAppEnabled: boolean;
	cashAppCashtag?: string;
	zelleEnabled: boolean;
	zelleContact?: string;
	cashApplePayEnabled: boolean;
}> {
	if (!ownerTokenIdentifier) {
		// Guest hosts can always settle manually.
		return {
			hasPaymentOptions: true,
			absorbExtraCents: true,
			preferredPaymentMethod: "cash_apple_pay",
			venmoEnabled: false,
			venmoUsername: undefined,
			cashAppEnabled: false,
			cashAppCashtag: undefined,
			zelleEnabled: false,
			zelleContact: undefined,
			cashApplePayEnabled: true,
		};
	}

	const owner = await ctx.db
		.query("users")
		.withIndex("by_tokenIdentifier", (q) =>
			q.eq("tokenIdentifier", ownerTokenIdentifier),
		)
		.first();

	if (!owner) {
		return {
			hasPaymentOptions: false,
			absorbExtraCents: false,
			preferredPaymentMethod: undefined,
			venmoEnabled: false,
			venmoUsername: undefined,
			cashAppEnabled: false,
			cashAppCashtag: undefined,
			zelleEnabled: false,
			zelleContact: undefined,
			cashApplePayEnabled: false,
		};
	}

	const hasVenmo =
		owner.venmoEnabled === true &&
		typeof owner.venmoUsername === "string" &&
		owner.venmoUsername.trim().length > 0;
	const hasCashApp =
		owner.cashAppEnabled === true &&
		typeof owner.cashAppCashtag === "string" &&
		owner.cashAppCashtag.trim().length > 0;
	const hasZelle =
		owner.zelleEnabled === true &&
		typeof owner.zelleContact === "string" &&
		owner.zelleContact.trim().length > 0;
	const hasCashApplePay = owner.cashApplePayEnabled === true;

	return {
		hasPaymentOptions: hasVenmo || hasCashApp || hasZelle || hasCashApplePay,
		absorbExtraCents: owner.absorbExtraCents === true,
		preferredPaymentMethod: owner.preferredPaymentMethod,
		venmoEnabled: owner.venmoEnabled === true,
		venmoUsername: owner.venmoUsername?.trim() || undefined,
		cashAppEnabled: owner.cashAppEnabled === true,
		cashAppCashtag: owner.cashAppCashtag?.trim() || undefined,
		zelleEnabled: owner.zelleEnabled === true,
		zelleContact: owner.zelleContact?.trim() || undefined,
		cashApplePayEnabled: owner.cashApplePayEnabled === true,
	};
}

function computeParticipantSettlementTotals(
	participants: Array<{ participantKey: string; joinedAt: number }>,
	participantItemSubtotals: Map<string, number>,
	// The receipt's authoritative subtotal — used as the denominator so that
	// taxRate = tax / receiptSubtotal is the same for every participant.
	receiptSubtotal: number,
	extraFeesTotal: number,
	tax: number | undefined,
	gratuity: number | undefined,
	hostParticipantKey: string | undefined,
	absorbExtraCents: boolean,
) {
	const totals = new Map<
		string,
		{
			itemSubtotal: number;
			taxShare: number;
			gratuityShare: number;
			extraFeesShare: number;
			roundingAdjustment: number;
			totalDue: number;
		}
	>();
	if (participants.length === 0) {
		return totals;
	}

	const participantCount = participants.length;
	// The receipt's subtotal is the authoritative denominator — it's what the
	// restaurant used to compute tax. Using it ensures every participant pays
	// the same tax rate (tax / receiptSubtotal) on their claimed items.
	// Fall back to the sum of claimed items when no subtotal is available.
	const totalClaimedItemSubtotal = roundCurrency(
		Array.from(participantItemSubtotals.values()).reduce((s, v) => s + v, 0),
	);
	const proportionalBase =
		receiptSubtotal > 0
			? receiptSubtotal
			: totalClaimedItemSubtotal > 0
				? totalClaimedItemSubtotal
				: 0;
	const canSplitProportionally = proportionalBase > 0;
	const hasFeeBreakdown = tax !== undefined || gratuity !== undefined;

	const taxCents = Math.max(0, Math.round((tax ?? 0) * 100));
	const gratuityCents = Math.max(0, Math.round((gratuity ?? 0) * 100));
	const extraFeesCents = Math.max(0, Math.round(extraFeesTotal * 100));

	// When proportionalBase comes from receiptSubtotal (which may be larger than
	// claimed items), only distribute the portion of fees attributable to
	// claimed items.  This prevents the remainder logic from dumping unclaimed-
	// item fees onto the host.  The claim ratio ensures each participant still
	// pays the same effective rate (e.g. tax / subtotal) on their items.
	const claimRatio =
		proportionalBase > 0 ? totalClaimedItemSubtotal / proportionalBase : 0;

	let perTax: Map<string, number>;
	let perGratuity: Map<string, number>;
	let perOther: Map<string, number>;

	if (canSplitProportionally && hasFeeBreakdown) {
		// Best case: split tax/gratuity proportionally by claimed-item share
		const otherCents = Math.max(0, extraFeesCents - taxCents - gratuityCents);
		const claimedTaxCents = Math.round(taxCents * claimRatio);
		const claimedGratuityCents = Math.round(gratuityCents * claimRatio);
		const claimedOtherCents = Math.round(otherCents * claimRatio);
		perTax = distributeProportionalCents(
			claimedTaxCents,
			totalClaimedItemSubtotal,
			participants,
			participantItemSubtotals,
			hostParticipantKey,
			absorbExtraCents,
		);
		perGratuity = distributeProportionalCents(
			claimedGratuityCents,
			totalClaimedItemSubtotal,
			participants,
			participantItemSubtotals,
			hostParticipantKey,
			absorbExtraCents,
		);
		perOther = distributeProportionalCents(
			claimedOtherCents,
			totalClaimedItemSubtotal,
			participants,
			participantItemSubtotals,
			hostParticipantKey,
			absorbExtraCents,
		);
	} else if (canSplitProportionally) {
		// No fee breakdown: split claimed portion of extraFeesTotal proportionally
		const claimedExtraFeesCents = Math.round(extraFeesCents * claimRatio);
		perTax = zeroCents(participants);
		perGratuity = zeroCents(participants);
		perOther = distributeProportionalCents(
			claimedExtraFeesCents,
			totalClaimedItemSubtotal,
			participants,
			participantItemSubtotals,
			hostParticipantKey,
			absorbExtraCents,
		);
	} else if (hasFeeBreakdown) {
		// No item subtotals: even split per component
		const otherCents = Math.max(0, extraFeesCents - taxCents - gratuityCents);
		perTax = distributeEvenCents(
			taxCents,
			participants,
			participantItemSubtotals,
			hostParticipantKey,
			absorbExtraCents,
		);
		perGratuity = distributeEvenCents(
			gratuityCents,
			participants,
			participantItemSubtotals,
			hostParticipantKey,
			absorbExtraCents,
		);
		perOther = distributeEvenCents(
			otherCents,
			participants,
			participantItemSubtotals,
			hostParticipantKey,
			absorbExtraCents,
		);
	} else {
		// Truly unattributable: even split of full extraFeesTotal
		perTax = zeroCents(participants);
		perGratuity = zeroCents(participants);
		perOther = distributeEvenCents(
			extraFeesCents,
			participants,
			participantItemSubtotals,
			hostParticipantKey,
			absorbExtraCents,
		);
	}

	// Compute the actual total of distributed extra-fee cents (after claimRatio
	// scaling) so the rounding adjustment reflects the true even-share baseline,
	// not the full receipt fees.
	let actualDistributedCents = 0;
	for (const p of participants) {
		actualDistributedCents +=
			(perTax.get(p.participantKey) ?? 0) +
			(perGratuity.get(p.participantKey) ?? 0) +
			(perOther.get(p.participantKey) ?? 0);
	}
	const baseExtraShareCents =
		participantCount > 0
			? Math.floor(actualDistributedCents / participantCount)
			: 0;

	for (const participant of participants) {
		const itemSubtotal = roundCurrency(
			participantItemSubtotals.get(participant.participantKey) ?? 0,
		);
		const tCents = perTax.get(participant.participantKey) ?? 0;
		const gCents = perGratuity.get(participant.participantKey) ?? 0;
		const oCents = perOther.get(participant.participantKey) ?? 0;
		const totalExtraCents = tCents + gCents + oCents;

		totals.set(participant.participantKey, {
			itemSubtotal,
			taxShare: roundCurrency(tCents / 100),
			gratuityShare: roundCurrency(gCents / 100),
			extraFeesShare: roundCurrency(totalExtraCents / 100),
			roundingAdjustment: roundCurrency(
				(totalExtraCents - baseExtraShareCents) / 100,
			),
			totalDue: roundCurrency(itemSubtotal + totalExtraCents / 100),
		});
	}

	return totals;
}

function distributeProportionalCents(
	totalCents: number,
	totalClaimedItemSubtotal: number,
	participants: Array<{ participantKey: string; joinedAt: number }>,
	participantItemSubtotals: Map<string, number>,
	hostParticipantKey: string | undefined,
	absorbExtraCents: boolean,
): Map<string, number> {
	const result = new Map<string, number>();
	if (totalCents <= 0 || participants.length === 0) {
		for (const p of participants) {
			result.set(p.participantKey, 0);
		}
		return result;
	}

	let allocated = 0;
	for (const participant of participants) {
		const itemSubtotal =
			participantItemSubtotals.get(participant.participantKey) ?? 0;
		const ratio =
			totalClaimedItemSubtotal > 0
				? itemSubtotal / totalClaimedItemSubtotal
				: 0;
		const share = Math.floor(totalCents * ratio);
		result.set(participant.participantKey, share);
		allocated += share;
	}

	const remainder = totalCents - allocated;
	if (remainder > 0) {
		const recipientKey = selectRemainderRecipientForCents(
			participants,
			participantItemSubtotals,
			hostParticipantKey,
			absorbExtraCents,
		);
		if (recipientKey) {
			result.set(
				recipientKey,
				(result.get(recipientKey) ?? 0) + remainder,
			);
		}
	}

	return result;
}

function distributeEvenCents(
	totalCents: number,
	participants: Array<{ participantKey: string; joinedAt: number }>,
	participantItemSubtotals: Map<string, number>,
	hostParticipantKey: string | undefined,
	absorbExtraCents: boolean,
): Map<string, number> {
	const result = new Map<string, number>();
	if (totalCents <= 0 || participants.length === 0) {
		for (const p of participants) {
			result.set(p.participantKey, 0);
		}
		return result;
	}

	const baseShare = Math.floor(totalCents / participants.length);
	for (const participant of participants) {
		result.set(participant.participantKey, baseShare);
	}

	const remainder = totalCents - baseShare * participants.length;
	if (remainder > 0) {
		const recipientKey = selectRemainderRecipientForCents(
			participants,
			participantItemSubtotals,
			hostParticipantKey,
			absorbExtraCents,
		);
		if (recipientKey) {
			result.set(
				recipientKey,
				(result.get(recipientKey) ?? 0) + remainder,
			);
		}
	}

	return result;
}

function zeroCents(
	participants: Array<{ participantKey: string }>,
): Map<string, number> {
	const result = new Map<string, number>();
	for (const p of participants) {
		result.set(p.participantKey, 0);
	}
	return result;
}

function selectRemainderRecipientForCents(
	participants: Array<{ participantKey: string; joinedAt: number }>,
	participantItemSubtotals: Map<string, number>,
	hostParticipantKey: string | undefined,
	absorbExtraCents: boolean,
): string | undefined {
	if (absorbExtraCents && hostParticipantKey) {
		const hasHost = participants.some(
			(p) => p.participantKey === hostParticipantKey,
		);
		if (hasHost) {
			return hostParticipantKey;
		}
	}
	return selectRemainderRecipient(
		participants,
		participantItemSubtotals,
		hostParticipantKey,
	);
}

function selectRemainderRecipient(
	participants: Array<{ participantKey: string; joinedAt: number }>,
	participantItemSubtotals: Map<string, number>,
	hostParticipantKey: string | undefined,
): string | undefined {
	const candidateParticipants = participants.filter((participant) => {
		if (!hostParticipantKey) {
			return true;
		}
		const nonHostCount = participants.filter(
			(row) => row.participantKey !== hostParticipantKey,
		).length;
		if (nonHostCount === 0) {
			return true;
		}
		return participant.participantKey !== hostParticipantKey;
	});

	if (candidateParticipants.length === 0) {
		return participants[0]?.participantKey;
	}

	return candidateParticipants.slice().sort((a, b) => {
		const subtotalDelta =
			(participantItemSubtotals.get(b.participantKey) ?? 0) -
			(participantItemSubtotals.get(a.participantKey) ?? 0);
		if (Math.abs(subtotalDelta) > 0.00001) {
			return subtotalDelta;
		}
		return a.joinedAt - b.joinedAt;
	})[0]?.participantKey;
}

async function computeParticipantSettlementTotalsFromClaims(
	ctx: MutationCtx,
	receipt: ReceiptRecord,
	items: Array<NormalizedReceiptItem>,
	participants: Array<{ participantKey: string; joinedAt: number }>,
	claims: Array<{ itemKey: string; participantKey: string; quantity: number }>,
) {
	const unitPriceByItemKey = new Map(
		items.map((item, index) => {
			const key = makeItemKey(item, index);
			const unitPrice = (item.price ?? 0) / Math.max(1, item.quantity);
			return [key, unitPrice] as const;
		}),
	);
	const participantSubtotals = new Map<string, number>();
	for (const claim of claims) {
		participantSubtotals.set(
			claim.participantKey,
			(participantSubtotals.get(claim.participantKey) ?? 0) +
				claim.quantity * (unitPriceByItemKey.get(claim.itemKey) ?? 0),
		);
	}

	const computedItemSubtotal = roundCurrency(
		items.reduce(
			(sum, item) =>
				sum +
				(typeof item.price === "number" && Number.isFinite(item.price)
					? item.price
					: 0),
			0,
		),
	);
	const receiptSubtotal =
		typeof receipt.subtotal === "number" &&
		Number.isFinite(receipt.subtotal) &&
		receipt.subtotal > 0
			? receipt.subtotal
			: computedItemSubtotal;

	const hostPaymentConfig = await resolveHostPaymentConfig(
		ctx,
		receipt.ownerTokenIdentifier,
	);
	const extraFeesTotal =
		receipt.extraFeesTotal ??
		computeExtraFeesTotal(
			receipt.receiptTotal,
			items,
			receipt.tax,
			receipt.gratuity,
		);
	return computeParticipantSettlementTotals(
		participants,
		participantSubtotals,
		receiptSubtotal,
		extraFeesTotal,
		receipt.tax,
		receipt.gratuity,
		hostParticipantKeyForReceipt(receipt),
		hostPaymentConfig.absorbExtraCents,
	);
}

async function requireIdentity(ctx: MutationCtx): Promise<AuthIdentity> {
	const identity = await ctx.auth.getUserIdentity();
	if (!identity) {
		throw new Error("Authentication required.");
	}
	return identity;
}

async function upsertUserFromIdentity(
	ctx: MutationCtx,
	identity: AuthIdentity,
	now: number,
) {
	const existingUser = await ctx.db
		.query("users")
		.withIndex("by_tokenIdentifier", (q) =>
			q.eq("tokenIdentifier", identity.tokenIdentifier),
		)
		.first();

	const patch = {
		subject: identity.subject,
		issuer: identity.issuer,
		name: identity.name,
		email: identity.email,
		pictureUrl: identity.pictureUrl,
		updatedAt: now,
		lastSeenAt: now,
	};

	if (existingUser) {
		await ctx.db.patch(existingUser._id, patch);
		return;
	}

	await ctx.db.insert("users", {
		tokenIdentifier: identity.tokenIdentifier,
		...patch,
		createdAt: now,
	});
}

async function generateUniqueShareCode(ctx: MutationCtx): Promise<string> {
	for (let attempt = 0; attempt < MAX_CODE_ATTEMPTS; attempt += 1) {
		const candidate = makeCode(CODE_LENGTH);
		const existing = await ctx.db
			.query("receipts")
			.withIndex("by_shareCode", (q) => q.eq("shareCode", candidate))
			.first();

		if (!existing) {
			return candidate;
		}
	}

	throw new Error("Could not generate unique share code");
}

function makeCode(length: number): string {
	let value = "";
	for (let i = 0; i < length; i += 1) {
		value += Math.floor(Math.random() * 10).toString();
	}
	return value;
}
