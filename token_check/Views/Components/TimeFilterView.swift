import SwiftUI

struct TimeFilterView: View {
    let years: [String]
    let months: [String]
    let days: [String]
    @Binding var selectedYear: String?
    @Binding var selectedMonth: String?
    @Binding var selectedDay: String?
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Picker("年份", selection: Binding(
                get: { selectedYear ?? "全部" },
                set: {
                    if $0 == "全部" {
                        selectedYear = nil
                        selectedMonth = nil
                        selectedDay = nil
                    } else {
                        selectedYear = $0
                        selectedMonth = nil
                        selectedDay = nil
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
                        selectedDay = nil
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

            if !days.isEmpty {
                Picker("日期", selection: Binding(
                    get: { selectedDay ?? "全部" },
                    set: {
                        selectedDay = $0 == "全部" ? nil : $0
                        onChange()
                    }
                )) {
                    ForEach(days, id: \.self) { day in
                        if day == "全部" {
                            Text("全部日期").tag(day)
                        } else {
                            Text("\(Int(day) ?? 0)日").tag(day)
                        }
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .labelsHidden()
    }
}
