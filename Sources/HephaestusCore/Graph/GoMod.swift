/// The modules a `go.mod` requires: the lines of its require blocks and its single require lines,
/// never those of its replace directives (docs/graph.md › Boxes).
public enum GoMod {
    public static func requirements(of text: String) -> [String] {
        var paths: [String] = []
        var inBlock = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = Substring(rawLine)
            if let comment = line.range(of: "//") {
                line = line[..<comment.lowerBound]
            }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).map(String.init)
            guard let first = fields.first else { continue }
            if inBlock {
                if first == ")" {
                    inBlock = false
                } else {
                    paths.append(first)
                }
                continue
            }
            if first == "require(" || (first == "require" && fields.count > 1 && fields[1] == "(") {
                inBlock = true
            } else if first == "require", fields.count > 1 {
                paths.append(fields[1])
            }
        }
        return paths
    }
}
