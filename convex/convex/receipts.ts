import { mutation, query, MutationCtx, QueryCtx } from "./_generated/server";
import { v } from "convex/values";
import type { Id } from "./_generated/dataModel";

const CODE_LENGTH = 6;
const MAX_CODE_ATTEMPTS = 20;
const GUEST_DEVICE_ID_REGEX = /^[0-9a-fA-F-]{36}$/;
const SHARE_CODE_REGEX = /^\d{6}$/;

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
      await ctx.db.patch(existing._id, {
        isActive: true,
        // Legacy JSON can contain stale shapes from older builds.
        // Clear it so reads come from normalized receiptItems only.
        receiptJson: undefined,
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
    const participant = await resolveParticipantIdentityForMutation(
      ctx,
      args.guestDeviceId,
    );
    await upsertReceiptParticipant(ctx, receipt._id, participant, now);

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

    const [items, participants, claims, viewerParticipant] = await Promise.all([
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
      resolveParticipantIdentityForQuery(ctx, args.guestDeviceId),
    ]);

    const claimedByItemKey = new Map<string, number>();
    const viewerClaimedByItemKey = new Map<string, number>();

    for (const claim of claims) {
      claimedByItemKey.set(
        claim.itemKey,
        (claimedByItemKey.get(claim.itemKey) ?? 0) + claim.quantity,
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

    return {
      id: receipt._id,
      code: receipt.shareCode,
      clientReceiptId: receipt.clientReceiptId,
      createdAt: receipt.createdAt,
      isActive: receipt.isActive ?? true,
      viewerParticipantKey: viewerParticipant?.participantKey,
      participants: participants.map((participant) => ({
        participantKey: participant.participantKey,
        displayName:
          participant.displayName ??
          defaultParticipantDisplayName(participant.participantKey),
        joinedAt: participant.joinedAt,
      })),
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

    const now = Date.now();
    const participant = await resolveParticipantIdentityForMutation(
      ctx,
      args.guestDeviceId,
    );
    await upsertReceiptParticipant(ctx, receipt._id, participant, now);

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
        joinedAt: Math.min(existingAuthParticipant.joinedAt, participant.joinedAt),
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
  includeArchived: boolean,
) {
  for (const row of rows) {
    const receipt = await ctx.db.get(row.receiptId);
    if (!receipt || (!includeArchived && receipt.isActive === false)) {
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

  if (!receipt || receipt.isActive === false) {
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
      displayName: normalizedDisplayName(identity.name) ?? "You",
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
      displayName: normalizedDisplayName(identity.name) ?? "You",
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
      displayName: participant.displayName,
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
    joinedAt: now,
    updatedAt: now,
  });
}

function normalizedDisplayName(value?: string): string | undefined {
  if (!value) {
    return undefined;
  }

  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function defaultParticipantDisplayName(participantKey: string): string {
  if (participantKey.startsWith("auth:")) {
    return "Friend";
  }

  return "Guest";
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
