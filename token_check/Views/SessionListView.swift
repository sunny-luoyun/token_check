import SwiftUI

struct SessionListView: View {
    @StateObject private var viewModel = SessionListViewModel()
    @State private var hoveredSessionID: Session.ID?

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
                    PageHeaderView(
                        title: "会话历史",
                        subtitle: "\(viewModel.filteredSessions.count) 个会话"
                    ) {
                        HStack(spacing: 8) {
                            searchField

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

                            Button(action: viewModel.applyFilter) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption)
                                    .padding(6)
                                    .background(.quaternary.opacity(0.3))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isLoading)
                            .help("刷新")

                            Toggle(isOn: $viewModel.showRollback) {
                                Image(systemName: "arrow.counterclockwise.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(viewModel.showRollback ? theme.rollback : .secondary)
                                    .padding(6)
                                    .background(.quaternary.opacity(0.3))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .toggleStyle(.button)
                            .buttonStyle(.plain)
                            .help("显示回滚消耗")
                            .disabled(!viewModel.hasSessionRollback)
                            .onChange(of: viewModel.showRollback) { _, _ in
                                viewModel.applyFilter()
                            }
                        }
                    }

                    DataSourceSwitchBar(
                        dataSource: $viewModel.dataSource,
                        detailText: { source in
                            if source == .dsh {
                                return viewModel.dshLevel == .full
                                    ? "DeepSeek Harness · 事件级（L2）"
                                    : "DeepSeek Harness · 投影缓存（L1）"
                            }
                            return source.detailText
                        }
                    )

                    Divider()

                    sessionTable
                        .padding(16)
                }
            }
        }
        .navigationTitle("会话历史")
        .onAppear {
            viewModel.load()
        }
        .onChange(of: viewModel.dataSource) { _, _ in
            viewModel.load()
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.filteredSessions.count)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("搜索标题、模型或项目", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary.opacity(0.3))
        )
        .frame(width: 200)
    }

    private var sessionTable: some View {
        Table(viewModel.filteredSessions) {
            TableColumn("时间") { session in
                Text(session.timeCreated, style: .date)
                    .font(.caption)
                    .onHover { hovering in
                        hoveredSessionID = hovering ? session.id : nil
                    }
            }
            .width(100)

            TableColumn("标题") { session in
                Text(session.title ?? session.slug ?? "(无标题)")
                    .lineLimit(1)
                    .foregroundStyle(hoveredSessionID == session.id ? Color.accentColor : .primary)
                    .onHover { hovering in
                        hoveredSessionID = hovering ? session.id : nil
                    }
            }
            .width(200)

            TableColumn("模型") { session in
                Text(session.modelDisplayName)
                    .font(.caption)
                    .foregroundStyle(hoveredSessionID == session.id ? Color.accentColor : .secondary)
                    .onHover { hovering in
                        hoveredSessionID = hovering ? session.id : nil
                    }
            }
            .width(160)

            TableColumn("未命中") { session in
                let rollback = viewModel.showRollback ? viewModel.sessionRollbacks[session.id] : nil
                let adjusted = session.tokensInput + (rollback?.asTokenData.tokensInput ?? 0)
                Text(formatNumber(adjusted))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .onHover { hovering in
                        hoveredSessionID = hovering ? session.id : nil
                    }
            }
            .width(90)

            TableColumn("命中") { session in
                let rollback = viewModel.showRollback ? viewModel.sessionRollbacks[session.id] : nil
                let adjusted = session.tokensCacheRead + (rollback?.asTokenData.tokensCacheRead ?? 0)
                Text(formatNumber(adjusted))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .onHover { hovering in
                        hoveredSessionID = hovering ? session.id : nil
                    }
            }
            .width(90)

            TableColumn("Output") { session in
                let rollback = viewModel.showRollback ? viewModel.sessionRollbacks[session.id] : nil
                let adjusted = session.tokensOutput + (rollback?.asTokenData.tokensOutput ?? 0)
                Text(formatNumber(adjusted))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .onHover { hovering in
                        hoveredSessionID = hovering ? session.id : nil
                    }
            }
            .width(90)

            TableColumn("Cost") { session in
                Text(String(format: "$%.4f", session.cost))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .onHover { hovering in
                        hoveredSessionID = hovering ? session.id : nil
                    }
            }
            .width(80)
        }
        .alternatingRowBackgrounds()
        .frame(minHeight: 200, maxHeight: .infinity)
        .mainContentCard()
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
