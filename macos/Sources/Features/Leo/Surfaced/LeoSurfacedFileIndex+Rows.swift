import Foundation
import LeoKit

extension LeoSurfacedFileIndex {
    func attach(to rows: [LeoAgentRow]) -> [LeoAgentRow] {
        rows.map { $0.withSurfacedFiles(files(name: $0.name, startedAt: $0.startedAt)) }
    }
}
