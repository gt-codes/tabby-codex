import { mutation, query, type MutationCtx } from "./_generated/server";
import { v } from "convex/values";
import {
	FREE_BILLS_PER_PERIOD,
	deriveBillingUsageState,
	usageStateToPatch,
} from "./billingShared";

const BILL_CREDIT_PACKS: Record<string, number> = {
	"com.splt.billcredits.1": 1,
	"com.splt.billcredits.5": 5,
};

type AuthIdentity = {
	tokenIdentifier: string;
	subject: string;
	issuer: string;
	name?: string;
	email?: string;
	pictureUrl?: string;
};

export const getUsageSummary = query({
	args: {},
	handler: async (ctx) => {
		const identity = await ctx.auth.getUserIdentity();
		if (!identity) {
			throw new Error("Authentication required.");
		}

		const now = Date.now();
		const user = await ctx.db
			.query("users")
			.withIndex("by_tokenIdentifier", (q) =>
				q.eq("tokenIdentifier", identity.tokenIdentifier),
			)
			.first();

		const usage = deriveBillingUsageState(
			{
				createdAt: user?.createdAt ?? now,
				freeBillsUsedInPeriod: user?.freeBillsUsedInPeriod,
				currentPeriodStartAt: user?.currentPeriodStartAt,
				currentPeriodEndAt: user?.currentPeriodEndAt,
				billCreditsBalance: user?.billCreditsBalance,
			},
			now,
		);

		const freeRemaining = Math.max(
			0,
			FREE_BILLS_PER_PERIOD - usage.freeBillsUsedInPeriod,
		);

		return {
			freeLimit: FREE_BILLS_PER_PERIOD,
			freeUsed: usage.freeBillsUsedInPeriod,
			freeRemaining,
			periodStartAt: usage.currentPeriodStartAt,
			periodEndAt: usage.currentPeriodEndAt,
			billCreditsBalance: usage.billCreditsBalance,
			canHostNewBill: freeRemaining > 0 || usage.billCreditsBalance > 0,
		};
	},
});

export const redeemCreditPurchase = mutation({
	args: {
		transactionId: v.string(),
		productId: v.string(),
		purchasedAt: v.optional(v.number()),
	},
	handler: async (ctx, args) => {
		const identity = await ctx.auth.getUserIdentity();
		if (!identity) {
			throw new Error("Authentication required.");
		}

		const transactionId = args.transactionId.trim();
		const productId = args.productId.trim();
		if (!transactionId) {
			throw new Error("INVALID_TRANSACTION_ID");
		}
		const creditsGranted = BILL_CREDIT_PACKS[productId];
		if (!creditsGranted) {
			throw new Error("UNKNOWN_BILL_CREDIT_PRODUCT");
		}

		const now = Date.now();
		const existingRedemption = await ctx.db
			.query("billCreditPurchases")
			.withIndex("by_transactionId", (q) => q.eq("transactionId", transactionId))
			.first();

		const user = await upsertBillingUser(ctx, identity, now);
		const usage = deriveBillingUsageState(user, now);

		if (existingRedemption) {
			if (existingRedemption.tokenIdentifier !== identity.tokenIdentifier) {
				throw new Error("PURCHASE_ALREADY_REDEEMED");
			}

			return {
				applied: false,
				transactionId,
				creditsGranted: existingRedemption.creditsGranted,
				billCreditsBalance: usage.billCreditsBalance,
			};
		}

		const updatedUsage = {
			...usage,
			billCreditsBalance: usage.billCreditsBalance + creditsGranted,
		};
		await ctx.db.patch(user._id, {
			...usageStateToPatch(updatedUsage),
			updatedAt: now,
			lastSeenAt: now,
		});
		await ctx.db.insert("billCreditPurchases", {
			tokenIdentifier: identity.tokenIdentifier,
			transactionId,
			productId,
			creditsGranted,
			purchasedAt: args.purchasedAt ?? now,
			createdAt: now,
		});

		return {
			applied: true,
			transactionId,
			creditsGranted,
			billCreditsBalance: updatedUsage.billCreditsBalance,
		};
	},
});

async function upsertBillingUser(
	ctx: MutationCtx,
	identity: AuthIdentity,
	now: number,
) {
	const existing = await ctx.db
		.query("users")
		.withIndex("by_tokenIdentifier", (q) =>
			q.eq("tokenIdentifier", identity.tokenIdentifier),
		)
		.first();

	if (existing) {
		const patch: {
			subject: string;
			issuer: string;
			email?: string;
			pictureUrl?: string;
			updatedAt: number;
			lastSeenAt: number;
			name?: string;
		} = {
			subject: identity.subject,
			issuer: identity.issuer,
			email: identity.email,
			pictureUrl: identity.pictureUrl,
			updatedAt: now,
			lastSeenAt: now,
		};
		if (!existing.name && identity.name) {
			patch.name = identity.name;
		}
		await ctx.db.patch(existing._id, patch);
		const updated = await ctx.db.get(existing._id);
		if (!updated) {
			throw new Error("Failed to update billing user.");
		}
		return updated;
	}

	const id = await ctx.db.insert("users", {
		tokenIdentifier: identity.tokenIdentifier,
		subject: identity.subject,
		issuer: identity.issuer,
		name: identity.name,
		email: identity.email,
		pictureUrl: identity.pictureUrl,
		createdAt: now,
		updatedAt: now,
		lastSeenAt: now,
		...usageStateToPatch(deriveBillingUsageState({ createdAt: now }, now)),
	});
	const inserted = await ctx.db.get(id);
	if (!inserted) {
		throw new Error("Failed to create billing user.");
	}
	return inserted;
}
