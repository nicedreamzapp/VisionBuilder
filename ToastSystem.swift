// ToastSystem.swift
// Global toast/alert notification system
import SwiftUI
import Combine

// MARK: - Toast Types

enum ToastType: Equatable {
    case success
    case error
    case warning
    case info
    case autoAccept(count: Int, label: String)

    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        case .autoAccept: return "sparkles"
        }
    }

    var color: Color {
        switch self {
        case .success: return .green
        case .error: return .red
        case .warning: return .orange
        case .info: return .blue
        case .autoAccept: return .purple
        }
    }
}

// MARK: - Toast Message

struct ToastMessage: Identifiable, Equatable {
    let id: UUID
    let type: ToastType
    let title: String
    let message: String?
    let duration: Double

    init(type: ToastType, title: String, message: String? = nil, duration: Double = 3.0) {
        self.id = UUID()
        self.type = type
        self.title = title
        self.message = message
        self.duration = duration
    }

    static func == (lhs: ToastMessage, rhs: ToastMessage) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Toast Manager (Global Singleton)

final class ToastManager: ObservableObject {
    static let shared = ToastManager()

    @Published var currentToast: ToastMessage?
    private var toastQueue: [ToastMessage] = []
    private var hideTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public Methods (can be called from any context)

    func showSuccess(_ title: String, message: String? = nil) {
        let toast = ToastMessage(type: .success, title: title, message: message)
        enqueue(toast)
    }

    func showError(_ title: String, message: String? = nil) {
        let toast = ToastMessage(type: .error, title: title, message: message, duration: 4.0)
        enqueue(toast)
    }

    func showWarning(_ title: String, message: String? = nil) {
        let toast = ToastMessage(type: .warning, title: title, message: message)
        enqueue(toast)
    }

    func showInfo(_ title: String, message: String? = nil) {
        let toast = ToastMessage(type: .info, title: title, message: message)
        enqueue(toast)
    }

    func showAutoAccept(count: Int, label: String, confidence: Float) {
        let message = String(format: "Average confidence: %.0f%%", confidence * 100)
        let toast = ToastMessage(
            type: .autoAccept(count: count, label: label),
            title: "Auto-labeled \(count) objects as '\(label)'",
            message: message,
            duration: 4.0
        )
        enqueue(toast)
    }

    func dismiss() {
        Task { @MainActor in
            hideTask?.cancel()
            currentToast = nil
            showNextInQueue()
        }
    }

    // MARK: - Private Methods

    private func enqueue(_ toast: ToastMessage) {
        Task { @MainActor in
            if currentToast == nil {
                currentToast = toast
                scheduleHide(after: toast.duration)
            } else {
                toastQueue.append(toast)
            }
        }
    }

    @MainActor
    private func scheduleHide(after duration: Double) {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            currentToast = nil
            showNextInQueue()
        }
    }

    @MainActor
    private func showNextInQueue() {
        guard !toastQueue.isEmpty else { return }
        let next = toastQueue.removeFirst()
        currentToast = next
        scheduleHide(after: next.duration)
    }
}

// MARK: - Toast View

struct ToastView: View {
    let toast: ToastMessage
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.type.icon)
                .font(.title2)
                .foregroundColor(toast.type.color)

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .lineLimit(2)

                if let message = toast.message {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
        )
        .padding(.horizontal, 16)
    }
}

// MARK: - Toast Container Modifier

struct ToastContainerModifier: ViewModifier {
    @ObservedObject private var toastManager = ToastManager.shared

    func body(content: Content) -> some View {
        ZStack {
            content

            VStack {
                if let toast = toastManager.currentToast {
                    ToastView(toast: toast) {
                        toastManager.dismiss()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
                }
                Spacer()
            }
            .animation(.spring(response: 0.3), value: toastManager.currentToast?.id)
        }
    }
}

// MARK: - View Extension

extension View {
    func withToasts() -> some View {
        modifier(ToastContainerModifier())
    }
}
