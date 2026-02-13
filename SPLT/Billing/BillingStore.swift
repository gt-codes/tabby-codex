import Foundation
import StoreKit
import SwiftUI

@MainActor
final class BillingStore: ObservableObject {
    static let shared = BillingStore()

    static let supportedProductIDs = [
        "com.splt.billcredits.1",
        "com.splt.billcredits.5",
    ]

    @Published private(set) var products: [Product] = []
    @Published private(set) var usageSummary: BillUsageSummary?
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var isRefreshingUsage = false
    @Published var purchaseInFlightProductID: String?
    @Published var lastErrorMessage: String?

    private init() {}

    func refresh() async {
        await loadProducts()
        await refreshUsageSummary()
    }

    func loadProducts() async {
        if isLoadingProducts { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }

        do {
            let fetched = try await Product.products(for: Self.supportedProductIDs)
            products = fetched.sorted(by: { lhs, rhs in
                let lhsCredits = Self.creditAmount(for: lhs.id)
                let rhsCredits = Self.creditAmount(for: rhs.id)
                if lhsCredits == rhsCredits {
                    return lhs.id < rhs.id
                }
                return lhsCredits < rhsCredits
            })
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Couldn't load bill credit options."
        }
    }

    func refreshUsageSummary() async {
        if isRefreshingUsage { return }
        isRefreshingUsage = true
        defer { isRefreshingUsage = false }

        do {
            usageSummary = try await ConvexService.shared.fetchBillingUsageSummary()
            lastErrorMessage = nil
        } catch {
            usageSummary = nil
            lastErrorMessage = "Couldn't load your bill credit usage."
        }
    }

    @discardableResult
    func purchase(product: Product) async -> Bool {
        purchaseInFlightProductID = product.id
        defer { purchaseInFlightProductID = nil }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                _ = try await ConvexService.shared.redeemCreditPurchase(
                    transactionId: String(transaction.id),
                    productId: transaction.productID,
                    purchasedAt: transaction.purchaseDate
                )
                await transaction.finish()
                await refreshUsageSummary()
                lastErrorMessage = nil
                return true
            case .pending:
                lastErrorMessage = "Purchase is pending approval."
                return false
            case .userCancelled:
                return false
            @unknown default:
                lastErrorMessage = "Purchase couldn't be completed."
                return false
            }
        } catch {
            lastErrorMessage = "Purchase couldn't be completed."
            return false
        }
    }

    static func creditAmount(for productID: String) -> Int {
        switch productID {
        case "com.splt.billcredits.1":
            return 1
        case "com.splt.billcredits.5":
            return 5
        default:
            return 0
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let signedType):
            return signedType
        case .unverified:
            throw NSError(
                domain: "BillingStore",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Purchase verification failed."]
            )
        }
    }
}

struct BillCreditsPurchaseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var billingStore = BillingStore.shared
    var onPurchaseCompleted: () -> Void = {}

    var body: some View {
        NavigationStack {
            List {
                creditsSection
                productsSection
                if let errorMessage = billingStore.lastErrorMessage, !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .font(SPLTType.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Bill Credits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            await billingStore.refresh()
        }
    }

    @ViewBuilder
    private var creditsSection: some View {
        Section("Credits") {
            if let usage = billingStore.usageSummary {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(usage.billCreditsBalance) bill credits available")
                        .font(SPLTType.bodyBold)
                    Text("Credits are used after free bills run out.")
                        .font(SPLTType.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if billingStore.isRefreshingUsage {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading credits")
                        .font(SPLTType.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Credits unavailable right now.")
                    .font(SPLTType.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var productsSection: some View {
        Section("Buy Credits") {
            if billingStore.isLoadingProducts {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading bill credit packs")
                        .font(SPLTType.caption)
                        .foregroundStyle(.secondary)
                }
            } else if billingStore.products.isEmpty {
                Text("No bill credit packs available right now.")
                    .font(SPLTType.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(billingStore.products, id: \.id) { product in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            let credits = BillingStore.creditAmount(for: product.id)
                            Text("\(credits) bill credit\(credits == 1 ? "" : "s")")
                                .font(SPLTType.bodyBold)
                            Text(product.displayPrice)
                                .font(SPLTType.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task {
                                let purchased = await billingStore.purchase(product: product)
                                if purchased {
                                    onPurchaseCompleted()
                                    dismiss()
                                }
                            }
                        } label: {
                            if billingStore.purchaseInFlightProductID == product.id {
                                ProgressView()
                            } else {
                                Text("Buy")
                                    .font(SPLTType.bodyBold)
                            }
                        }
                        .disabled(billingStore.purchaseInFlightProductID != nil)
                    }
                }
            }
        }
    }
}
