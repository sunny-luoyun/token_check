import SwiftUI

struct SessionListView: View {
    @StateObject private var viewModel = SessionListViewModel()
    @Environment(\.appTheme) var theme

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading {
                VStack(spacing: 12) {
                    Spacer()
                    RoundedRectangle(cornerRadius: theme.radiusMedium)
                        .fill(.quaternary.opacity(0.5))
                        .frame(height: 40)
                        .shimmering()
                        .padding(.horizontal)
                    RoundedRectangle(cornerRadius: theme.radiusMedium)
                        .fill(.quaternary.opacity(0.5))
                        .frame(maxWidth: .infinity)
                        .frame(height: 300)
                        .shimmering()
                        .padding(.horizontal)
                    Spacer()
                }
                .transition(.opacity)
            } else if let error = viewModel.error {
                errorView(error)
            } else {
                VStack(spacing: 0) {
                    timeFilterBar
                        .padding(.horizontal)
                        .padding(.vertical, 8)

                    Table(viewModel.filteredSessions) {
                        TableColumn("时间") { session in
                            Text(session.timeCreated, style: .date)
                                .font(.caption)
                        }
                        .width(100)

                        TableColumn("标题") { session in
                            Text(session.title ?? session.slug ?? "(无标题)")
                                .lineLimit(1)
                        }

                        TableColumn("模型") { session in
                            Text(session.modelDisplayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .width(160)

                        TableColumn("Input") { session in
                            let rollback = viewModel.showRollback ? viewModel.sessionRollbacks[session.id] : nil
                            let adjusted = session.tokensInput + (rollback?.asTokenData.tokensInput ?? 0)
                            Text(formatNumber(adjusted))
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .width(90)

                        TableColumn("Output") { session in
                            let rollback = viewModel.showRollback ? viewModel.sessionRollbacks[session.id] : nil
                            let adjusted = session.tokensOutput + (rollback?.asTokenData.tokensOutput ?? 0)
                            Text(formatNumber(adjusted))
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .width(90)

                        TableColumn("Cost") { session in
                            Text(String(format: "$%.4f", session.cost))
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .width(80)
                    }
                }
            }
        }
        .navigationTitle("会话历史")
        .searchable(text: $viewModel.searchText, prompt: "搜索标题、模型或项目")
        .toolbar {
            ToolbarItem {
                Button(action: viewModel.applyFilter) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
            }
            ToolbarItem {
                Toggle(isOn: $viewModel.showRollback) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .foregroundStyle(viewModel.showRollback ? .red : .secondary)
                }
                .toggleStyle(.button)
                .help("显示回滚消耗")
                .disabled(!viewModel.hasSessionRollback)
                .onChange(of: viewModel.showRollback) { _, _ in
                    viewModel.applyFilter()
                }
            }
        }
        .onAppear {
            viewModel.load()
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.filteredSessions.count)
    }

    private func errorView(_ error: String) -> some View {
        Spacer()
            .overlay {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(error)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("重试", action: viewModel.load)
                        .buttonStyle(.bordered)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private var timeFilterBar: some View {
        HStack {
            Spacer()
            TimeFilterView(
                years: viewModel.availableYears,
                months: viewModel.availableMonths,
                days: viewModel.availableDays,
                selectedYear: $viewModel.selectedYear,
                selectedMonth: $viewModel.selectedMonth,
                selectedDay: $viewModel.selectedDay,
                filterMode: $viewModel.filterMode,
                startDate: $viewModel.startDate,
                endDate: $viewModel.endDate,
                onChange: { viewModel.applyFilter() }
            )
            Spacer()
        }
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000_000 {
            String(format: "%.1fB", Double(n) / 1_000_000_000)
        } else if n >= 1_000_000 {
            String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            String(format: "%.1fK", Double(n) / 1_000)
        } else {
            "\(n)"
        }
    }
}
