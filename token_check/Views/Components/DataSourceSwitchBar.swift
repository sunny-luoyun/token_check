import SwiftUI

/// 数据源切换行（opencode / DSH），费用、趋势、会话、统计页共用
struct DataSourceSwitchBar: View {
    @Binding var dataSource: StatsDataSource
    /// 数据源说明文字（跟随选择变化）
    var detailText: (StatsDataSource) -> String

    var body: some View {
        HStack(spacing: 8) {
            Picker("数据源", selection: $dataSource) {
                ForEach(StatsDataSource.allCases, id: \.self) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            .help("统计来源")

            Text(detailText(dataSource))
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}
