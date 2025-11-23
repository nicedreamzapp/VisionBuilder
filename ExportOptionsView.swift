import SwiftUI

struct ExportOptionsView: View {
    @ObservedObject var exportManager: ExportManager
    @Binding var isPresented: Bool

    @State private var selectedFormat: ExportFormat = .visionBuilder
    @State private var selectedScale: ImageScale = .high

    var body: some View {
        ZStack {
            backgroundDimmer
            dialogContent
        }
    }

    // MARK: - Background

    var backgroundDimmer: some View {
        Color.black.opacity(0.4)
            .ignoresSafeArea()
            .onTapGesture {
                isPresented = false
            }
    }

    // MARK: - Main Dialog

    var dialogContent: some View {
        VStack(spacing: 0) {
            dialogHeader
                .padding(.bottom, 24)

            formatSection
                .padding(.bottom, 24)

            scaleSection
                .padding(.bottom, 24)

            labelSection
                .padding(.bottom, 24)

            toggleSection
                .padding(.bottom, 24)

            buttonSection
        }
        .padding(24)
        .frame(width: 380)
        .background(dialogBackground)
        .shadow(color: .black.opacity(0.2), radius: 30, y: 15)
        .scaleEffect(isPresented ? 1.0 : 0.9)
        .opacity(isPresented ? 1.0 : 0)
        .animation(.spring(response: 0.3), value: isPresented)
    }

    // MARK: - Header

    var dialogHeader: some View {
        VStack(spacing: 8) {
            Text("Export Options")
                .font(.system(size: 24, weight: .bold))

            Text("Choose format and settings")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Image Scale Selection

    var scaleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Image Quality")
                .font(.system(size: 16, weight: .semibold))

            VStack(spacing: 8) {
                ForEach(ImageScale.allCases, id: \.self) { scale in
                    scaleButton(for: scale)
                }
            }
        }
    }

    func scaleButton(for scale: ImageScale) -> some View {
        Button {
            selectedScale = scale
            exportManager.exportOptions.imageScale = scale
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack(spacing: 16) {
                Image(systemName: scale.icon)
                    .font(.system(size: 20))
                    .foregroundColor(selectedScale == scale ? .white : .primary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(scale.rawValue)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(selectedScale == scale ? .white : .primary)

                    Text(scale.description)
                        .font(.system(size: 12))
                        .foregroundColor(selectedScale == scale ? .white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }

                Spacer()

                if selectedScale == scale {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white)
                }
            }
            .padding(14)
            .background(formatButtonBackground(isSelected: selectedScale == scale))
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Format Selection

    var formatSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Format")
                .font(.system(size: 16, weight: .semibold))

            VStack(spacing: 8) {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    formatButton(for: format)
                }
            }
        }
    }

    func formatButton(for format: ExportFormat) -> some View {
        Button {
            selectedFormat = format
            exportManager.exportOptions.format = format
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack(spacing: 16) {
                Image(systemName: format.icon)
                    .font(.system(size: 24))
                    .foregroundColor(selectedFormat == format ? .white : .primary)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text(format.rawValue)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(selectedFormat == format ? .white : .primary)

                    Text(format.description)
                        .font(.system(size: 12))
                        .foregroundColor(selectedFormat == format ? .white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }

                Spacer()

                if selectedFormat == format {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                }
            }
            .padding(16)
            .background(formatButtonBackground(isSelected: selectedFormat == format))
        }
        .buttonStyle(PlainButtonStyle())
    }

    func formatButtonBackground(isSelected: Bool) -> some View {
        Group {
            if isSelected {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.blue)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                        .opacity(0.3)

                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                }
            }
        }
    }

    // MARK: - Label Filter

    @ViewBuilder
    var labelSection: some View {
        if !exportManager.pendingBoxes.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Labels to Export")
                    .font(.system(size: 16, weight: .semibold))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(uniqueLabels, id: \.self) { label in
                            labelChip(for: label)
                        }
                    }
                }
            }
        }
    }

    var uniqueLabels: [String] {
        Array(Set(exportManager.pendingBoxes.map { $0.label })).sorted()
    }

    func labelChip(for label: String) -> some View {
        Button {
            if exportManager.exportOptions.selectedLabels.contains(label) {
                exportManager.exportOptions.selectedLabels.remove(label)
            } else {
                exportManager.exportOptions.selectedLabels.insert(label)
            }
        } label: {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(exportManager.exportOptions.selectedLabels.contains(label) ? .white : .primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(labelChipBackground(isSelected: exportManager.exportOptions.selectedLabels.contains(label)))
        }
    }

    func labelChipBackground(isSelected: Bool) -> some View {
        Group {
            if isSelected {
                Capsule()
                    .fill(Color.blue)
            } else {
                ZStack {
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .opacity(0.3)

                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5)
                }
            }
        }
    }

    // MARK: - Toggle

    var toggleSection: some View {
        Toggle(isOn: $exportManager.exportOptions.includeMetadata) {
            Label("Include Metadata", systemImage: "doc.text")
                .font(.system(size: 14, weight: .medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
                .opacity(0.3)
        )
    }

    // MARK: - Action Buttons

    var buttonSection: some View {
        HStack(spacing: 16) {
            Button("Cancel") {
                isPresented = false
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .glassStyle(variant: .regular, floating: false)
            .foregroundColor(.primary)

            Button("Export") {
                exportManager.executeExportForSharing()
                isPresented = false
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .glassStyle(variant: .regular, floating: false, tint: .blue)
            .foregroundColor(.white)
            .font(.system(size: 16, weight: .semibold))
        }
    }

    // MARK: - Background

    var dialogBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(.black.opacity(0.001))

            RoundedRectangle(cornerRadius: 24)
                .fill(.ultraThinMaterial)
                .opacity(0.4)

            RoundedRectangle(cornerRadius: 24)
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.15),
                            .clear,
                            .clear,
                            .white.opacity(0.05),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
        }
    }
}
