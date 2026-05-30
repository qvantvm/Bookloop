import SwiftUI

struct AIBalanceWidgetView: View {
    @EnvironmentObject private var usageStore: AIUsageCostStore
    @EnvironmentObject private var settingsStore: AppSettingsStore

    var body: some View {
        Group {
            if settingsStore.hasAPIKey {
                widgetContent
            }
        }
    }

    private var widgetContent: some View {
        VStack(spacing: 2) {
            Image(systemName: usageStore.showsBalance ? "creditcard.fill" : "dollarsign.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(usageStore.showsBalance ? Color.green : Color.secondary)

            if let balance = usageStore.creditBalanceUSD {
                Text(formatUSD(balance, compact: true))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else if usageStore.isRefreshingBalance {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.55)
            }

            if usageStore.hasSessionUsage {
                Text(formatUSD(usageStore.sessionEstimatedCostUSD, compact: true))
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(width: 40)
        .padding(.vertical, 4)
        .help(helpText)
    }

    private var helpText: String {
        var lines: [String] = []
        if let balance = usageStore.creditBalanceUSD {
            lines.append("Prepaid credit remaining (approx.): \(formatUSD(balance, compact: false))")
        } else if let reason = usageStore.balanceUnavailableReason {
            lines.append(reason)
        }
        if usageStore.hasSessionUsage {
            lines.append(
                "This session (estimated): \(formatUSD(usageStore.sessionEstimatedCostUSD, compact: false)) · \(usageStore.sessionPromptTokens.formatted()) prompt + \(usageStore.sessionCompletionTokens.formatted()) completion tokens"
            )
            lines.append("Costs are estimated from published list prices and may differ from your invoice.")
        }
        if let updated = usageStore.balanceLastUpdated {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            lines.append("Balance checked \(formatter.localizedString(for: updated, relativeTo: Date())).")
        }
        return lines.joined(separator: "\n")
    }

    private func formatUSD(_ value: Double, compact: Bool) -> String {
        if compact, value >= 10 {
            return String(format: "$%.0f", value)
        }
        if value < 0.01, value > 0 {
            return "<$0.01"
        }
        if value < 1 {
            return String(format: "$%.2f", value)
        }
        return String(format: "$%.2f", value)
    }
}
