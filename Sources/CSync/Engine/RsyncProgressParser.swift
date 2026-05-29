import Foundation

struct RsyncProgressParser {
    func progress(from line: String) -> Double? {
        guard let range = line.range(of: #"(\d{1,3})%"#, options: .regularExpression) else {
            return nil
        }
        let percentText = line[range].dropLast()
        guard let percent = Double(percentText), percent >= 0, percent <= 100 else {
            return nil
        }
        return percent / 100
    }
}
