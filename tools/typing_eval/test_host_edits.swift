import Foundation

func runHostEditTests() {
    precondition(HostSuffixReplacementPlan(contextBeforeInput: "other", suffix: "typo", replacement: "type") == nil)
    let first = HostSuffixReplacementPlan(contextBeforeInput: "teh", suffix: "teh", replacement: "the")!
    var text = "teh"
    let replaced = first.apply(initialContext: text, deleteBackward: {
        text.removeLast(); return text.isEmpty ? nil : text
    }, insert: { text += $0 })
    precondition(replaced && text == "the")
    var deletions = 0, insertions = 0
    let stuck = first.apply(initialContext: "teh", deleteBackward: { deletions += 1; return "teh" }, insert: { _ in insertions += 1 })
    precondition(!stuck && deletions == 1 && insertions == 0)
    deletions = 0
    let grows = first.apply(initialContext: "teh", deleteBackward: { deletions += 1; return "teh-longer" }, insert: { _ in insertions += 1 })
    precondition(!grows && deletions == 1 && insertions == 0)
    let cluster = "క్ష"
    let plan = HostSuffixReplacementPlan(contextBeforeInput: "prefix " + cluster, suffix: cluster, replacement: "X")!
    var scalars = Array(("prefix " + cluster).unicodeScalars)
    var output = ""
    let ok = plan.apply(initialContext: String(String.UnicodeScalarView(scalars)), deleteBackward: {
        scalars.removeLast(); return String(String.UnicodeScalarView(scalars))
    }, insert: { output = $0 })
    precondition(ok && output == "X" && String(String.UnicodeScalarView(scalars)) == "prefix ")
    print("PASS: suffix validation, first-word nil context, stuck host, growing host, scalar-deleting Indic host")
}
