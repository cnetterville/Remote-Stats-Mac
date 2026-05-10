//
//  TerminalView.swift
//  Remote Stats Mac
//
//  Full PTY terminal using Citadel's withPTY API.
//  Supports interactive programs (top, htop, bash, python, etc.)
//

import SwiftUI
import Citadel
import NIOSSH
import NIOCore

// MARK: - View Model

@available(macOS 15.0, *)
@Observable
@MainActor
final class PTYViewModel {
    var terminal = TerminalEmulator()
    var isConnecting = false
    var isConnected = false
    var connectionError: String?

    let server: ServerConfig
    var initialCommand: String?
    private var writer: TTYStdinWriter?
    private var sessionTask: Task<Void, Never>?
    private var sentInitialCommand = false

    init(server: ServerConfig) {
        self.server = server
    }

    func start(cols: Int, rows: Int) {
        terminal.resize(cols: cols, rows: rows)
        sessionTask = Task { await runSession(cols: cols, rows: rows) }
    }

    func stop() {
        sessionTask?.cancel()
        sessionTask = nil
        writer = nil
        isConnected = false
    }

    private func runSession(cols: Int, rows: Int) async {
        isConnecting = true
        connectionError = nil
        do {
            let auth = try SSHService.authMethod(for: server)
            let client = try await SSHClient.connect(
                host: server.host,
                port: server.port,
                authenticationMethod: auth,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
            isConnecting = false
            isConnected = true

            let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: cols,
                terminalRowHeight: rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: .init([:])
            )

            try await client.withPTY(ptyRequest) { [weak self] inbound, outbound in
                guard let self else { return }
                self.writer = outbound

                if !sentInitialCommand, let cmd = initialCommand, !cmd.isEmpty {
                    sentInitialCommand = true
                    send(cmd + "\n")
                }

                for try await output in inbound {
                    guard !Task.isCancelled else { break }
                    let buf: ByteBuffer
                    switch output {
                    case .stdout(let b): buf = b
                    case .stderr(let b): buf = b
                    }
                    if let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes) {
                        terminal.process(Data(bytes))
                    }
                }
            }
        } catch {
            if !Task.isCancelled {
                connectionError = error.localizedDescription
            }
        }
        isConnecting = false
        isConnected = false
        writer = nil
    }

    // MARK: - Input

    func send(_ text: String) {
        guard let writer else { return }
        var buf = ByteBuffer()
        buf.writeString(text)
        Task { try? await writer.write(buf) }
    }

    func sendBytes(_ bytes: [UInt8]) {
        guard let writer else { return }
        let buf = ByteBuffer(bytes: bytes)
        Task { try? await writer.write(buf) }
    }

    func notifyResize(cols: Int, rows: Int) {
        terminal.resize(cols: cols, rows: rows)
        guard let writer else { return }
        Task { try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0) }
    }
}

// MARK: - View

@available(macOS 15.0, *)
struct TerminalView: View {
    let server: ServerConfig
    @State private var viewModel: PTYViewModel
    @State private var input = ""
    @State private var terminalCols = 80
    @State private var terminalRows = 24
    @FocusState private var inputFocused: Bool

    static let fontSize: CGFloat = 11
    // SF Mono character width is approximately 0.601 × fontSize
    static let charWidth: CGFloat = fontSize * 0.601
    static let lineHeight: CGFloat = fontSize * 1.35

    init(server: ServerConfig, initialCommand: String? = nil) {
        self.server = server
        let vm = PTYViewModel(server: server)
        vm.initialCommand = initialCommand
        self._viewModel = State(initialValue: vm)
    }

    var body: some View {
        VStack(spacing: 0) {
            terminalScreen
            Divider()
            specialKeyStrip
            Divider()
            inputBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Terminal")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                statusIndicator
            }
        }
        .onDisappear { viewModel.stop() }
    }

    // MARK: Terminal screen

    private var terminalScreen: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                terminalGrid
                    .padding(4)
            }
            .background(Color.black)
            .onAppear {
                let c = max(20, Int(floor((geo.size.width - 8) / Self.charWidth)))
                let r = max(10, Int(floor((geo.size.height - 8) / Self.lineHeight)))
                terminalCols = c
                terminalRows = r
                viewModel.start(cols: c, rows: r)
            }
            .onChange(of: geo.size) { _, newSize in
                let c = max(20, Int(floor((newSize.width - 8) / Self.charWidth)))
                let r = max(10, Int(floor((newSize.height - 8) / Self.lineHeight)))
                if c != terminalCols || r != terminalRows {
                    terminalCols = c
                    terminalRows = r
                    viewModel.notifyResize(cols: c, rows: r)
                }
            }
        }
    }

    private var terminalGrid: some View {
        // Keyed on generation so SwiftUI only re-renders when the terminal screen changes.
        let gen = viewModel.terminal.generation
        return VStack(alignment: .leading, spacing: 0) {
            if viewModel.isConnecting {
                Text("Connecting to \(server.host)…")
                    .font(.system(size: Self.fontSize, design: .monospaced))
                    .foregroundStyle(.green)
                    .padding(4)
            } else if let err = viewModel.connectionError {
                Text("Error: \(err)")
                    .font(.system(size: Self.fontSize, design: .monospaced))
                    .foregroundStyle(.red)
                    .padding(4)
            } else {
                ForEach(0..<viewModel.terminal.rows, id: \.self) { r in
                    Text(viewModel.terminal.attributedRow(r, fontSize: Self.fontSize))
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .id(gen)
    }

    // MARK: Special key strip

    private var specialKeyStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                specialKey("⌃C") { viewModel.sendBytes([0x03]) }
                specialKey("⌃D") { viewModel.sendBytes([0x04]) }
                specialKey("⌃Z") { viewModel.sendBytes([0x1A]) }
                specialKey("ESC") { viewModel.sendBytes([0x1B]) }
                specialKey("TAB") { viewModel.sendBytes([0x09]) }
                specialKey("↑") { viewModel.sendBytes([0x1B, 0x5B, 0x41]) }
                specialKey("↓") { viewModel.sendBytes([0x1B, 0x5B, 0x42]) }
                specialKey("→") { viewModel.sendBytes([0x1B, 0x5B, 0x43]) }
                specialKey("←") { viewModel.sendBytes([0x1B, 0x5B, 0x44]) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private func specialKey(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.isConnected)
    }

    // MARK: Input bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("input", text: $input)
                .font(.system(size: 14, design: .monospaced))
                .autocorrectionDisabled()
                .submitLabel(.send)
                .focused($inputFocused)
                .onSubmit { submitInput() }

            Button(action: submitInput) {
                Image(systemName: "return")
                    .foregroundStyle(input.isEmpty ? Color.secondary : Color.blue)
            }
            .disabled(input.isEmpty || !viewModel.isConnected)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func submitInput() {
        viewModel.send(input + "\n")
        input = ""
    }

    // MARK: Status

    private var statusIndicator: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(viewModel.isConnecting ? Color.orange
                      : viewModel.isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(viewModel.isConnecting ? "Connecting"
                 : viewModel.isConnected ? "Connected" : "Disconnected")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
