import { mutation, query } from "./_generated/server";
import { v } from "convex/values";
import type { Id } from "./_generated/dataModel";

export const upsertMe = mutation({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error("Authentication required.");
    }

    const now = Date.now();
    const existing = await ctx.db
      .query("users")
      .withIndex("by_tokenIdentifier", (q) => q.eq("tokenIdentifier", identity.tokenIdentifier))
      .first();

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

    if (existing) {
      // Preserve user-edited profile names. Only seed from identity if missing.
      if (!existing.name && identity.name) {
        patch.name = identity.name;
      }
      await ctx.db.patch(existing._id, patch);
      return { id: existing._id };
    }

    const id = await ctx.db.insert("users", {
      tokenIdentifier: identity.tokenIdentifier,
      ...patch,
      createdAt: now,
    });

    return { id };
  },
});

export const updateProfile = mutation({
  args: {
    name: v.optional(v.string()),
    preferredPaymentMethod: v.optional(v.string()),
    absorbExtraCents: v.optional(v.boolean()),
    venmoEnabled: v.optional(v.boolean()),
    venmoUsername: v.optional(v.string()),
    cashAppEnabled: v.optional(v.boolean()),
    cashAppCashtag: v.optional(v.string()),
    zelleEnabled: v.optional(v.boolean()),
    zelleContact: v.optional(v.string()),
    cashApplePayEnabled: v.optional(v.boolean()),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error("Authentication required.");
    }

    const now = Date.now();
    const existing = await ctx.db
      .query("users")
      .withIndex("by_tokenIdentifier", (q) => q.eq("tokenIdentifier", identity.tokenIdentifier))
      .first();

    const updates: {
      name?: string;
      preferredPaymentMethod?: string;
      absorbExtraCents?: boolean;
      venmoEnabled?: boolean;
      venmoUsername?: string;
      cashAppEnabled?: boolean;
      cashAppCashtag?: string;
      zelleEnabled?: boolean;
      zelleContact?: string;
      cashApplePayEnabled?: boolean;
      updatedAt: number;
      lastSeenAt: number;
    } = {
      updatedAt: now,
      lastSeenAt: now,
    };

    if (args.name !== undefined) {
      updates.name = args.name;
    }
    if (args.preferredPaymentMethod !== undefined) {
      updates.preferredPaymentMethod = args.preferredPaymentMethod;
    }
    if (args.absorbExtraCents !== undefined) {
      updates.absorbExtraCents = args.absorbExtraCents;
    }
    if (args.venmoEnabled !== undefined) {
      updates.venmoEnabled = args.venmoEnabled;
    }
    if (args.venmoUsername !== undefined) {
      updates.venmoUsername = args.venmoUsername;
    }
    if (args.cashAppEnabled !== undefined) {
      updates.cashAppEnabled = args.cashAppEnabled;
    }
    if (args.cashAppCashtag !== undefined) {
      updates.cashAppCashtag = args.cashAppCashtag;
    }
    if (args.zelleEnabled !== undefined) {
      updates.zelleEnabled = args.zelleEnabled;
    }
    if (args.zelleContact !== undefined) {
      updates.zelleContact = args.zelleContact;
    }
    if (args.cashApplePayEnabled !== undefined) {
      updates.cashApplePayEnabled = args.cashApplePayEnabled;
    }

    if (existing) {
      await ctx.db.patch(existing._id, updates);
      return { id: existing._id };
    }

    const id = await ctx.db.insert("users", {
      tokenIdentifier: identity.tokenIdentifier,
      subject: identity.subject,
      issuer: identity.issuer,
      name: args.name ?? identity.name,
      email: identity.email,
      pictureUrl: identity.pictureUrl,
      preferredPaymentMethod: args.preferredPaymentMethod,
      absorbExtraCents: args.absorbExtraCents,
      venmoEnabled: args.venmoEnabled,
      venmoUsername: args.venmoUsername,
      cashAppEnabled: args.cashAppEnabled,
      cashAppCashtag: args.cashAppCashtag,
      zelleEnabled: args.zelleEnabled,
      zelleContact: args.zelleContact,
      cashApplePayEnabled: args.cashApplePayEnabled,
      createdAt: now,
      updatedAt: now,
      lastSeenAt: now,
    });

    return { id };
  },
});

export const generateProfilePhotoUploadUrl = mutation({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error("Authentication required.");
    }

    return await ctx.storage.generateUploadUrl();
  },
});

export const setProfilePhoto = mutation({
  args: {
    // Accept a plain string from clients and validate existence before persisting.
    storageId: v.string(),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error("Authentication required.");
    }

    const storageId = args.storageId as Id<"_storage">;
    const fileMetadata = await ctx.storage.getMetadata(storageId);
    if (!fileMetadata) {
      throw new Error("Uploaded profile photo was not found in storage.");
    }

    const now = Date.now();
    const existing = await ctx.db
      .query("users")
      .withIndex("by_tokenIdentifier", (q) => q.eq("tokenIdentifier", identity.tokenIdentifier))
      .first();

    if (existing?.pictureStorageId && existing.pictureStorageId !== storageId) {
      await ctx.storage.delete(existing.pictureStorageId);
    }

    const updates = {
      pictureStorageId: storageId,
      pictureUrl: undefined,
      updatedAt: now,
      lastSeenAt: now,
    };

    if (existing) {
      await ctx.db.patch(existing._id, updates);
      return { id: existing._id };
    }

    const id = await ctx.db.insert("users", {
      tokenIdentifier: identity.tokenIdentifier,
      subject: identity.subject,
      issuer: identity.issuer,
      name: identity.name,
      email: identity.email,
      pictureStorageId: storageId,
      createdAt: now,
      updatedAt: now,
      lastSeenAt: now,
    });

    return { id };
  },
});

export const me = query({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      return null;
    }

    const user = await ctx.db
      .query("users")
      .withIndex("by_tokenIdentifier", (q) => q.eq("tokenIdentifier", identity.tokenIdentifier))
      .first();

    if (!user) {
      return null;
    }

    const pictureUrl = user.pictureStorageId
      ? await ctx.storage.getUrl(user.pictureStorageId)
      : user.pictureUrl;

    return {
      ...user,
      pictureUrl: pictureUrl ?? undefined,
    };
  },
});

export const listRecent = query({
  args: {
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      return [];
    }

    const limit = Math.max(1, Math.min(Math.floor(args.limit ?? 50), 200));
    return await ctx.db
      .query("users")
      .withIndex("by_createdAt")
      .order("desc")
      .take(limit);
  },
});
