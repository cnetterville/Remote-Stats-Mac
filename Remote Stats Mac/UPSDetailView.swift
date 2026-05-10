//
//  UPSDetailView.swift
//  Remote Stats Mac
//

import SwiftUI

// MARK: - View Model

@Observable
@MainActor
final class UPSViewModel {
    var stats: UPSStats? = nil
    var isLoading = false
    var error: String? = nil

    let config: NUTConfig

    init(config: NUTConfig) {
        self.config = config
    }

    func refresh() async {
        isLoading = true
        error = nil
        do {
            stats = try await NUTService.fetchStats(for: config)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Detail View

struct UPSDetailView: View {
    let config: NUTConfig
    @State private var viewModel: UPSViewModel

    init(config: NUTConfig) {
        self.config = config
        self._viewModel = State(initialValue: UPSViewModel(config: config))
    }

    var body: some View {
        ScrollView {
            if viewModel.isLoading && viewModel.stats == nil {
                ProgressView()
                    .padding(.top, 60)
                    .frame(maxWidth: .infinity)
            } else if let err = viewModel.error, viewModel.stats == nil {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text(err)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        Task { await viewModel.refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 60)
                .padding(.horizontal)
                .frame(maxWidth: .infinity)
            } else if let stats = viewModel.stats {
                UPSStatsContent(stats: stats)
            }
        }
        .navigationTitle(config.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if viewModel.isLoading {
                    ProgressView()
                } else {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .task { await viewModel.refresh() }
        .refreshable { await viewModel.refresh() }
    }
}

// MARK: - Stats Content

private struct UPSStatsContent: View {
    let stats: UPSStats

    var body: some View {
        VStack(spacing: 14) {
            statusBadge

            if let charge = stats.batteryCharge {
                batteryCard(charge: charge)
            }

            if stats.load != nil || stats.inputVoltage != nil || stats.outputVoltage != nil {
                powerCard
            }

            if !stats.model.isEmpty || !stats.manufacturer.isEmpty || stats.nominalPower != nil {
                deviceCard
            }
        }
        .padding()
    }

    // MARK: Status Badge

    private var statusBadge: some View {
        let flag = stats.primaryFlag
        let color = flag?.color ?? .gray
        let icon  = flag?.icon ?? "questionmark.circle"
        let text  = flag?.displayName ?? "Unknown"

        return HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text(text)
                .font(.title3.bold())
                .foregroundStyle(color)
            Spacer()
            if stats.statusFlags.contains(.charging) && (stats.batteryCharge ?? 0) < 99 {
                Label("Charging", systemImage: "battery.100percent.bolt")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.green.opacity(0.12), in: Capsule())
            }
            if stats.statusFlags.contains(.replaceBattery) {
                Label("Replace Battery", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.red.opacity(0.12), in: Capsule())
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Battery Card

    private func batteryCard(charge: Double) -> some View {
        StatCard(title: "Battery", icon: batteryIcon(charge), color: batteryColor(charge)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int(charge))%")
                        .font(.title.bold())
                        .monospacedDigit()
                        .foregroundStyle(batteryColor(charge))
                    Spacer()
                    if let runtime = stats.formattedRuntime {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(runtime)
                                .font(.subheadline.bold())
                                .monospacedDigit()
                            Text("remaining")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                ProgressView(value: charge / 100)
                    .tint(batteryColor(charge))

                if stats.batteryVoltage != nil || stats.batteryVoltageNominal != nil {
                    Divider()
                    HStack {
                        if let v = stats.batteryVoltage {
                            UPSLabeledValue(label: "Voltage", value: String(format: "%.1f V", v))
                        }
                        if let vn = stats.batteryVoltageNominal {
                            UPSLabeledValue(label: "Nominal", value: String(format: "%.0f V", vn))
                        }
                    }
                }
            }
        }
    }

    // MARK: Power Card

    private var powerCard: some View {
        StatCard(title: "Power", icon: "bolt.fill", color: .yellow) {
            VStack(alignment: .leading, spacing: 10) {
                if let load = stats.load {
                    HStack {
                        Text("Load")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.0f%%", load))
                            .font(.subheadline.bold())
                            .monospacedDigit()
                            .foregroundStyle(loadColor(load))
                    }
                    ProgressView(value: load / 100)
                        .tint(loadColor(load))
                }

                if stats.inputVoltage != nil || stats.outputVoltage != nil || stats.inputVoltageNominal != nil {
                    if stats.load != nil { Divider() }
                    HStack {
                        if let v = stats.inputVoltage {
                            UPSLabeledValue(label: "Input", value: String(format: "%.0f V", v))
                        }
                        if let v = stats.outputVoltage {
                            UPSLabeledValue(label: "Output", value: String(format: "%.0f V", v))
                        }
                        if let v = stats.inputVoltageNominal {
                            UPSLabeledValue(label: "Nominal", value: String(format: "%.0f V", v))
                        }
                    }
                }
            }
        }
    }

    // MARK: Device Card

    private var deviceCard: some View {
        StatCard(title: "Device", icon: "info.circle.fill", color: .secondary) {
            VStack(spacing: 0) {
                if !stats.manufacturer.isEmpty {
                    UPSDetailRow(label: "Manufacturer", value: stats.manufacturer)
                    Divider().padding(.vertical, 6)
                }
                if !stats.model.isEmpty {
                    UPSDetailRow(label: "Model", value: stats.model)
                }
                if let power = stats.nominalPower {
                    Divider().padding(.vertical, 6)
                    UPSDetailRow(label: "Capacity", value: "\(power) VA")
                }
                if !stats.rawStatus.isEmpty {
                    Divider().padding(.vertical, 6)
                    UPSDetailRow(label: "Status flags", value: stats.rawStatus)
                }
            }
            .font(.subheadline)
        }
    }

    // MARK: Helpers

    private func batteryColor(_ pct: Double) -> Color {
        if pct <= 20 { return .red }
        if pct <= 50 { return .orange }
        return .green
    }

    private func batteryIcon(_ pct: Double) -> String {
        if pct <= 25 { return "battery.25percent" }
        if pct <= 50 { return "battery.50percent" }
        if pct <= 75 { return "battery.75percent" }
        return "battery.100percent"
    }

    private func loadColor(_ pct: Double) -> Color {
        if pct > 80 { return .red }
        if pct > 50 { return .orange }
        return .green
    }
}

// MARK: - Supporting Views

struct UPSLabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.subheadline.bold())
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct UPSDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .bold()
                .multilineTextAlignment(.trailing)
        }
    }
}
