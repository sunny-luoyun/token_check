import SwiftUI

struct TimeFilterView: View {
    let years: [String]
    let months: [String]
    @Binding var selectedYear: String?
    @Binding var selectedMonth: String?
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Picker("年份", selection: Binding(
                get: { selectedYear ?? "全部" },
                set: {
                    if $0 == "全部" {
                        selectedYear = nil
                        selectedMonth = nil
                    } else {
                        selectedYear = $0
                        selectedMonth = nil
                    }
                    onChange()
                }
            )) {
                ForEach(years, id: \.self) { year in
                    Text(year == "全部" ? "全部年份" : "\(year)年").tag(year)
                }
            }
            .pickerStyle(.menu)

            if !months.isEmpty {
                Picker("月份", selection: Binding(
                    get: { selectedMonth ?? "全部" },
                    set: {
                        selectedMonth = $0 == "全部" ? nil : $0
                        onChange()
                    }
                )) {
                    ForEach(months, id: \.self) { month in
                        if month == "全部" {
                            Text("全部月份").tag(month)
                        } else {
                            Text("\(Int(month) ?? 0)月").tag(month)
                        }
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .labelsHidden()
    }
}
