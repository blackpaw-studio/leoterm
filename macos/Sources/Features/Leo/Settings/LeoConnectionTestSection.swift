import SwiftUI

/// The Test Connection box: the button, then the headline and one line per
/// step. A step that wasn't reached reads "Not tested".
struct LeoConnectionTestSection: View {
    let isTesting: Bool
    let report: LeoConnectionTestReport?
    let canTest: Bool
    let test: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Test Connection").fontWeight(.semibold)
                    Text("SSH, then the daemon. Nothing is saved.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Test Connection", action: test).disabled(isTesting || !canTest)
            }
            .padding(12)
            if isTesting {
                Divider()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Testing…").foregroundStyle(.secondary)
                }
                .padding(12)
            } else if let report {
                Divider()
                results(report).padding(12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
    }

    private func results(_ report: LeoConnectionTestReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: report.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(report.succeeded ? .green : .red)
                Text(report.succeeded ? "Connected" : "Connection failed")
                    .fontWeight(.semibold).foregroundStyle(report.succeeded ? Color.primary : .red)
                Spacer()
                Text(report.duration.formatted(.number.precision(.fractionLength(2))) + " s")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            ForEach(LeoConnectionTestStep.allCases, id: \.self) { step in
                stepRow(step, report.outcome(for: step))
            }
        }
    }

    private func stepRow(_ step: LeoConnectionTestStep, _ outcome: LeoConnectionTestOutcome) -> some View {
        let (symbol, color, detail): (String, Color, String) = switch outcome {
        case .passed(let text): ("checkmark.circle.fill", .green, text)
        case .failed(let text): ("xmark.circle.fill", .red, text)
        case .unavailable(let text): ("exclamationmark.triangle.fill", .orange, text)
        case .notTested: ("minus.circle", .secondary, "Not tested")
        }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(step.title).fontWeight(.medium).frame(width: 100, alignment: .leading)
            Text(detail)
                .foregroundStyle(outcome == .notTested ? Color.secondary : (isFailure(outcome) ? .red : .primary))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func isFailure(_ outcome: LeoConnectionTestOutcome) -> Bool {
        if case .failed = outcome { true } else { false }
    }
}
