//
//  ConsoleView.swift
//  Remote Stats Mac
//

import SwiftUI
import Citadel
import NIOCore

// MARK: - Model

struct ConsoleEntry: Identifiable {
    let id = UUID()
    let command: String
    let output: String
    let isError: Bool
}

@Observable
@MainActor
class ConsoleViewModel {
    var entries: [ConsoleEntry] = []
    var isConnecting = false
    var isRunning = false
    var isConnected = false
    var connectionError: String?

    let server: ServerConfig
    private var client: SSHClient?

    init(server: ServerConfig) {
        self.server = server
    }

    func connect() async {
        isConnecting = true
        connectionError = nil
        do {
            let auth = try SSHService.authMethod(for: server)
            client = try await SSHClient.connect(
                host: server.host,
                port: server.port,
                authenticationMethod: auth,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
            isConnected = true
        } catch {
            connectionError = error.localizedDescription
            isConnected = false
        }
        isConnecting = false
    }

    func run(_ command: String) async {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isRunning = true

        if client == nil || !isConnected {
            await connect()
        }

        guard isConnected, let client else {
            entries.append(ConsoleEntry(
                command: trimmed,
                output: connectionError ?? "Not connected.",
                isError: true
            ))
            isRunning = false
            return
        }

        do {
            let buffer = try await client.executeCommand(trimmed)
            let raw = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
            entries.append(ConsoleEntry(
                command: trimmed,
                output: raw.trimmingCharacters(in: .newlines),
                isError: false
            ))
        } catch {
            isConnected = false
            entries.append(ConsoleEntry(
                command: trimmed,
                output: error.localizedDescription,
                isError: true
            ))
        }
        isRunning = false
    }

    func disconnect() {
        Task { try? await client?.close() }
        client = nil
        isConnected = false
    }

    func clear() { entries = [] }
}

// MARK: - View

struct ConsoleView: View {
    let server: ServerConfig
    @State private var viewModel: ConsoleViewModel
    @State private var input = ""
    @State private var commandHistory: [String] = []
    @State private var historyIndex: Int? = nil
    @FocusState private var inputFocused: Bool

    init(server: ServerConfig) {
        self.server = server
        self._viewModel = State(initialValue: ConsoleViewModel(server: server))
    }

    var body: some View {
        VStack(spacing: 0) {
            outputArea
            Divider()
            inputBar
        }
        .navigationTitle("Console")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                statusIndicator
                Button {
                    viewModel.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(viewModel.entries.isEmpty)
            }
        }
        .task { await viewModel.connect() }
        .onDisappear { viewModel.disconnect() }
    }

    // MARK: Output area

    private var outputArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // Session header
                    Text("\(server.username)@\(server.host)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)

                    if viewModel.isConnecting {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.7)
                            Text("Connecting…")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    } else if let err = viewModel.connectionError, !viewModel.isConnected {
                        Text("✗ \(err)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                    } else if viewModel.isConnected && viewModel.entries.isEmpty {
                        Text("Connected. Type a command below.")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    ForEach(viewModel.entries) { entry in
                        ConsoleEntryRow(entry: entry, prompt: "\(server.username)@\(server.host)")
                    }

                    // Anchor to scroll to
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .onChange(of: viewModel.entries.count) {
                withAnimation { proxy.scrollTo("bottom") }
            }
            .onChange(of: viewModel.isConnecting) {
                withAnimation { proxy.scrollTo("bottom") }
            }
        }
    }

    // MARK: Input bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            Text("$")
                .font(.body.monospaced().bold())
                .foregroundStyle(.green)

            TextField("command", text: $input)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                .submitLabel(.send)
                .focused($inputFocused)
                .onSubmit { submit() }

            if viewModel.isRunning {
                ProgressView().scaleEffect(0.8)
            } else {
                Button(action: submit) {
                    Image(systemName: "paperplane.fill")
                        .foregroundStyle(input.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color.blue)
                }
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || !viewModel.isConnected)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: Status dot

    private var statusIndicator: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(viewModel.isConnecting ? .orange : (viewModel.isConnected ? .green : .red))
                .frame(width: 8, height: 8)
            Text(viewModel.isConnecting ? "Connecting" : (viewModel.isConnected ? "Connected" : "Disconnected"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private func submit() {
        let cmd = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        commandHistory.insert(cmd, at: 0)
        historyIndex = nil
        input = ""
        Task { await viewModel.run(cmd) }
    }
}

// MARK: - Entry Row

struct ConsoleEntryRow: View {
    let entry: ConsoleEntry
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Command line
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(prompt) $")
                    .font(.caption.monospaced())
                    .foregroundStyle(.green)
                Text(entry.command)
                    .font(.body.monospaced().bold())
            }
            // Output
            if !entry.output.isEmpty {
                Text(entry.output)
                    .font(.caption.monospaced())
                    .foregroundStyle(entry.isError ? .red : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
