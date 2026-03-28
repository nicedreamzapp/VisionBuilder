//
//  UpgradePromptView.swift
//  Vision Builder
//
//  One-time prompt shown after the MobileCLIP upgrade.
//  Offers to reset the database for a clean start with full CLIP support.
//

import SwiftUI

struct UpgradePromptView: View {
    @Binding var isPresented: Bool
    var onFreshStart: () -> Void
    var onKeepData: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.blue.opacity(0.2), Color.purple.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 100, height: 100)

                Image(systemName: "sparkles")
                    .font(.system(size: 44))
                    .foregroundStyle(LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
            }

            // Title
            VStack(spacing: 10) {
                Text("Vision Builder 2.0")
                    .font(.title.bold())

                Text("Now with MobileCLIP Intelligence")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }

            // Features list
            VStack(alignment: .leading, spacing: 14) {
                featureRow(icon: "text.magnifyingglass", color: .blue,
                          title: "Find by Description",
                          detail: "Type \"shoes\" to find all shoes in your photos")

                featureRow(icon: "sparkle.magnifyingglass", color: .purple,
                          title: "Auto-Label Suggestions",
                          detail: "AI suggests what each cluster contains")

                featureRow(icon: "brain", color: .green,
                          title: "Smarter Clustering",
                          detail: "Objects grouped by meaning, not just appearance")
            }
            .padding(.horizontal, 8)

            Spacer()

            // Actions
            VStack(spacing: 12) {
                Button {
                    onFreshStart()
                    markUpgradeSeen()
                    isPresented = false
                } label: {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Fresh Start (Recommended)")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    onKeepData()
                    markUpgradeSeen()
                    isPresented = false
                } label: {
                    Text("Keep Existing Data")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Text("Fresh Start resets the database so all new scans get full AI features.\nExisting labeled folders in Files are not affected.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer().frame(height: 8)
        }
        .padding(.horizontal, 24)
    }

    private func featureRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func markUpgradeSeen() {
        UserDefaults.standard.set(true, forKey: "hasSeenMobileCLIPUpgrade")
    }

    static var shouldShow: Bool {
        !UserDefaults.standard.bool(forKey: "hasSeenMobileCLIPUpgrade")
    }
}
