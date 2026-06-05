import SwiftUI

struct SessionListView: View {
    @StateObject private var viewModel = SessionListViewModel()

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.error {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                            Text(formatNumber(session.tokensInput))
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .width(80)

                        TableColumn("Output") { session in
                            Text(formatNumber(session.tokensOutput))
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .width(80)

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
        }
        .onAppear {
            if viewModel.sessions.isEmpty {
                viewModel.load()
            }
        }
    }

    private var timeFilterBar: some View {
        HStack {
            Spacer()
            TimeFilterView(
                years: viewModel.availableYears,
                months: viewModel.availableMonths,
                selectedYear: $viewModel.selectedYear,
                selectedMonth: $viewModel.selectedMonth,
                onChange: { viewModel.applyFilter() }
            )
            Spacer()
        }
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000 {
            String(format: "%.1fK", Double(n) / 1_000)
        } else {
            "\(n)"
        }
    }
}
