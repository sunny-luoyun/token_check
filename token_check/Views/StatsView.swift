import SwiftUI

struct StatsView: View {
    @StateObject private var viewModel = StatsViewModel()
    @State private var selectedSegment: StatsSegment = .agent
    @Environment(\.appTheme) var theme

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading {
                loadingSkeleton
            } else if let error = viewModel.error {
                errorView(error)
            } else {
                VStack(spacing: 0) {
                    timeFilterBar
                        .padding(.horizontal)
                        .padding(.vertical, 8)

                    segmentPicker
                        .padding(.horizontal)
                        .padding(.bottom, 8)

                    Divider()

                    ScrollView {
                        VStack(spacing: 0) {
                            switch selectedSegment {
                            case .agent: agentContent
                            case .project: projectContent
                            case .efficiency: efficiencyContent
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("统计")
        .toolbar {
            ToolbarItem {
                Button(action: viewModel.applyFilter) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
            }
        }
        .onAppear { viewModel.load() }
    }

    private var loadingSkeleton: some View {
        VStack(spacing: 16) {
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

    // MARK: - Time Filter

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

    // MARK: - Segment Picker

    private var segmentPicker: some View {
        HStack {
            Picker("统计维度", selection: $selectedSegment) {
                ForEach(StatsSegment.allCases, id: \.self) { seg in
                    Text(seg.rawValue).tag(seg)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 360, alignment: .leading)

            Spacer()
        }
    }

    // MARK: - Agent Content

    private var agentContent: some View {
        VStack(spacing: 12) {
            if viewModel.agentUsage.isEmpty {
                emptyPlaceholder("暂无 Agent 数据")
            } else {
                agentSummaryCards
                    .padding(.horizontal)
                    .padding(.top, 12)

                Text("按 Agent 分解")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 8)

                agentTable
                    .padding(.horizontal)
            }
        }
    }

    private var agentSummaryCards: some View {
        let totalSessions = viewModel.agentUsage.reduce(0) { $0 + $1.sessions }
        let totalCost = viewModel.agentUsage.reduce(0) { $0 + $1.cost }
        let topAgent = viewModel.agentUsage.max(by: { $0.sessions < $1.sessions })

        return LazyVGrid(columns: [
            GridItem(.adaptive(minimum: 140), spacing: 12)
        ], spacing: 12) {
            StatCardView(
                title: "Agent 类型数",
                value: "\(viewModel.agentUsage.count)",
                subtitle: nil,
                icon: "cpu.fill",
                color: .purple
            )
            StatCardView(
                title: "总会话数",
                value: formatNumber(totalSessions),
                subtitle: nil,
                icon: "text.bubble.fill",
                color: .blue
            )
            StatCardView(
                title: "总费用",
                value: formatCost(totalCost),
                subtitle: nil,
                icon: "yensign.circle.fill",
                color: .red
            )
            if let top = topAgent {
                StatCardView(
                    title: "最活跃 Agent",
                    value: top.agentName,
                    subtitle: "\(top.sessions) 个会话",
                    icon: "star.fill",
                    color: .orange
                )
            }
        }
    }

    private var agentTable: some View {
        Table(viewModel.agentUsage) {
            TableColumn("Agent") { item in
                HStack(spacing: 6) {
                    Image(systemName: agentIcon(for: item.agentName))
                        .foregroundStyle(agentColor(for: item.agentName))
                    Text(item.agentName)
                        .font(.body.weight(.medium))
                }
            }
            .width(140)

            TableColumn("会话数") { item in
                Text(formatNumber(item.sessions))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(80)

            TableColumn("Input") { item in
                Text(formatNumber(item.inputTokens))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(90)

            TableColumn("Output") { item in
                Text(formatNumber(item.outputTokens))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(90)

            TableColumn("推理") { item in
                Text(formatNumber(item.reasoningTokens))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(90)

            TableColumn("缓存读取") { item in
                Text(formatNumber(item.cacheReadTokens))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(90)

            TableColumn("费用") { item in
                Text(formatCost(item.cost))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(90)
        }
        .frame(minHeight: 100, idealHeight: 400)
    }

    // MARK: - Project Content

    private var projectContent: some View {
        VStack(spacing: 12) {
            if viewModel.projectUsage.isEmpty {
                emptyPlaceholder("暂无项目数据")
            } else {
                projectSummaryCards
                    .padding(.horizontal)
                    .padding(.top, 12)

                Text("按项目分解")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 8)

                projectTable
                    .padding(.horizontal)
            }
        }
    }

    private var projectSummaryCards: some View {
        let totalSessions = viewModel.projectUsage.reduce(0) { $0 + $1.sessions }
        let totalCost = viewModel.projectUsage.reduce(0) { $0 + $1.cost }
        let topProject = viewModel.projectUsage.max(by: { $0.sessions < $1.sessions })

        return LazyVGrid(columns: [
            GridItem(.adaptive(minimum: 140), spacing: 12)
        ], spacing: 12) {
            StatCardView(
                title: "项目数",
                value: "\(viewModel.projectUsage.count)",
                subtitle: nil,
                icon: "folder.fill",
                color: .indigo
            )
            StatCardView(
                title: "总会话数",
                value: formatNumber(totalSessions),
                subtitle: nil,
                icon: "text.bubble.fill",
                color: .blue
            )
            StatCardView(
                title: "总费用",
                value: formatCost(totalCost),
                subtitle: nil,
                icon: "yensign.circle.fill",
                color: .red
            )
            if let top = topProject {
                StatCardView(
                    title: "最活跃项目",
                    value: top.displayName,
                    subtitle: "\(top.sessions) 个会话",
                    icon: "star.fill",
                    color: .orange
                )
            }
        }
    }

    private var projectTable: some View {
        Table(viewModel.projectUsage) {
            TableColumn("项目") { item in
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.indigo)
                    Text(item.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                }
            }

            TableColumn("会话数") { item in
                Text(formatNumber(item.sessions))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(80)

            TableColumn("Input") { item in
                Text(formatNumber(item.inputTokens))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(90)

            TableColumn("Output") { item in
                Text(formatNumber(item.outputTokens))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(90)

            TableColumn("推理") { item in
                Text(formatNumber(item.reasoningTokens))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(90)

            TableColumn("费用") { item in
                Text(formatCost(item.cost))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(90)
        }
        .frame(minHeight: 100, idealHeight: 400)
    }

    // MARK: - Efficiency Content

    private var efficiencyContent: some View {
        VStack(spacing: 12) {
            if viewModel.efficiencySummary.sessionsWithChanges == 0 {
                emptyPlaceholder("暂无代码变更数据")
            } else {
                efficiencySummaryCards
                    .padding(.horizontal)
                    .padding(.top, 12)

                Text("效率详情")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 8)

                efficiencyTable
                    .padding(.horizontal)
            }
        }
    }

    private var efficiencySummaryCards: some View {
        let s = viewModel.efficiencySummary
        return LazyVGrid(columns: [
            GridItem(.adaptive(minimum: 130), spacing: 12)
        ], spacing: 12) {
            StatCardView(
                title: "新增行数",
                value: formatNumber(s.totalAdditions),
                subtitle: nil,
                icon: "plus.circle.fill",
                color: .green
            )
            StatCardView(
                title: "删除行数",
                value: formatNumber(s.totalDeletions),
                subtitle: nil,
                icon: "minus.circle.fill",
                color: .red
            )
            StatCardView(
                title: "变更文件",
                value: formatNumber(s.totalFiles),
                subtitle: nil,
                icon: "doc.text.fill",
                color: .blue
            )
            StatCardView(
                title: "净增行数",
                value: formatNumber(s.netLines),
                subtitle: nil,
                icon: "arrow.up.arrow.down.circle.fill",
                color: .teal
            )
            StatCardView(
                title: "效率",
                value: String(format: "%.1f", s.avgLinesPer1KTokens),
                subtitle: "行/千token",
                icon: "speedometer",
                color: .orange
            )
            StatCardView(
                title: "含变更会话",
                value: formatNumber(s.sessionsWithChanges),
                subtitle: nil,
                icon: "number.circle.fill",
                color: .purple
            )
        }
    }

    private var efficiencyTable: some View {
        Table(viewModel.efficiencyDetails) {
            TableColumn("标题") { item in
                Text(item.title)
                    .font(.caption)
                    .lineLimit(1)
            }

            TableColumn("模型") { item in
                Text(item.modelId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .width(120)

            TableColumn("Agent") { item in
                HStack(spacing: 4) {
                    Image(systemName: agentIcon(for: item.agent))
                        .foregroundStyle(agentColor(for: item.agent))
                    Text(item.agent)
                        .font(.caption)
                }
            }
            .width(80)

            TableColumn("新增") { item in
                Text(formatNumber(item.additions))
                    .font(.caption.monospaced())
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(70)

            TableColumn("删除") { item in
                Text(formatNumber(item.deletions))
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(70)

            TableColumn("文件") { item in
                Text("\(item.files)")
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(50)

            TableColumn("Tokens") { item in
                Text(formatNumber(item.totalTokens))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(80)

            TableColumn("行/千tok") { item in
                Text(String(format: "%.1f", item.linesPer1KTokens))
                    .font(.caption.monospaced())
                    .foregroundStyle(item.linesPer1KTokens > 10 ? .green : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(80)
        }
        .frame(minHeight: 100, idealHeight: 400)
    }

    // MARK: - Helpers

    private func emptyPlaceholder(_ text: String) -> some View {
        Spacer()
            .overlay {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(text)
                        .foregroundStyle(.secondary)
                }
            }
    }

    private func agentIcon(for agent: String) -> String {
        switch agent.lowercased() {
        case "code": return "chevron.left.forwardslash.chevron.right"
        case "explore": return "magnifyingglass"
        case "debug": return "ant.fill"
        case "general": return "brain"
        default: return "questionmark.circle"
        }
    }

    private func agentColor(for agent: String) -> Color {
        switch agent.lowercased() {
        case "code": return .blue
        case "explore": return .green
        case "debug": return .red
        case "general": return .purple
        default: return .gray
        }
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000 {
            String(format: "%.2fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            String(format: "%.1fK", Double(n) / 1_000)
        } else {
            "\(n)"
        }
    }

    private func formatCost(_ c: Double) -> String {
        String(format: "¥%.4f", c)
    }
}
