import { mutation, query, MutationCtx } from "./_generated/server";
import { v } from "convex/values";

const CODE_LENGTH = 6;
const MAX_CODE_ATTEMPTS = 20;

export const create = mutation({
  args: {
    clientReceiptId: v.string(),
    receiptJson: v.string(),
  },
  handler: async (ctx, args) => {
    const now = Date.now();

    const existing = await ctx.db
      .query("receipts")
      .withIndex("by_clientReceiptId", (q) => q.eq("clientReceiptId", args.clientReceiptId))
      .first();

    if (existing) {
      await ctx.db.patch(existing._id, {
        receiptJson: args.receiptJson,
        updatedAt: now,
      });

      return {
        id: existing._id,
        code: existing.shareCode,
      };
    }

    const shareCode = await generateUniqueShareCode(ctx);
    const id = await ctx.db.insert("receipts", {
      clientReceiptId: args.clientReceiptId,
      shareCode,
      receiptJson: args.receiptJson,
      createdAt: now,
      updatedAt: now,
    });

    return { id, code: shareCode };
  },
});

export const get = query({
  args: {
    code: v.string(),
  },
  handler: async (ctx, args) => {
    if (!/^\d{6}$/.test(args.code)) {
      return null;
    }

    const receipt = await ctx.db
      .query("receipts")
      .withIndex("by_shareCode", (q) => q.eq("shareCode", args.code))
      .first();

    if (!receipt) {
      return null;
    }

    return receipt.receiptJson;
  },
});

export const listRecent = query({
  args: {
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const limit = Math.min(args.limit ?? 30, 100);
    const receipts = await ctx.db
      .query("receipts")
      .withIndex("by_createdAt")
      .order("desc")
      .take(limit);

    return receipts.map((receipt) => ({
      id: receipt._id,
      code: receipt.shareCode,
      receiptJson: receipt.receiptJson,
      createdAt: receipt.createdAt,
      clientReceiptId: receipt.clientReceiptId,
    }));
  },
});

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
