import { mutation, query, MutationCtx, QueryCtx } from "./_generated/server";
import { v } from "convex/values";
import type { Id } from "./_generated/dataModel";

const CODE_LENGTH = 6;
const MAX_CODE_ATTEMPTS = 20;
const GUEST_DEVICE_ID_REGEX = /^[0-9a-fA-F-]{36}$/;

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

export const create = mutation({
  args: {
    clientReceiptId: v.string(),
    items: v.array(receiptItemInput),
    ...receiptOwnerArgs,
  },
  handler: async (ctx, args) => {
    const owner = await resolveReceiptOwner(ctx, args.guestDeviceId);
    const now = Date.now();

    if (owner.kind === "authenticated") {
      await upsertUserFromIdentity(ctx, owner.identity, now);
    }

    const existing = await findExistingReceiptForOwner(ctx, owner, args.clientReceiptId);
    if (existing) {
      await ctx.db.patch(existing._id, {
        isActive: true,
        updatedAt: now,
      });
      await replaceReceiptItems(ctx, existing._id, args.items, now);

      return {
        id: existing._id,
        code: existing.shareCode,
      };
    }

    const shareCode = await generateUniqueShareCode(ctx);
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
    if (!/^\d{6}$/.test(args.code)) {
      return null;
    }

    const receipt = await ctx.db
      .query("receipts")
      .withIndex("by_shareCode", (q) => q.eq("shareCode", args.code))
      .first();

    if (!receipt || receipt.isActive === false) {
      return null;
    }

    const items = await loadReceiptItems(ctx, receipt._id, receipt.receiptJson);
    return {
      id: receipt._id,
      code: receipt.shareCode,
      clientReceiptId: receipt.clientReceiptId,
      createdAt: receipt.createdAt,
      isActive: receipt.isActive ?? true,
      items,
    };
  },
});

export const listRecent = query({
  args: {
    limit: v.optional(v.number()),
    ...receiptOwnerArgs,
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    const limit = Math.max(1, Math.min(Math.floor(args.limit ?? 30), 100));

    if (identity) {
      const receipts = await ctx.db
        .query("receipts")
        .withIndex("by_owner_active_createdAt", (q) =>
          q.eq("ownerTokenIdentifier", identity.tokenIdentifier).eq("isActive", true),
        )
        .order("desc")
        .take(limit);

      return await mapReceiptsForQuery(ctx, receipts);
    }

    const guestDeviceId = normalizeGuestDeviceId(args.guestDeviceId);
    if (!guestDeviceId) {
      return [];
    }

    const receipts = await ctx.db
      .query("receipts")
      .withIndex("by_guest_active_createdAt", (q) => q.eq("guestDeviceId", guestDeviceId).eq("isActive", true))
      .order("desc")
      .take(limit);

    return await mapReceiptsForQuery(ctx, receipts);
  },
});

export const archive = mutation({
  args: {
    clientReceiptId: v.string(),
    ...receiptOwnerArgs,
  },
  handler: async (ctx, args) => {
    const owner = await resolveReceiptOwner(ctx, args.guestDeviceId);
    const existing = await findExistingReceiptForOwner(ctx, owner, args.clientReceiptId);

    if (!existing) {
      return { archived: false };
    }

    await ctx.db.patch(existing._id, {
      isActive: false,
      updatedAt: Date.now(),
    });

    return { archived: true };
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

    const guestReceipts = await ctx.db
      .query("receipts")
      .withIndex("by_guestDeviceId", (q) => q.eq("guestDeviceId", guestDeviceId))
      .collect();

    for (const receipt of guestReceipts) {
      await ctx.db.patch(receipt._id, {
        ownerTokenIdentifier: identity.tokenIdentifier,
        ownerSubject: identity.subject,
        ownerIssuer: identity.issuer,
        guestDeviceId: undefined,
        updatedAt: now,
      });
    }

    return { migratedCount: guestReceipts.length };
  },
});

async function mapReceiptsForQuery(
  ctx: QueryCtx,
  receipts: Array<{
    _id: Id<"receipts">;
    shareCode: string;
    clientReceiptId: string;
    createdAt: number;
    isActive?: boolean;
    receiptJson?: string;
  }>,
) {
  return await Promise.all(
    receipts.map(async (receipt) => {
      const items = await loadReceiptItems(ctx, receipt._id, receipt.receiptJson);
      return {
        id: receipt._id,
        code: receipt.shareCode,
        clientReceiptId: receipt.clientReceiptId,
        createdAt: receipt.createdAt,
        isActive: receipt.isActive ?? true,
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
        q.eq("ownerTokenIdentifier", owner.identity.tokenIdentifier).eq("clientReceiptId", clientReceiptId),
      )
      .first();
  }

  return await ctx.db
    .query("receipts")
    .withIndex("by_guest_clientReceiptId", (q) =>
      q.eq("guestDeviceId", owner.guestDeviceId).eq("clientReceiptId", clientReceiptId),
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

async function loadReceiptItems(
  ctx: QueryCtx,
  receiptId: Id<"receipts">,
  legacyReceiptJson?: string,
) {
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

  // Legacy fallback for older receipts saved as receiptJson.
  try {
    const parsed = JSON.parse(legacyReceiptJson) as { items?: unknown[] };
    const rawItems = Array.isArray(parsed.items) ? parsed.items : [];
    const normalized = rawItems
      .map((item, index) => normalizeLegacyItem(item, index))
      .filter((item) => item !== null);
    return normalized as Array<{
      clientItemId?: string;
      name: string;
      quantity: number;
      price?: number;
      sortOrder: number;
    }>;
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
  const price = typeof value.price === "number" && Number.isFinite(value.price) ? value.price : undefined;

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

  await Promise.all(existingItems.map((item) => ctx.db.delete(item._id)));

  const normalized = items
    .map((item, index) => ({
      clientItemId: item.clientItemId,
      name: item.name.trim(),
      quantity: toPositiveNumber(item.quantity, 1),
      price: typeof item.price === "number" && Number.isFinite(item.price) ? item.price : undefined,
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
    .withIndex("by_tokenIdentifier", (q) => q.eq("tokenIdentifier", identity.tokenIdentifier))
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
