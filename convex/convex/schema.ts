import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export default defineSchema({
  receipts: defineTable({
    clientReceiptId: v.string(),
    shareCode: v.string(),
    receiptJson: v.string(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_shareCode", ["shareCode"])
    .index("by_clientReceiptId", ["clientReceiptId"])
    .index("by_createdAt", ["createdAt"]),
});
