import SwiftUI

struct RecorderView: View {
    @EnvironmentObject private var model: RecorderModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                preview
                Divider()
                controls
            }
        }
        .task { await model.initializeCapture() }
        .onChange(of: model.selectedSourceID) { _ in Task { await model.prepareCapture() } }
        .onChange(of: model.resolution) { _ in Task { await model.prepareCapture() } }
        .onChange(of: model.fps) { _ in Task { await model.prepareCapture() } }
        .onChange(of: model.cameraEnabled) { _ in Task { await model.prepareCapture() } }
        .onChange(of: model.microphoneEnabled) { _ in Task { await model.prepareCapture() } }
        .onChange(of: model.systemAudioEnabled) { _ in Task { await model.prepareCapture() } }
        .alert("Macord", isPresented: Binding(get: { model.permissionMessage != nil }, set: { if !$0 { model.permissionMessage = nil } })) {
            Button("OK", role: .cancel) { model.permissionMessage = nil }
        } message: {
            Text(model.permissionMessage ?? "")
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Macord")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text(model.isRecording ? "Recording in progress" : "Ready to capture")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(model.isRecording ? Color.red : Color.green)
                .frame(width: 8, height: 8)
            Text(model.isRecording ? "LIVE" : "READY")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var preview: some View {
        ZStack(alignment: .bottomTrailing) {
            if let previewImage = model.previewImage {
                Image(decorative: previewImage, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.92))
                    .overlay {
                    VStack(spacing: 10) {
                        Image(systemName: "rectangle.dashed.badge.record")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.white.opacity(0.8))
                        Text(model.selectedSource?.name ?? "No display selected")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                        Text(model.selectedSource?.nativeLabel ?? "Connect a display to begin")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    }
                    .aspectRatio(16 / 10, contentMode: .fit)
            }

            if model.isPreparing {
                ProgressView()
                    .controlSize(.small)
                    .padding(12)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionBlock(title: "Capture") {
                    PickerRow(title: "Display") {
                        Picker("Display", selection: $model.selectedSourceID) {
                            ForEach(model.sources) { source in
                                Text("\(source.name)  ·  \(source.nativeLabel)").tag(Optional(source.id))
                            }
                        }
                    }
                    PickerRow(title: "Resolution") {
                        Picker("Resolution", selection: $model.resolution) {
                            ForEach(ResolutionOption.allCases) { option in
                                Text(option == .source ? "Source  ·  \(model.selectedSource?.nativeLabel ?? "Native")" : option.rawValue).tag(option)
                            }
                        }
                    }
                    PickerRow(title: "Frame rate") {
                        Picker("Frame rate", selection: $model.fps) {
                            ForEach(model.availableFPS, id: \.self) { value in
                                Text("\(value) FPS").tag(value)
                            }
                        }
                    }
                    PickerRow(title: "Codec") {
                        Picker("Codec", selection: $model.codec) {
                            Text("H.264  ·  Hardware").tag("H.264")
                            Text("HEVC  ·  Hardware").tag("HEVC")
                        }
                    }
                }

                SectionBlock(title: "Camera") {
                    Toggle("Webcam overlay", isOn: $model.cameraEnabled)
                    if model.cameraEnabled {
                        PickerRow(title: "Camera") {
                            Picker("Camera", selection: $model.cameraName) {
                                Text(model.cameraName).tag(model.cameraName)
                            }
                        }
                        PickerRow(title: "Position") {
                            Picker("Position", selection: $model.cameraPosition) {
                                ForEach(CameraPosition.allCases) { position in
                                    Text(position.rawValue).tag(position)
                                }
                            }
                        }
                    }
                }

                SectionBlock(title: "Audio") {
                    Toggle("Microphone", isOn: $model.microphoneEnabled)
                    Toggle("System audio", isOn: $model.systemAudioEnabled)
                    Text("Captures audio from other apps through ScreenCaptureKit.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await model.toggleRecording() }
                } label: {
                    Label(model.isRecording ? "Stop recording" : "Start recording", systemImage: model.isRecording ? "stop.fill" : "record.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isRecording ? .red : .accentColor)
                .controlSize(.large)
            }
            .padding(24)
        }
        .frame(width: 310)
    }
}

private struct SectionBlock<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct PickerRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
            Spacer(minLength: 8)
            content
                .labelsHidden()
                .frame(maxWidth: 170)
        }
    }
}
