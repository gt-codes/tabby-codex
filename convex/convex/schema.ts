import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export default defineSchema({
  receipts: defineTable({
    ownerTokenIdentifier: v.optional(v.string()),
    ownerSubject: v.optional(v.string()),
    ownerIssuer: v.optional(v.string()),
    guestDeviceId: v.optional(v.string()),
    clientReceiptId: v.string(),
    shareCode: v.string(),
    // Legacy payload retained as optional while migrating to receiptItems.
    receiptJson: v.optional(v.string()),
    isActive: v.optional(v.boolean()),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_shareCode", ["shareCode"])
    .index("by_clientReceiptId", ["clientReceiptId"])
    .index("by_owner_clientReceiptId", ["ownerTokenIdentifier", "clientReceiptId"])
    .index("by_owner_active_createdAt", ["ownerTokenIdentifier", "isActive", "createdAt"])
    .index("by_guestDeviceId", ["guestDeviceId"])
    .index("by_guest_clientReceiptId", ["guestDeviceId", "clientReceiptId"])
    .index("by_guest_active_createdAt", ["guestDeviceId", "isActive", "createdAt"])
    .index("by_createdAt", ["createdAt"]),
  receiptItems: defineTable({
    receiptId: v.id("receipts"),
    clientItemId: v.optional(v.string()),
    name: v.string(),
    quantity: v.number(),
    price: v.optional(v.number()),
    sortOrder: v.number(),
    createdAt: v.number(),
  }).index("by_receipt_sortOrder", ["receiptId", "sortOrder"]),
  users: defineTable({
    tokenIdentifier: v.string(),
    subject: v.string(),
    issuer: v.string(),
    name: v.optional(v.string()),
    email: v.optional(v.string()),
    pictureUrl: v.optional(v.string()),
    pictureStorageId: v.optional(v.id("_storage")),
    preferredPaymentMethod: v.optional(v.string()),
    createdAt: v.number(),
    updatedAt: v.number(),
    lastSeenAt: v.number(),
  })
    .index("by_tokenIdentifier", ["tokenIdentifier"])
    .index("by_createdAt", ["createdAt"]),
});
