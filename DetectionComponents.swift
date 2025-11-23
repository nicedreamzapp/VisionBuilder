import SwiftUI

// MARK: - Liquid Glass Variant

enum glassStyleVariant {
    case regular
    case clear
}

// MARK: - Enhanced Control Button (with colored emoji backgrounds)

struct EnhancedControlButton: View {
    let emoji: String
    let label: String
    let color: Color
    let action: () -> Void
    var isActive: Bool = false

    @State private var isPressed = false
    @State private var glowIntensity: Double = 0

    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()

            // Interaction glow
            withAnimation(.easeOut(duration: 0.3)) {
                glowIntensity = 1.0
            }
            withAnimation(.easeIn(duration: 0.3).delay(0.1)) {
                glowIntensity = 0
            }

            action()
        }) {
            VStack(spacing: 6) {
                // Colored emoji background
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(color.opacity(0.9))
                        .frame(width: 50, height: 50)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            .white.opacity(0.3),
                                            .clear,
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        )

                    Text(emoji)
                        .font(.system(size: 28))
                        .scaleEffect(isPressed ? 0.85 : 1.0)
                }

                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 70, height: 70)
            .background(
                ZStack {
                    // Ultra-transparent glass background
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .opacity(0.5)

                    // Very subtle color tint
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(color.opacity(0.05))

                    // Active state glow
                    if isActive {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(color.opacity(0.5), lineWidth: 2)
                            .blur(radius: 2)
                    }
                }
            )
            .overlay {
                // Subtle glass edge
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.2),
                                .white.opacity(0.05),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
            }
            .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
            .overlay {
                // Interaction glow
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [
                                color.opacity(0.3 * glowIntensity),
                                color.opacity(0.1 * glowIntensity),
                                .clear,
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 40
                        )
                    )
                    .allowsHitTesting(false)
            }
            .scaleEffect(isPressed ? 0.94 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .onLongPressGesture(
            minimumDuration: 0,
            maximumDistance: .infinity,
            pressing: { pressing in
                withAnimation(.easeInOut(duration: 0.1)) {
                    isPressed = pressing
                }
            },
            perform: {}
        )
    }
}

// MARK: - Simplified Control Panel

struct SimplifiedControlPanel: View {
    @ObservedObject var boxState: BoxState
    @ObservedObject var exportManager: ExportManager // Parameter, not @EnvironmentObject
    @ObservedObject var sam2DetectionManager: SAM2DetectionManager
    @Binding var showLabelDialog: Bool
    @Binding var showDatasetBrowser: Bool
    let onReturnToLibrary: () -> Void

    var instructionText: String {
        if boxState.boxes.isEmpty {
            return "Tap objects to create boxes or use Auto-Detect"
        } else if boxState.selectedBoxID != nil {
            if boxState.selectedBox?.isSaved == false {
                return "Box selected - Tap Save to label"
            } else {
                return "Box saved - Continue adding more"
            }
        } else {
            return "Tap to select • Tap empty area to create"
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            // Dynamic instruction text - Liquid Glass style
            Text(instructionText)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .glassStyle(variant: .regular, floating: false)
                .animation(.easeInOut, value: instructionText)

            // Button row
            HStack(spacing: 12) {
                // Delete button - only show if boxes exist
                if !boxState.boxes.isEmpty {
                    EnhancedControlButton(
                        emoji: "🗑️",
                        label: "Delete",
                        color: .red,
                        action: {
                            if let selectedID = boxState.selectedBoxID {
                                boxState.deleteBox(id: selectedID)
                            }
                        }
                    )
                    .transition(.scale.combined(with: .opacity))
                }

                // Save button - only show if unsaved box is selected
                if boxState.selectedBoxID != nil && boxState.selectedBox?.isSaved == false {
                    EnhancedControlButton(
                        emoji: "💾",
                        label: "Save",
                        color: .green,
                        action: {
                            showLabelDialog = true
                        }
                    )
                    .transition(.scale.combined(with: .opacity))
                }

                // Export button - only show if saved boxes exist
                if boxState.savedCount > 0 {
                    EnhancedControlButton(
                        emoji: "📤",
                        label: "Export",
                        color: .blue,
                        action: {
                            if let currentImage = boxState.currentImage {
                                exportManager.quickSave(
                                    image: currentImage,
                                    labeledBoxes: boxState.boxes
                                )
                            }
                        }
                    )
                    .transition(.scale.combined(with: .opacity))
                }

                // Auto-Detect button
                EnhancedControlButton(
                    emoji: "🤖",
                    label: "Auto-Detect",
                    color: .purple,
                    action: {
                        if let currentImage = boxState.currentImage {
                            sam2DetectionManager.autoDetectAllObjects(in: currentImage)
                        }
                    }
                )

                // Done button - goes to Dataset tab
                EnhancedControlButton(
                    emoji: "✓",
                    label: "Done",
                    color: .gray,
                    action: onReturnToLibrary
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                ZStack {
                    // Almost invisible base for glass effect
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(.black.opacity(0.001))

                    // Very light material effect
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .opacity(0.25)

                    // Glossy overlay
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.1),
                                    .clear,
                                    .white.opacity(0.05),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    // Edge highlight for glass effect
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.2),
                                    .clear,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                }
            )
            .shadow(color: .black.opacity(0.05), radius: 10, y: 5)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10) // Reduced from 20 to sit closer to bottom
    }
}

// MARK: - Tap Feedback View

struct TapFeedbackView: View {
    let location: CGPoint
    @State private var scale: CGFloat = 0.5
    @State private var opacity: Double = 1.0
    @State private var rippleScale: CGFloat = 0.8
    @State private var glowIntensity: Double = 1.0

    var body: some View {
        ZStack {
            // Liquid glass ripple effect
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.6),
                            .white.opacity(0.3),
                            .clear,
                        ],
                        startPoint: .center,
                        endPoint: .bottom
                    ),
                    lineWidth: 2
                )
                .frame(width: 60, height: 60)
                .scaleEffect(rippleScale)
                .opacity(opacity * 0.8)
                .blur(radius: rippleScale > 1.5 ? 2 : 0)

            // Center glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            .white,
                            .white.opacity(0.3),
                            .clear,
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 20
                    )
                )
                .frame(width: 30, height: 30)
                .scaleEffect(scale)
                .opacity(opacity * glowIntensity)
                .blur(radius: 1)

            // Lightning bolt for processing
            Image(systemName: "bolt.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
                .opacity(opacity)
                .scaleEffect(scale * 1.2)
                .shadow(color: .white, radius: 4)
        }
        .position(location)
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                scale = 1.4
                rippleScale = 2.5
                opacity = 0
                glowIntensity = 0
            }
        }
    }
}

// MARK: - Enhanced Label Dialog (Liquid Glass)

struct EnhancedLabelDialog: View {
    @Binding var isPresented: Bool
    @Binding var labelText: String
    let onSave: () -> Void

    @FocusState private var isFocused: Bool
    @State private var tempText = ""
    @State private var glowAnimation = false

    var body: some View {
        ZStack {
            // Dimming background
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .contentShape(Rectangle()) // prevent taps passing through
                .onTapGesture { isPresented = false }

            GeometryReader { geometry in
                VStack(spacing: 20) {
                    // Header
                    HStack {
                        Text("🏷️")
                            .font(.system(size: 32))

                        Text("Label this object")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.primary)

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .opacity(0.8)
                    )

                    // Text field with liquid glass
                    TextField("Enter label...", text: $tempText)
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(.system(size: 16))
                        .foregroundColor(.primary)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5)
                                )
                        )
                        .focused($isFocused)

                    // Buttons with liquid glass
                    HStack(spacing: 16) {
                        Button("Cancel") {
                            tempText = ""
                            isPresented = false
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .glassStyle(variant: .regular, floating: false)

                        Button("Save") {
                            labelText = tempText.isEmpty ? "Object" : tempText
                            onSave()
                            tempText = ""
                            isPresented = false
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .glassStyle(variant: .regular, floating: false, tint: .blue)
                        .overlay {
                            if glowAnimation {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.blue, lineWidth: 2)
                                    .blur(radius: 4)
                                    .opacity(glowAnimation ? 0 : 0.8)
                                    .scaleEffect(glowAnimation ? 1.2 : 1)
                            }
                        }
                    }
                }
                .padding(24)
                .frame(width: 340)
                .background(
                    ZStack {
                        // Base layer
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.black.opacity(0.001))

                        // Very light glass
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .opacity(0.4) // Slightly more opaque for readability

                        // Glossy shine
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
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

                        // Glass edge
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(
                                .white.opacity(0.25),
                                lineWidth: 0.5
                            )
                    }
                )
                .shadow(color: .black.opacity(0.1), radius: 20, y: 10)
                .scaleEffect(isPresented ? 1.0 : 0.9)
                .opacity(isPresented ? 1.0 : 0)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isPresented)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 3) // Position in upper third
                .ignoresSafeArea(.keyboard) // Don't move with keyboard
                .onAppear {
                    tempText = labelText
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        isFocused = true
                    }

                    // Interaction glow animation
                    withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                        glowAnimation = true
                    }
                }
            }
        }
    }
}

// MARK: - Minimal Instruction View (if still needed)

struct MinimalInstructionView: View {
    @State private var showInstruction = true

    var body: some View {
        if showInstruction {
            HStack(spacing: 8) {
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.blue)

                Text("Tap objects to create boxes")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
            )
            .transition(.move(edge: .top).combined(with: .opacity))
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation {
                        showInstruction = false
                    }
                }
            }
        }
    }
}
