// FloatPrompter — 可調透明度的懸浮提詞器
// 題目庫搜尋 / 自動播放 / 手動滾輪 / 重點句標示

import Cocoa
import Carbon
import NaturalLanguage
import FoundationModels

// MARK: - Paste parsing & keyword extraction

let quoteChars = CharacterSet(charactersIn: "\"“”‘’'「」『』")

/// 貼上的文字 → 一或多題。第一行永遠是題目；之後「空行 + 以 ? 結尾的短句」視為下一題。
func parsePasted(_ raw: String) -> [(String, String)] {
    let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var out: [(String, [String])] = []
    var prevBlank = true
    for line in lines {
        let t = line.trimmingCharacters(in: .whitespaces)
        let isQ = (t.hasSuffix("?") || t.hasSuffix("？")) && t.count < 160
        if out.isEmpty {
            if !t.isEmpty { out.append((t, [])) }
        } else if isQ && prevBlank {
            out.append((t, []))
        } else {
            out[out.count - 1].1.append(line)
        }
        prevBlank = t.isEmpty
    }
    return out.map { title, bodyLines in
        let body = bodyLines.map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: quoteChars) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (title.trimmingCharacters(in: quoteChars), body)
    }
}

// 重點句：從答案中挑出最重要的幾句（Apple 裝置端模型；不可用時改用詞頻評分）

/// 把內文拆成句子（跳過小標題；條列每行算一句），文字與提詞畫面上顯示的一致
func splitSentences(_ body: String) -> [String] {
    var out: [String] = []
    for raw in body.replacingOccurrences(of: "**", with: "").components(separatedBy: "\n") {
        var l = raw.trimmingCharacters(in: .whitespaces)
        if l.isEmpty || l.hasPrefix("#") { continue }
        if l.hasPrefix("- ") || l.hasPrefix("* ") { l = String(l.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        let tok = NLTokenizer(unit: .sentence)
        tok.string = l
        tok.enumerateTokens(in: l.startIndex..<l.endIndex) { r, _ in
            let s = String(l[r]).trimmingCharacters(in: .whitespaces)
            if s.count >= 4 { out.append(s) }
            return true
        }
    }
    return out
}

// MARK: - Answer structure (STAR / Past-Present-Future / Why us)

let kAnalysisVersion = 4

struct Seg: Codable, Equatable {
    var part: String          // S T A R / PAST PRESENT FUTURE / COMPANY ROLE ME / OTHER
    var text: String
    var phrases: [String]
}

let topicList = ["Leadership", "Influence without authority", "Stakeholder management", "Cross-functional collaboration",
                 "Conflict", "Disagree with manager", "Failure or mistake", "Ambiguity", "Prioritization", "Tight deadline",
                 "Data-driven decision", "Process improvement", "Initiative and ownership", "Customer focus",
                 "Learning quickly", "Communication", "Innovation", "Difficult feedback"]

/// 題型 → (代號, 段落名, 範例)
struct Framework {
    let kind: String
    let display: String
    let parts: [(code: String, letter: String, name: String, desc: String)]
    let example: String
    let exampleOut: String
}

let frameworks: [Framework] = [
    Framework(kind: "behavioral", display: "Behavioral",
              parts: [("S", "S", "Situation", "situation: background, where and when"),
                      ("T", "T", "Task", "task or problem: the challenge, what needed to be fixed"),
                      ("A", "A", "Action", "action: what I personally did"),
                      ("R", "R", "Result", "result: outcome, numbers, what changed")],
              example: """
              1. Last year I worked at a retail chain.
              2. Our store had the lowest sales in the region and I had to fix it in one quarter.
              3. I interviewed customers and redesigned the layout.
              4. I also trained staff on upselling.
              5. Sales grew 18% in three months.
              """, exampleOut: "1=S 2=T 3=A 4=A 5=R"),
    Framework(kind: "tmay", display: "Tell me about yourself",
              parts: [("PAST", "P", "Past", "past: background, education, earlier experience"),
                      ("PRESENT", "N", "Present", "present: what I do now, current role or study"),
                      ("FUTURE", "F", "Future", "future: goals, why this next step")],
              example: """
              1. I studied economics in Taipei.
              2. After that I spent two years in supply chain at a logistics company.
              3. Right now I'm doing my master's in data analytics.
              4. Next, I want to use data to make operations faster, which is why this role fits.
              """, exampleOut: "1=P 2=P 3=N 4=F"),
    Framework(kind: "whyus", display: "Why us",
              parts: [("COMPANY", "C", "Why company", "company: facts about the company, its products, customers, mission"),
                      ("ROLE", "R", "Why role", "role: why this specific role or team"),
                      ("ME", "M", "Why me", "me: why the speaker's skills or experience fit")],
              example: """
              1. Your company makes eco-friendly packaging for big retailers.
              2. I like that the analyst role works directly with the operations team.
              3. In my last job I cut shipping costs 10% with data, so I can help quickly.
              """, exampleOut: "1=C 2=R 3=M"),
]

func framework(_ kind: String?) -> Framework? { frameworks.first { $0.kind == kind } }

func partName(_ code: String, kind: String?) -> String {
    framework(kind)?.parts.first { $0.code == code }?.name ?? "Other"
}

/// 顏色跟 interview-answer-map 一樣：S/Past/Why company 藍、T/Present/Why role 棕、A/Future/Why me 綠、R 紅、Other 灰
func partIndex(_ code: String, kind: String?) -> Int {
    guard let f = framework(kind), let i = f.parts.firstIndex(where: { $0.code == code }) else { return 4 }
    return i
}
let barColors: [NSColor] = ["#2F69A8", "#8A5A1C", "#1F7A5E", "#9A3A5C", "#6B6A63"].map(hex)
let textColors: [NSColor] = ["#9CC4F0", "#EDC27F", "#86DABA", "#F2A7C0", "#C8C6BE"].map(hex)

func hex(_ s: String) -> NSColor {
    let v = Int(s.dropFirst(), radix: 16) ?? 0
    return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
                   blue: CGFloat(v & 255) / 255, alpha: 1)
}

func ask(_ prompt: String) async -> String? {
    guard case .available = SystemLanguageModel.default.availability else { return nil }
    return try? await LanguageModelSession().respond(to: prompt, options: GenerationOptions(sampling: .greedy)).content
}

/// 先用題目字面判斷題型，判斷不出來才問模型
func detectKind(_ question: String, _ answer: String) async -> String {
    let q = question.lowercased()
    let has = { (ws: [String]) in ws.contains { q.contains($0) } }
    if has(["about yourself", "walk me through your", "introduce yourself", "introduction", "自我介紹", "your background", "about you"]) { return "tmay" }
    if has(["why us", "why do you want", "why this", "why our", "why are you interested", "know about us",
            "about our company", "why should we", "why join", "why here", "為什麼想", "為什麼選", "了解我們"]) { return "whyus" }
    if has(["tell me about a time", "give an example", "describe a time", "describe a situation", "a time when",
            "a time you", "how did you handle", "walk me through a"]) { return "behavioral" }
    guard let r = await ask("""
    Is this interview answer a story about one specific past experience (what happened, what I did, the result)? \
    Answer only yes or no.

    Question: \(question)
    Answer: \(answer)
    """) else { return "behavioral" }
    if r.lowercased().contains("yes") { return "behavioral" }
    let r2 = await ask("""
    Is this interview answer mainly about the company or job (answer: company) or about the speaker's own background \
    and goals (answer: self)? Answer only one word.

    Question: \(question)
    Answer: \(answer)
    """) ?? ""
    return r2.lowercased().contains("self") ? "tmay" : "whyus"
}

/// 明顯的線索直接判斷（小模型在這兩種題型不穩）
/// 開場打招呼、自我介紹名字這類句子歸到 Other
func isGreeting(_ s: String) -> Bool {
    let l = s.lowercased().replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespaces)
    let words = l.split(whereSeparator: { $0.isWhitespace }).count
    let starts = ["hi", "hello", "hey", "good morning", "good afternoon", "thank you", "thanks", "my name is", "nice to meet"]
    return words <= 8 && starts.contains { l.hasPrefix($0) }
}

/// 明顯的線索直接判斷（小模型在這兩種題型不穩）
func cueLabel(_ s: String, kind: String) -> String? {
    if isGreeting(s) { return "OTHER" }
    let l = " " + s.lowercased().replacingOccurrences(of: "’", with: "'") + " "
    let has = { (ws: [String]) in ws.contains { l.contains($0) } }
    switch kind {
    case "tmay":
        if has([" want ", " hope ", " i'd love", " i would love", " looking forward", " next step", " in the future",
                " my goal", " i'd like", " excited about", " excited to", " eager to", " which is why", " that's why",
                " why i'm", " this role", " this position", " your team"]) { return "FUTURE" }
        if has([" now ", " currently", " right now", " these days", " at the moment", " finishing", " i'm studying",
                " i'm working", " i'm a ", " i am a ", " i'm pursuing"]) { return "PRESENT" }
        let pastVerb = l.range(of: "\\b(i|we|i've|i have|i've also|i also)\\s+(\\w+\\s+)?\\w{2,}ed\\b", options: .regularExpression) != nil
        if pastVerb || has([" studied", " graduated", " worked ", " was ", " were ", " spent ", " started ", " before ",
                            " previously", " last year", " ago", " grew up", " majored", " interned", " led ", " built ",
                            " joined ", " lived ", " this summer", " last summer", " i'm from ", " i am from ", " i'm originally"]) { return "PAST" }
        if has([" i'm ", " i am "]) { return "PRESENT" }
    case "whyus":
        if has([" i ", " i'm ", " i've ", " my "]) && !has([" you ", " your "]) {
            return has([" role", " position", " this job", " the team", " work on ", " work with "]) ? "ROLE" : "ME"
        }
        if has([" role", " position", " this job", " this team"]) { return "ROLE" }
        if has([" you ", " your ", " company", " customers", " products", " mission"]) { return "COMPANY" }
    default: break
    }
    return nil
}

func labelSentences(_ sents: [String], _ f: Framework, question: String) async -> [String] {
    let q = question.lowercased()
    if f.kind == "whyus" && ["know about us", "about our company", "know about our", "了解我們"].contains(where: { q.contains($0) }) {
        return sents.map { _ in "COMPANY" }
    }
    if f.kind != "behavioral" {
        let cues = sents.map { cueLabel($0, kind: f.kind) }
        if cues.allSatisfy({ $0 != nil }) { return cues.map { $0! } }
        let model = await labelByModel(sents, f)
        return zip(cues, model).map { $0 ?? $1 }
    }
    let model = await labelByModel(sents, f)
    return zip(sents, model).map { isGreeting($0) ? "OTHER" : $1 }
}

func labelByModel(_ sents: [String], _ f: Framework) async -> [String] {
    let numbered = sents.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    let defs = f.parts.map { "\($0.letter) = \($0.desc)" }.joined(separator: "\n")
    let reply = await ask("""
    Label each sentence of this interview answer with one letter:
    \(defs)

    Example answer:
    \(f.example)
    Example output:
    \(f.exampleOut)

    Now label this answer. Output only the labels in the same format.
    \(numbered)
    """) ?? ""
    var byNum: [Int: String] = [:]
    let re = try! NSRegularExpression(pattern: "(\\d+)\\s*[=.:)\\-]\\s*([A-Za-z])")
    for m in re.matches(in: reply, range: NSRange(reply.startIndex..., in: reply)) {
        guard let nr = Range(m.range(at: 1), in: reply), let lr = Range(m.range(at: 2), in: reply),
              let n = Int(reply[nr]) else { continue }
        let letter = reply[lr].uppercased()
        if let p = f.parts.first(where: { $0.letter == letter }) { byNum[n] = p.code }
    }
    // 沒標到的句子：照位置補（第一句是第一段、最後一句是最後一段）
    var out: [String] = []
    for i in 0..<sents.count {
        if let c = byNum[i + 1] { out.append(c); continue }
        if i == 0 { out.append(f.parts[0].code) }
        else if i == sents.count - 1 && sents.count > 2 { out.append(f.parts.last!.code) }
        else { out.append(out.last ?? f.parts[0].code) }
    }
    return out
}

let phraseStop: Set<String> = ["a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "with", "our", "my", "we", "i", "was", "were", "is", "are", "it", "that", "this"]

func wordRanges(_ s: String) -> [(String, Range<String.Index>)] {
    let t = NLTokenizer(unit: .word)
    t.string = s
    return t.tokens(for: s.startIndex..<s.endIndex).map { (s[$0].lowercased(), $0) }
}

/// 模型抄的片語常常有一點改寫，對回原文中最接近的那一段
func alignPhrase(_ phrase: String, in text: String) -> String? {
    let p = phrase.trimmingCharacters(in: CharacterSet(charactersIn: " -•*\"“”.:;,0123456789").union(.whitespacesAndNewlines))
    guard p.count >= 2 else { return nil }
    if let r = text.range(of: p, options: .caseInsensitive) { return String(text[r]) }
    let pw = Set(wordRanges(p).map { $0.0 }.filter { !phraseStop.contains($0) })
    guard !pw.isEmpty else { return nil }
    let tw = wordRanges(text)
    var best: (count: Int, span: Int, a: Int, b: Int)?
    for i in tw.indices where pw.contains(tw[i].0) {
        var seen = Set<String>()
        for j in i..<min(tw.count, i + 16) where pw.contains(tw[j].0) {
            seen.insert(tw[j].0)
            let cand = (seen.count, j - i, i, j)
            if best == nil || cand.0 > best!.count || (cand.0 == best!.count && cand.1 < best!.span) { best = cand }
        }
    }
    guard let b = best, Double(b.count) >= max(1, (Double(pw.count) * 0.6).rounded(.up)),
          !(pw.count == 1 && (pw.first?.count ?? 0) < 3) else { return nil }
    return String(text[tw[b.a].1.lowerBound..<tw[b.b].1.upperBound])
}

/// 去掉片語頭尾的 and / the / of 這類字
func trimEdges(_ p: String) -> String {
    var w = wordRanges(p)
    while let f = w.first, phraseStop.contains(f.0) { w.removeFirst() }
    while let l = w.last, phraseStop.contains(l.0) { w.removeLast() }
    guard let a = w.first, let b = w.last else { return "" }
    return String(p[a.1.lowerBound..<b.1.upperBound])
}

/// 數字後面的 % 一起帶上
func extendPercent(_ p: String, in text: String) -> String {
    guard let r = text.range(of: p), r.upperBound < text.endIndex, text[r.upperBound] == "%" else { return p }
    return p + "%"
}

/// 片語太短（像 "Beijing"）就擴成它所在的子句（"lived in Beijing and worked in Shanghai"）
func expandToClause(_ p: String, in sentence: String) -> String {
    guard p.split(whereSeparator: { $0.isWhitespace }).count < 4 else { return p }
    let ns = sentence as NSString
    let re = try! NSRegularExpression(pattern: "[,;:]|\\s(?=(so|where|which|while|because|but)\\s)", options: .caseInsensitive)
    var cuts = [0]
    for m in re.matches(in: sentence, range: NSRange(location: 0, length: ns.length)) { cuts.append(m.range.location + m.range.length) }
    cuts.append(ns.length)
    let pr = ns.range(of: p, options: .caseInsensitive)
    guard pr.location != NSNotFound else { return p }
    for i in 0..<(cuts.count - 1) where cuts[i] <= pr.location && pr.location + pr.length <= cuts[i + 1] {
        var clause = ns.substring(with: NSRange(location: cuts[i], length: cuts[i + 1] - cuts[i]))
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?\"“”"))
        let filler: Set<String> = ["and", "so", "but", "then", "also", "i", "i'm", "i’m", "i've", "i’ve", "we", "we're",
                                   "where", "which", "while", "because", "that", "i'd", "i’d", "am", "have", "just", "really"]
        var words = clause.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        while let f = words.first, filler.contains(f.lowercased()), words.count > 2 { words.removeFirst() }
        clause = words.joined(separator: " ")
        let wc = words.count
        return (wc >= 2 && wc <= 10 && sentence.range(of: clause) != nil) ? clause : p
    }
    return p
}

/// 一句話 → 1–2 個能讓人接得下去的關鍵片語（3–8 字，原文照抄）
func keyPhrases(_ text: String) async -> [String] {
    guard let reply = await ask("""
    Turn one sentence of an interview answer into 1 or 2 cue phrases for a teleprompter. Each phrase is 3 to 8 words \
    copied exactly from the sentence, and together they keep the facts the speaker must remember: names, places, \
    numbers, what they did. Skip filler like "I'm also" or "so".

    Sentence: Last year I worked at Nike's Taipei office, where I managed inventory reports for 40 stores.
    Phrases:
    worked at Nike's Taipei office
    managed inventory reports for 40 stores

    Sentence: That experience is why I'm excited about building data tools for your team.
    Phrases:
    building data tools for your team

    Sentence: \(text)
    Phrases:
    """) else { return [] }
    var out: [String] = []
    for line in reply.components(separatedBy: "\n") {
        guard let a0 = alignPhrase(line, in: text) else { continue }
        let a = expandToClause(extendPercent(trimEdges(a0), in: text), in: text)
        let wc = a.split(whereSeparator: { $0.isWhitespace }).count
        guard a.count >= 3, wc <= 10 else { continue }
        let low = a.lowercased()
        if out.contains(where: { $0.lowercased().contains(low) }) { continue }
        out.removeAll { low.contains($0.lowercased()) }
        out.append(a)
        if out.count == 2 { break }
    }
    if out.isEmpty {   // 模型沒給：取句子開頭的子句
        let words = text.split(separator: " ").prefix(9).joined(separator: " ")
        let first = expandToClause(String(text.split(separator: " ").prefix(2).joined(separator: " ")), in: text)
        let pick = first.split(separator: " ").count >= 3 ? first : trimEdges(words.trimmingCharacters(in: .punctuationCharacters))
        if !pick.isEmpty { out = [pick] }
    }
    return out
}

/// 適合的題目主題：用線索字計分（裝置端小模型挑主題不可靠，會全部說 yes）
/// A、T 段的句子權重較高，因為主題通常看「你做了什麼、遇到什麼」
let topicCues: [String: [String]] = [
    "Leadership": [" led ", " lead ", "my team", "delegat", "assigned", "mentored", "coordinated the team", "managed a team"],
    "Influence without authority": ["convinc", "persuad", "explained why", "explained to them", "without authority", "got them to", "bought in", "buy-in", "won them over", "didn't report to", "influence", "didn't have authority", "no authority", "no formal authority"],
    "Stakeholder management": ["ceo", "investor", "client", "executive", "stakeholder", "my manager", "director", "vp ", "leadership team", "board"],
    "Cross-functional collaboration": ["dev team", "engineering", "engineers", "design team", "designers", "sales team", "marketing", "operations team", "procurement", "across teams", "departments", "other teams", "both teams", "teams in"],
    "Conflict": ["disagree", "conflict", "tension", "argued", "clash", "pushback from"],
    "Disagree with manager": ["pushed back on my manager", "disagreed with my manager", "my manager wanted", "my boss wanted", "challenged my manager"],
    "Failure or mistake": ["mistake", " error", "failed", "failure", "went wrong", "i owned", "my fault", "missed the", "messed up"],
    "Ambiguity": ["unclear", "ambiguous", "no clear", "uncertain", "no guidance", "without instructions", "figure out"],
    "Prioritization": ["prioritiz", "split the", "broke it into", "smaller pieces", "trade-off", "tradeoff", "most important", "focus on", "first, i"],
    "Tight deadline": ["deadline", "one week", "two weeks", "in a week", "within ten days", "within a week", "on time", "day early", "days early", "time pressure", "urgent", "lost three days", "overnight"],
    "Data-driven decision": ["analysis", "analyz", "metrics", "dashboard", "forecast", "sql", "a/b test", "the data showed", "based on the data", "data-driven", "decided based"],
    "Process improvement": ["process", "checklist", "automat", "streamlin", "template", "jira", "workflow", "sanity check", "tracker", "system to"],
    "Initiative and ownership": ["i set up", "i created", "i built", "i decided", "on my own", "took the initiative", "volunteered", "i owned", "followed up", "following up", "took ownership", "co-founded", "until it's resolved", "ownership"],
    "Customer focus": ["customer", "user feedback", "users", "client needs", "end user"],
    "Learning quickly": ["learned", "taught myself", "new to", "ramp up", "picked up", "from scratch"],
    "Communication": ["explained", "presented", "communicat", "one-on-one", "checked in", "aligned", "updated everyone", "walked them through"],
    "Innovation": ["new idea", "invented", "prototype", "first time", "creative", "new approach", "new feature"],
    "Difficult feedback": ["feedback", "critic", "hard conversation", "tough conversation"],
]

func fitTopics(_ segs: [Seg], title: String = "") -> [String] {
    var score: [String: Double] = [:]
    let tl = " " + title.lowercased().replacingOccurrences(of: "’", with: "'") + " "
    for (topic, cues) in topicCues where cues.contains(where: { tl.contains($0) }) { score[topic, default: 0] += 2 }
    for seg in segs where seg.part != "OTHER" {
        let w: Double = (seg.part == "A" || seg.part == "T") ? 1.5 : 1.0
        let l = " " + seg.text.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        for (topic, cues) in topicCues {
            let hits = cues.filter { l.contains($0) }.count
            if hits > 0 { score[topic, default: 0] += w * Double(hits) }
        }
    }
    return topicList.filter { (score[$0] ?? 0) >= 1.5 }
        .sorted { (score[$0] ?? 0) != (score[$1] ?? 0) ? (score[$0] ?? 0) > (score[$1] ?? 0) : topicList.firstIndex(of: $0)! < topicList.firstIndex(of: $1)! }
        .prefix(3).map { $0 }
}

/// 分析一題：題型、每句歸段（連續同段合併）、每段關鍵片語、適合的題目主題
func analyze(_ n: Note) async -> Note {
    var n = n
    let sents = splitSentences(n.body)
    n.analyzedBody = n.body
    n.analysisVersion = kAnalysisVersion
    let ownHeadings = n.body.components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    guard !sents.isEmpty, !ownHeadings, case .available = SystemLanguageModel.default.availability else {
        n.kind = nil; n.segs = nil; n.topics = nil
        return n
    }
    let kind = await detectKind(n.title, sents.joined(separator: " "))
    let f = framework(kind)!
    let labels = sents.count == 1 ? [cueLabel(sents[0], kind: kind) ?? f.parts[0].code] : await labelSentences(sents, f, question: n.title)
    var segs = zip(sents, labels).map { Seg(part: $1, text: $0, phrases: []) }
    for i in segs.indices where segs[i].part != "OTHER" { segs[i].phrases = await keyPhrases(segs[i].text) }
    n.kind = kind
    n.segs = segs
    n.topics = kind == "behavioral" ? fitTopics(segs, title: n.title) : []
    n.keywords = segs.flatMap { $0.phrases }
    return n
}

/// 每段字數佔比（給比例條用）
func segShares(_ segs: [Seg]) -> [(String, Double)] {
    let counts = segs.map { Double(max(1, $0.text.split(whereSeparator: { $0.isWhitespace }).count)) }
    let total = counts.reduce(0, +)
    var merged: [(String, Double)] = []
    for (s, c) in zip(segs, counts) {
        if let i = merged.firstIndex(where: { $0.0 == s.part }) { merged[i].1 += c / total } else { merged.append((s.part, c / total)) }
    }
    return merged
}

/// 比例條：S / T / A / R 各佔多少
final class StructureBar: NSView {
    var shares: [(String, Double)] = [] { didSet { needsDisplay = true } }
    var kind: String?
    var showLabels = true
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: showLabels ? 16 : 4) }
    override func draw(_ dirtyRect: NSRect) {
        guard !shares.isEmpty else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        path.addClip()
        var x: CGFloat = 0
        for (code, share) in shares {
            let w = bounds.width * share
            let r = NSRect(x: x, y: 0, width: w, height: bounds.height)
            barColors[partIndex(code, kind: kind)].setFill()
            r.fill()
            if showLabels {
                let short = kind == "behavioral" ? code : partName(code, kind: kind)
                let t = NSAttributedString(string: "\(short) \(Int((share * 100).rounded()))%", attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.92)])
                if t.size().width + 6 < w {
                    t.draw(at: NSPoint(x: r.midX - t.size().width / 2, y: (bounds.height - t.size().height) / 2))
                }
            }
            x += w
        }
    }
}

// MARK: - Model

struct Note: Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var keywords: [String]
    var body: String
    var kind: String? = nil          // behavioral / tmay / whyus
    var segs: [Seg]? = nil
    var topics: [String]? = nil
    var analyzedBody: String? = nil

    var analysisVersion: Int? = nil

    var needsAnalysis: Bool { analyzedBody != body || (analysisVersion ?? 1) < kAnalysisVersion }

    /// 手動填的關鍵字 + 內文中 **粗體** 的字
    var allKeywords: [String] {
        var out: [String] = []
        let bold = (try? NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*"))?
            .matches(in: body, range: NSRange(body.startIndex..., in: body))
            .compactMap { Range($0.range(at: 1), in: body).map { String(body[$0]) } } ?? []
        for k in keywords + bold {
            let t = k.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && !out.contains(where: { $0.lowercased() == t.lowercased() }) { out.append(t) }
        }
        return out
    }
}

final class Store {
    static let shared = Store()
    var notes: [Note] = []
    let dir: URL
    let url: URL

    init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FloatPrompter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("notes.json")
        if let d = try? Data(contentsOf: url), let n = try? JSONDecoder().decode([Note].self, from: d) {
            notes = n
        } else {
            notes = Store.samples
            save()
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let d = try? enc.encode(notes) { try? d.write(to: url, options: .atomic) }
    }

    func upsert(_ n: Note) {
        if let i = notes.firstIndex(where: { $0.id == n.id }) { notes[i] = n } else { notes.insert(n, at: 0) }
        save()
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        save()
    }

    static let samples: [Note] = [
        Note(title: "使用說明（可刪除）", keywords: ["自動播放", "關鍵字"], body: """
## 怎麼用
- 在上方搜尋框輸入題目，↑↓ 選擇，Enter 開啟
- 空白鍵：**自動播放** / 暫停，↑↓ 調速度，Esc 回題目列表
- 滑鼠滾輪隨時可以手動捲動，播放會從你停的地方繼續

## 編輯
- 在提詞畫面**點兩下**就能編輯這一題
- 新增題目時直接整段貼上：第一行是題目，下面是答案
- 儲存時會自動挑出最重要的幾句，標成黃色

## 全域快捷鍵（在 Zoom / Meet 裡也有效）
- ⌥⌘P 顯示 / 隱藏
- ⌥⌘O 播放 / 暫停
- ⌥⌘↑ ⌥⌘↓ 調速度
- ⌥⌘B 回題目列表
"""),
        Note(title: "Tell me about yourself", keywords: ["background", "experience", "why this role"], body: """
## Present
I'm currently [your role / program], focusing on [area].

## Past
My **background** is in [field]. The **experience** that shaped me most was [project] — I [action] and it led to [result].

## Future
That's **why this role** excites me: it combines [skill A] with [skill B], and I want to grow in [direction].
"""),
        Note(title: "Why do you want to join us?", keywords: ["mission", "product", "team", "culture"], body: """
## Mission
What draws me first is your **mission** of [mission]. It connects to [personal story].

## Product
I've used your **product** — [specific feature] stood out because [reason].

## Team
From talking to people on the **team**, I learned [insight], which matches how I like to work.
"""),
        Note(title: "最有挑戰的一次經驗（STAR）", keywords: ["挑戰", "情境", "行動", "結果", "學到"], body: """
## Situation
當時的**情境**是：[背景，一兩句]

## Task
我負責的是 [任務]，最大的**挑戰**是 [困難點]

## Action
我採取的**行動**：
- 第一步 [做了什麼]
- 第二步 [做了什麼]

## Result
最後的**結果**是 [量化成果]
我從中**學到** [反思]
"""),
    ]
}

// MARK: - Matching

func isSubsequence(_ a: String, _ b: String) -> Bool {
    var it = b.makeIterator()
    outer: for c in a {
        while let d = it.next() { if d == c { continue outer } }
        return false
    }
    return true
}

/// 打字搜尋：每個詞都要命中（題目 > 關鍵字 > 內文 > 模糊）
func searchScore(_ n: Note, _ q: String) -> Int? {
    let terms = q.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    if terms.isEmpty { return 0 }
    let t = n.title.lowercased()
    let k = (n.allKeywords + (n.topics ?? [])).joined(separator: " ").lowercased()
    let b = n.body.lowercased()
    var s = 0
    for term in terms {
        if t.contains(term) { s += 10 }
        else if k.contains(term) { s += 6 }
        else if b.contains(term) { s += 2 }
        else if isSubsequence(term, t) { s += 1 }
        else { return nil }
    }
    return s
}

func ranges(of kw: String, in s: NSString) -> [NSRange] {
    var out: [NSRange] = []
    guard !kw.isEmpty else { return out }
    var start = 0
    while start < s.length {
        let r = s.range(of: kw, options: [.caseInsensitive], range: NSRange(location: start, length: s.length - start))
        if r.location == NSNotFound { break }
        out.append(r)
        start = r.location + max(1, r.length)
    }
    return out
}

// MARK: - Prefs

enum Pref {
    static let d = UserDefaults.standard
    static func dbl(_ k: String, _ def: Double) -> Double { d.object(forKey: k) as? Double ?? def }
    static var bgAlpha: Double { get { dbl("bgAlpha", 0.6) } set { d.set(newValue, forKey: "bgAlpha") } }
    static var winAlpha: Double { get { dbl("winAlpha", 1.0) } set { d.set(newValue, forKey: "winAlpha") } }
    static var fontSize: Double { get { dbl("fontSize", 26) } set { d.set(newValue, forKey: "fontSize") } }
    static var keywordMode: Bool { get { d.bool(forKey: "keywordMode") } set { d.set(newValue, forKey: "keywordMode") } }
    static var speed: Double { get { dbl("speed", 35) } set { d.set(newValue, forKey: "speed") } }
}

// MARK: - UI helpers

let kYellow = NSColor(srgbRed: 1.0, green: 0.84, blue: 0.04, alpha: 1)
let kHead = NSColor(srgbRed: 0.55, green: 0.75, blue: 1.0, alpha: 1)

func button(_ title: String, _ target: AnyObject?, _ sel: Selector?) -> NSButton {
    let b = NSButton(title: title, target: target, action: sel)
    b.bezelStyle = .rounded
    b.controlSize = .small
    b.font = .systemFont(ofSize: 12)
    return b
}

func label(_ s: String, size: CGFloat = 11, color: NSColor = .secondaryLabelColor) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.font = .systemFont(ofSize: size)
    l.textColor = color
    l.lineBreakMode = .byTruncatingHead
    l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return l
}

func slider(_ v: Double, _ min: Double, _ max: Double, _ target: AnyObject, _ sel: Selector, width: CGFloat = 64) -> NSSlider {
    let s = NSSlider(value: v, minValue: min, maxValue: max, target: target, action: sel)
    s.controlSize = .small
    s.widthAnchor.constraint(equalToConstant: width).isActive = true
    return s
}

func hstack(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .horizontal
    s.spacing = spacing
    s.alignment = .centerY
    return s
}

// MARK: - Window

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func sendEvent(_ e: NSEvent) {
        // 沒置頂時就像一般 App：點一下就把 App 叫到前面
        if e.type == .leftMouseDown, let a = App.shared, !a.pinned, !NSApp.isActive { NSApp.activate() }
        super.sendEvent(e)
    }
}

final class RootView: NSView {
    var onHover: ((Bool) -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

// MARK: - Library

/// 題目列表的一列：題目、結構比例條、題型與適合主題
final class NoteRow: NSTableCellView {
    let title = label("", size: 14, color: .white)
    let bar = StructureBar()
    let sub = label("", size: 11)

    init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        sub.lineBreakMode = .byTruncatingTail
        bar.showLabels = false
        let v = NSStackView(views: [title, bar, sub])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 5
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        for x in [title, bar, sub] { x.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            v.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            v.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ n: Note) {
        title.stringValue = n.title
        if let segs = n.segs, !n.needsAnalysis {
            bar.kind = n.kind
            bar.shares = segShares(segs)
            bar.isHidden = false
            let k = framework(n.kind)?.display ?? ""
            sub.stringValue = ([k] + (n.topics ?? [])).filter { !$0.isEmpty }.joined(separator: "   ·   ")
        } else {
            bar.isHidden = true
            sub.stringValue = App.shared?.analyzing.contains(n.id) == true ? "分析結構中…" : ""
        }
    }
}

final class LibraryView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let search = NSSearchField()
    let table = NSTableView()
    var filtered: [Note] = []
    var onOpen: ((Note) -> Void)?
    var onEdit: ((Note?) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        search.placeholderString = "輸入題目…  ↑↓ 選擇 · Enter 開啟"
        search.font = .systemFont(ofSize: 15)
        search.delegate = self

        let col = NSTableColumn(identifier: .init("c"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 64
        table.backgroundColor = .clear
        table.style = .plain
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)

        let sv = NSScrollView()
        sv.documentView = table
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false

        let bar = hstack([button("新增", self, #selector(newNote)),
                          button("編輯", self, #selector(editNote)),
                          button("刪除", self, #selector(deleteNote)),
                          NSView()])

        let v = NSStackView(views: [search, sv, bar])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 8
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        for x in [search, sv, bar] { x.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: leadingAnchor),
            v.trailingAnchor.constraint(equalTo: trailingAnchor),
            v.topAnchor.constraint(equalTo: topAnchor),
            v.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refilter()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refilter() {
        let q = search.stringValue
        let all = Store.shared.notes
        filtered = all.enumerated()
            .compactMap { i, n in searchScore(n, q).map { (i, n, $0) } }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
            .map { $0.1 }
        table.reloadData()
        if !filtered.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    func select(_ n: Note) {
        if !filtered.contains(where: { $0.id == n.id }) { search.stringValue = ""; refilter() }
        if let i = filtered.firstIndex(where: { $0.id == n.id }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
            table.scrollRowToVisible(i)
        }
    }

    /// 背景分析完成後，換掉列表裡的舊資料（保留選取）
    func replace(_ n: Note) {
        guard let i = filtered.firstIndex(where: { $0.id == n.id }) else { return }
        filtered[i] = n
        table.reloadData(forRowIndexes: [i], columnIndexes: [0])
    }

    var selected: Note? { table.selectedRow >= 0 && table.selectedRow < filtered.count ? filtered[table.selectedRow] : nil }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let v = (tableView.makeView(withIdentifier: id, owner: nil) as? NoteRow) ?? NoteRow()
        v.identifier = id
        v.show(filtered[row])
        return v
    }

    func controlTextDidChange(_ obj: Notification) { refilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): openSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): search.stringValue = ""; refilter(); return true
        default: return false
        }
    }

    func move(_ d: Int) {
        guard !filtered.isEmpty else { return }
        let r = min(max(0, table.selectedRow + d), filtered.count - 1)
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    @objc func openSelected() { if let n = selected { onOpen?(n) } }
    @objc func newNote() { onEdit?(nil) }

    @objc func editNote() { if let n = selected { onEdit?(n) } }
    @objc func deleteNote() {
        guard let n = selected else { return }
        let a = NSAlert()
        a.messageText = "刪除「\(n.title)」？"
        a.informativeText = "刪除後無法復原。"
        a.addButton(withTitle: "刪除")
        a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn {
            Store.shared.delete(n.id)
            refilter()
        }
    }
}

// MARK: - Prompter

final class PrompterView: NSView {
    let scroll = NSTextView.scrollableTextView()
    var text: NSTextView { scroll.documentView as! NSTextView }
    let titleLabel = label("", size: 13, color: .white)
    let structBar = StructureBar()
    let topicsLabel = label("", size: 11)
    lazy var playBtn = button("播放", self, #selector(togglePlay))
    lazy var modeSeg: NSSegmentedControl = {
        let c = NSSegmentedControl(labels: ["完整版", "關鍵字版"], trackingMode: .selectOne, target: self, action: #selector(modeChanged))
        c.controlSize = .small
        c.font = .systemFont(ofSize: 11)
        c.selectedSegment = Pref.keywordMode ? 1 : 0
        c.toolTip = "K 鍵切換"
        return c
    }()
    lazy var speedSlider = slider(Pref.speed, 5, 200, self, #selector(speedChanged), width: 90)
    let speedLabel = label("", size: 11)
    var topBar: NSView!

    var note: Note?
    var keywords: [String] = []
    var playing = false
    var pos: CGFloat = 0
    var lastSet: CGFloat = 0
    var targetPos: CGFloat?
    var timer: Timer?
    var onBack: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let t = text
        t.isEditable = false
        t.isSelectable = false
        t.drawsBackground = false
        t.textContainerInset = NSSize(width: 14, height: 10)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let dbl = NSClickGestureRecognizer(target: self, action: #selector(editCurrent))
        dbl.numberOfClicksRequired = 2
        scroll.addGestureRecognizer(dbl)
        scroll.toolTip = "點兩下編輯"

        topicsLabel.lineBreakMode = .byTruncatingTail
        topicsLabel.textColor = NSColor(srgbRed: 0.62, green: 0.66, blue: 1.0, alpha: 1)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        let top = hstack([button("題目列表", self, #selector(back)), titleLabel, NSView(), modeSeg, playBtn])
        let speedRow = hstack([label("速度", size: 11), speedSlider, speedLabel, NSView()])
        let header = NSStackView(views: [top, speedRow, structBar, topicsLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 5
        for x in [top, speedRow, structBar, topicsLabel] { x.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true }
        topBar = header

        let v = NSStackView(views: [header, scroll])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 6
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        for x in [header, scroll] { x.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: leadingAnchor),
            v.trailingAnchor.constraint(equalTo: trailingAnchor),
            v.topAnchor.constraint(equalTo: topAnchor),
            v.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateSpeedLabel()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    @objc func editCurrent() {
        guard let note else { return }
        setPlaying(false)
        App.shared.edit(note)
    }

    /// 編輯完重新載入，保留目前捲動位置
    func reload(_ n: Note) {
        note = n
        keywords = n.allKeywords
        titleLabel.stringValue = n.title
        render()
    }

    func load(_ n: Note) {
        note = n
        keywords = n.allKeywords
        titleLabel.stringValue = n.title
        render()
        pos = 0; lastSet = 0; targetPos = nil
        scroll.contentView.setBoundsOrigin(.zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        setPlaying(false)
        startTimer()
    }

    func startTimer() {
        guard timer == nil else { return }
        let tm = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }

    func stopTimer() { timer?.invalidate(); timer = nil; setPlaying(false) }

    // 把 markdown-ish 內文轉成顯示用字串，回傳小標題範圍
    func process(_ body: String) -> (String, [NSRange]) {
        var out = ""
        var heads: [NSRange] = []
        for raw in body.replacingOccurrences(of: "**", with: "").components(separatedBy: "\n") {
            var l = raw
            var isHead = false
            if l.hasPrefix("#") {
                l = String(l.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                isHead = true
            } else if l.hasPrefix("- ") || l.hasPrefix("* ") {
                l = "•  " + l.dropFirst(2)
            }
            let start = (out as NSString).length
            out += l + "\n"
            if isHead { heads.append(NSRange(location: start, length: (l as NSString).length)) }
        }
        return (out, heads)
    }

    func render() {
        guard let note else { return }
        if let segs = note.segs, !note.needsAnalysis, !segs.isEmpty {
            renderStructured(note, segs)
            return
        }
        structBar.isHidden = true
        modeSeg.isHidden = true
        topicsLabel.stringValue = App.shared?.analyzing.contains(note.id) == true ? "分析結構中…" : ""
        topicsLabel.isHidden = topicsLabel.stringValue.isEmpty
        let fs = CGFloat(Pref.fontSize)
        let (plain, heads) = process(note.body)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = fs * 0.3
        para.paragraphSpacing = fs * 0.25
        let s = NSMutableAttributedString(string: plain + String(repeating: "\n", count: 12), attributes: [
            .font: NSFont.systemFont(ofSize: fs, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
            .paragraphStyle: para,
        ])
        for r in heads {
            s.addAttributes([.font: NSFont.systemFont(ofSize: fs * 0.7, weight: .bold), .foregroundColor: kHead], range: r)
        }
        let ns = plain as NSString
        for kw in keywords {
            for r in ranges(of: kw, in: ns) {
                s.addAttributes([.foregroundColor: kYellow,
                                 .font: NSFont.systemFont(ofSize: fs, weight: .semibold)], range: r)
            }
        }
        text.textStorage?.setAttributedString(s)
    }

    /// 依結構分段顯示：每段一個彩色小標，內文用該段顏色，關鍵片語粗體加底線
    func renderStructured(_ note: Note, _ segs: [Seg]) {
        let fs = CGFloat(Pref.fontSize)
        let s = Pref.keywordMode ? keywordView(note, segs, fs) : fullView(note, segs, fs)
        s.append(NSAttributedString(string: String(repeating: "\n", count: 12), attributes: [.font: NSFont.systemFont(ofSize: fs)]))
        text.textStorage?.setAttributedString(s)
        structBar.kind = note.kind
        structBar.shares = segShares(segs)
        structBar.isHidden = false
        modeSeg.isHidden = false
        let k = framework(note.kind)?.display ?? ""
        topicsLabel.stringValue = ([k] + (note.topics ?? [])).filter { !$0.isEmpty }.joined(separator: "   ·   ")
        topicsLabel.isHidden = false
    }

    /// 完整版：連續同段的句子合成一段，段首彩色小標，關鍵片語粗體加底線
    func fullView(_ note: Note, _ segs: [Seg], _ fs: CGFloat) -> NSMutableAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = fs * 0.3
        para.paragraphSpacing = fs * 0.55
        let headPara = NSMutableParagraphStyle()
        headPara.paragraphSpacing = fs * 0.12
        let s = NSMutableAttributedString()
        var groups: [(String, [Seg])] = []
        for seg in segs {
            if let last = groups.last, last.0 == seg.part { groups[groups.count - 1].1.append(seg) } else { groups.append((seg.part, [seg])) }
        }
        for (part, items) in groups {
            let idx = partIndex(part, kind: note.kind)
            let name = partName(part, kind: note.kind)
            let head = note.kind == "behavioral" && part != "OTHER" ? "\(part)  \(name)" : name
            s.append(NSAttributedString(string: head.uppercased() + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: max(11, fs * 0.5), weight: .bold),
                .foregroundColor: textColors[idx], .kern: 1.2, .paragraphStyle: headPara]))
            let body = items.map { $0.text }.joined(separator: " ")
            let start = s.length
            s.append(NSAttributedString(string: body + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: fs, weight: .regular),
                .foregroundColor: textColors[idx].blended(withFraction: 0.45, of: .white) ?? .white,
                .paragraphStyle: para]))
            let ns = body as NSString
            for p in items.flatMap({ $0.phrases }) {
                for r in ranges(of: p, in: ns) {
                    s.addAttributes([.font: NSFont.systemFont(ofSize: fs, weight: .bold),
                                     .foregroundColor: textColors[idx],
                                     .underlineStyle: NSUnderlineStyle.thick.rawValue,
                                     .underlineColor: textColors[idx]],
                                    range: NSRange(location: start + r.location, length: r.length))
                }
            }
        }
        return s
    }

    /// 關鍵字版：一句一列，左邊段名，右邊關鍵片語條列；Other 只露開頭幾個字
    func keywordView(_ note: Note, _ segs: [Seg], _ fs: CGFloat) -> NSMutableAttributedString {
        let col = fs * 4.6
        let s = NSMutableAttributedString()
        for seg in segs {
            let idx = partIndex(seg.part, kind: note.kind)
            let name = note.kind == "behavioral" && seg.part != "OTHER" ? seg.part : partName(seg.part, kind: note.kind)
            let para = NSMutableParagraphStyle()
            para.tabStops = [NSTextTab(textAlignment: .left, location: col)]
            para.headIndent = col
            para.lineSpacing = fs * 0.25
            para.paragraphSpacing = fs * 0.2
            para.paragraphSpacingBefore = fs * 0.35
            s.append(NSAttributedString(string: name + "\t", attributes: [
                .font: NSFont.systemFont(ofSize: max(11, fs * 0.55), weight: .bold),
                .foregroundColor: textColors[idx], .paragraphStyle: para]))
            let items: [String]
            if seg.phrases.isEmpty {
                let w = seg.text.split(separator: " ")
                items = [w.prefix(4).joined(separator: " ") + (w.count > 4 ? "…" : "")]
            } else { items = seg.phrases }
            for (i, p) in items.enumerated() {
                let pp = para.mutableCopy() as! NSMutableParagraphStyle
                if i > 0 { pp.paragraphSpacingBefore = fs * 0.1 }
                s.append(NSAttributedString(string: (i > 0 ? "\t" : "") + "•  " + p + "\n", attributes: [
                    .font: seg.phrases.isEmpty ? NSFontManager.shared.convert(.systemFont(ofSize: fs * 0.85), toHaveTrait: .italicFontMask)
                                               : NSFont.systemFont(ofSize: fs, weight: .semibold),
                    .foregroundColor: seg.phrases.isEmpty ? textColors[idx].withAlphaComponent(0.7)
                                                          : (textColors[idx].blended(withFraction: 0.25, of: .white) ?? .white),
                    .paragraphStyle: pp]))
            }
        }
        return s
    }

    @objc func modeChanged() {
        Pref.keywordMode = modeSeg.selectedSegment == 1
        render()
    }

    func tick() {
        let clip = scroll.contentView
        let cur = clip.bounds.origin.y
        if abs(cur - lastSet) > 0.75 { pos = cur; targetPos = nil }   // 使用者手動滾了
        let maxY = max(0, text.frame.height - clip.bounds.height)
        if let t = targetPos {
            pos += (t - pos) * 0.18
            if abs(t - pos) < 0.8 { pos = t; targetPos = nil }
        } else if playing {
            pos += CGFloat(Pref.speed) / 60.0
            if pos >= maxY { pos = maxY; setPlaying(false) }
        } else {
            lastSet = cur
            return
        }
        pos = min(max(0, pos), maxY)
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: pos))
        scroll.reflectScrolledClipView(clip)
        lastSet = clip.bounds.origin.y
    }

    func setPlaying(_ p: Bool) {
        playing = p
        playBtn.title = p ? "暫停" : "播放"
    }

    @objc func togglePlay() { setPlaying(!playing) }
    @objc func back() { onBack?() }
    @objc func speedChanged() { Pref.speed = speedSlider.doubleValue; updateSpeedLabel() }

    func nudgeSpeed(_ d: Double) {
        Pref.speed = min(200, max(5, Pref.speed + d))
        speedSlider.doubleValue = Pref.speed
        updateSpeedLabel()
    }

    func updateSpeedLabel() { speedLabel.stringValue = "\(Int(Pref.speed))" }

    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.contains(.command) {
            switch e.charactersIgnoringModifiers {
            case "=", "+": App.shared.changeFont(2); return
            case "-": App.shared.changeFont(-2); return
            default: break
            }
        }
        switch Int(e.keyCode) {
        case kVK_Space: togglePlay()
        case kVK_UpArrow: nudgeSpeed(5)
        case kVK_DownArrow: nudgeSpeed(-5)
        case kVK_Escape: back()
        case kVK_ANSI_R: targetPos = 0
        case kVK_ANSI_K: modeSeg.selectedSegment = Pref.keywordMode ? 0 : 1; modeChanged()
        default: super.keyDown(with: e)
        }
    }
}

// MARK: - Editor

final class EditorController: NSWindowController, NSWindowDelegate {
    var note: Note
    let onSave: (Note) -> Void
    let bodyScroll = NSTextView.scrollableTextView()
    var bodyView: NSTextView { bodyScroll.documentView as! NSTextView }
    lazy var saveBtn = NSButton(title: "儲存  ⌘S", target: self, action: #selector(saveIt))
    lazy var reBtn = button("重新分析結構", self, #selector(reanalyze))
    let status = label("", size: 11)
    var force = false

    init(note: Note, onSave: @escaping (Note) -> Void) {
        self.note = note
        self.onSave = onSave
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = note.title.isEmpty ? "新增題目" : "編輯題目"
        w.level = .floating
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self

        let t = bodyView
        t.font = .systemFont(ofSize: 15)
        t.isRichText = false
        t.allowsUndo = true
        t.isAutomaticQuoteSubstitutionEnabled = false
        t.isAutomaticDashSubstitutionEnabled = false
        t.textContainerInset = NSSize(width: 6, height: 6)
        bodyScroll.borderType = .bezelBorder
        t.string = note.title.isEmpty ? "" : note.title + "\n" + note.body

        let hint = label("第一行是題目，下面是答案，可以直接整段貼上。儲存時會自動分段（STAR / Past-Present-Future / Why us）並標出關鍵片語。", size: 11)
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelIt))
        cancel.keyEquivalent = "\u{1b}"
        saveBtn.keyEquivalent = "s"
        saveBtn.keyEquivalentModifierMask = .command
        saveBtn.bezelColor = .controlAccentColor
        reBtn.toolTip = "內容沒改也重新分析一次"

        let v = NSStackView(views: [label("題目＋答案", size: 12, color: .labelColor), bodyScroll, hint,
                                    hstack([reBtn, status, NSView(), cancel, saveBtn])])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 6
        v.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for x in v.arrangedSubviews { x.widthAnchor.constraint(equalTo: v.widthAnchor, constant: -32).isActive = true }
        bodyScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        w.contentView = v
        w.center()
        w.makeFirstResponder(t)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func reanalyze() { force = true; saveIt() }

    @objc func saveIt() {
        guard let (t, b) = parsePasted(bodyView.string).first, !t.isEmpty else {
            NSSound.beep(); window?.makeFirstResponder(bodyView); return
        }
        note.title = t
        note.body = b
        guard note.needsAnalysis || force else { onSave(note); close(); return }
        saveBtn.isEnabled = false
        reBtn.isEnabled = false
        status.stringValue = "分析結構中…（約 5–15 秒）"
        let n = note
        Task { @MainActor in
            let done = await analyze(n)
            self.onSave(done)
            self.close()
        }
    }

    @objc func cancelIt() { close() }
}

// MARK: - App

func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    var hk = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                      nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
    let id = hk.id
    DispatchQueue.main.async { App.shared.hotKey(id) }
    return noErr
}

final class App: NSObject, NSApplicationDelegate {
    static var shared: App!
    var panel: FloatingPanel!
    let root = RootView()
    let library = LibraryView()
    let prompter = PrompterView()
    var statusItem: NSStatusItem!
    var editor: EditorController?
    var sharedBar: NSView!
    lazy var bgSlider = slider(Pref.bgAlpha, 0.05, 1.0, self, #selector(bgChanged))
    lazy var winSlider = slider(Pref.winAlpha, 0.25, 1.0, self, #selector(winChanged))
    lazy var pinBtn = button("置頂", self, #selector(togglePin))
    var pinMenuItem: NSMenuItem?
    /// 置頂 = 永遠浮在最上層 + 跨桌面/全螢幕 + 螢幕分享和截圖看不到；不置頂 = 一般視窗
    var pinned = false
    var analyzing = Set<UUID>()
    var hotKeys: [EventHotKeyRef?] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        App.shared = self
        buildMenu()
        buildPanel()
        buildStatusItem()
        registerHotKeys()

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(library.search)
        NSApp.activate()
        analyzePending()
    }

    /// 把還沒分析（或內容改過）的題目逐一在背景分析
    func analyzePending(first: UUID? = nil) {
        var queue = Store.shared.notes.filter { $0.needsAnalysis && !analyzing.contains($0.id) }.map { $0.id }
        if let f = first, let i = queue.firstIndex(of: f) { queue.remove(at: i); queue.insert(f, at: 0) }
        guard !queue.isEmpty else { return }
        analyzing.formUnion(queue)
        library.table.reloadData()
        Task { @MainActor in
            for id in queue {
                guard let n = Store.shared.notes.first(where: { $0.id == id }) else { analyzing.remove(id); continue }
                self.prompter.render()
                let done = await analyze(n)
                self.analyzing.remove(id)
                guard let cur = Store.shared.notes.first(where: { $0.id == id }), cur.body == n.body else { continue }
                Store.shared.upsert(done)
                self.library.replace(done)
                if !self.prompter.isHidden, self.prompter.note?.id == id { self.prompter.reload(done) }
            }
        }
    }

    func buildPanel() {
        let p = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                              styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { p.standardWindowButton($0)?.isHidden = true }
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.appearance = NSAppearance(named: .darkAqua)
        p.minSize = NSSize(width: 440, height: 260)
        p.alphaValue = CGFloat(Pref.winAlpha)
        p.center()
        p.setFrameAutosaveName("FloatPrompterPanel")

        root.wantsLayer = true
        root.layer?.cornerRadius = 14
        root.layer?.masksToBounds = true
        applyBg()
        p.contentView = root

        // 共用底部列
        pinBtn.setButtonType(.pushOnPushOff)
        pinBtn.toolTip = "置頂：永遠浮在最上層，切換 App 也在；螢幕分享和截圖都看不到（⌥⌘T）"
        let closeBtn = button("關閉", self, #selector(closePanel))
        closeBtn.toolTip = "關閉視窗（⌘W）。從 Dock 或選單列圖示可以再打開；⌘Q 結束"
        let bar = hstack([pinBtn, NSView(),
                          label("背景", size: 11), bgSlider,
                          label("整體", size: 11), winSlider,
                          button("A−", self, #selector(fontDown)), button("A+", self, #selector(fontUp)),
                          closeBtn], spacing: 5)
        sharedBar = bar

        prompter.isHidden = true
        let modes = NSView()
        for m in [library, prompter] as [NSView] {
            m.translatesAutoresizingMaskIntoConstraints = false
            modes.addSubview(m)
            NSLayoutConstraint.activate([
                m.leadingAnchor.constraint(equalTo: modes.leadingAnchor),
                m.trailingAnchor.constraint(equalTo: modes.trailingAnchor),
                m.topAnchor.constraint(equalTo: modes.topAnchor),
                m.bottomAnchor.constraint(equalTo: modes.bottomAnchor),
            ])
        }
        let v = NSStackView(views: [modes, bar])
        v.orientation = .vertical
        v.spacing = 8
        v.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(v)
        for x in [modes, bar] { x.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            v.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            v.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            v.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])

        library.onOpen = { [weak self] n in self?.open(n) }
        library.onEdit = { [weak self] n in self?.edit(n) }
        prompter.onBack = { [weak self] in self?.back() }
        root.onHover = { [weak self] inside in self?.hover(inside) }
        panel = p
        applyPin()
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "結束提詞器", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "編輯")
        edit.addItem(withTitle: "還原", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪下", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷貝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "貼上", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全選", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let winItem = NSMenuItem()
        main.addItem(winItem)
        let win = NSMenu(title: "視窗")
        let pin = win.addItem(withTitle: "置頂", action: #selector(togglePin), keyEquivalent: "t")
        pin.keyEquivalentModifierMask = [.command, .option]
        pin.target = self
        pinMenuItem = pin
        win.addItem(withTitle: "關閉視窗", action: #selector(closePanel), keyEquivalent: "w").target = self
        winItem.submenu = win
        NSApp.mainMenu = main
    }

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "提詞器")
        let m = NSMenu()
        m.addItem(withTitle: "顯示 / 隱藏提詞器  ⌥⌘P", action: #selector(togglePanel), keyEquivalent: "").target = self
        m.addItem(withTitle: "置頂 / 取消置頂  ⌥⌘T", action: #selector(togglePin), keyEquivalent: "").target = self
        m.addItem(withTitle: "新增題目", action: #selector(newFromMenu), keyEquivalent: "").target = self
        m.addItem(withTitle: "在 Finder 顯示題目資料", action: #selector(revealData), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "結束", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = m
    }

    func registerHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, nil)
        let mods = UInt32(cmdKey | optionKey)
        let keys: [(UInt32, Int)] = [(1, kVK_ANSI_P), (2, kVK_ANSI_O), (3, kVK_UpArrow), (4, kVK_DownArrow), (5, kVK_ANSI_B), (6, kVK_ANSI_T)]
        for (id, code) in keys {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(code), mods, EventHotKeyID(signature: OSType(0x464C5054), id: id),
                                GetApplicationEventTarget(), 0, &ref)
            hotKeys.append(ref)
        }
    }

    func hotKey(_ id: UInt32) {
        switch id {
        case 1: togglePanel()
        case 2: if !prompter.isHidden { prompter.togglePlay() }
        case 3: prompter.nudgeSpeed(5)
        case 4: prompter.nudgeSpeed(-5)
        case 5:
            panel.orderFrontRegardless()
            if !prompter.isHidden { back() }
            panel.makeKey()
            panel.makeFirstResponder(library.search)
        case 6: togglePin()
        default: break
        }
    }

    // MARK: 模式切換

    func open(_ n: Note) {
        if n.needsAnalysis { analyzePending(first: n.id) }
        prompter.load(n)
        library.isHidden = true
        prompter.isHidden = false
        panel.makeFirstResponder(prompter)
        hover(isMouseInside())
    }

    func back() {
        prompter.stopTimer()
        prompter.isHidden = true
        library.isHidden = false
        library.refilter()
        panel.makeFirstResponder(library.search)
        hover(true)
    }

    func edit(_ n: Note?) {
        editor?.close()
        let e = EditorController(note: n ?? Note(title: "", keywords: [], body: "")) { [weak self] saved in
            Store.shared.upsert(saved)
            self?.library.refilter()
            self?.library.select(saved)
            if let p = self?.prompter, !p.isHidden, p.note?.id == saved.id { p.reload(saved) }
        }
        editor = e
        e.window?.level = pinned ? .floating : .normal
        e.window?.sharingType = pinned ? .none : .readOnly
        e.showWindow(nil)
        NSApp.activate()
        e.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: 控制

    func isMouseInside() -> Bool { panel.frame.contains(NSEvent.mouseLocation) }

    func hover(_ inside: Bool) {
        let a: CGFloat = (inside || prompter.isHidden) ? 1.0 : 0.15
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            sharedBar.animator().alphaValue = a
            prompter.topBar.animator().alphaValue = inside ? 1.0 : 0.35
        }
    }

    func applyBg() { root.layer?.backgroundColor = NSColor(white: 0.06, alpha: CGFloat(Pref.bgAlpha)).cgColor }

    func changeFont(_ d: Double) {
        Pref.fontSize = min(72, max(14, Pref.fontSize + d))
        prompter.render()
    }

    @objc func bgChanged() { Pref.bgAlpha = bgSlider.doubleValue; applyBg() }
    @objc func winChanged() { Pref.winAlpha = winSlider.doubleValue; panel.alphaValue = CGFloat(Pref.winAlpha) }
    @objc func fontUp() { changeFont(2) }
    @objc func fontDown() { changeFont(-2) }
    func applyPin() {
        panel.level = pinned ? .floating : .normal
        panel.collectionBehavior = pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.managed]
        panel.sharingType = pinned ? .none : .readOnly
        editor?.window?.level = pinned ? .floating : .normal
        editor?.window?.sharingType = pinned ? .none : .readOnly
        pinBtn.state = pinned ? .on : .off
        pinBtn.title = pinned ? "已置頂" : "置頂"
        pinBtn.contentTintColor = pinned ? .systemOrange : nil
        pinMenuItem?.state = pinned ? .on : .off
        root.layer?.borderWidth = pinned ? 1.5 : 0
        root.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.7).cgColor
    }

    @objc func togglePin() {
        pinned.toggle()
        applyPin()
        showPanel()
    }

    func showPanel() {
        if pinned { panel.orderFrontRegardless(); panel.makeKey() }
        else { NSApp.activate(); panel.makeKeyAndOrderFront(nil) }
    }

    @objc func closePanel() {
        if let w = NSApp.keyWindow, w !== panel { w.performClose(nil); return }   // 編輯視窗開著就先關它
        panel.orderOut(nil)
    }

    @objc func togglePanel() {
        if panel.isVisible { panel.orderOut(nil) } else { showPanel() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel(); return true
    }
    @objc func newFromMenu() { showPanel(); edit(nil) }
    @objc func revealData() { NSWorkspace.shared.activateFileViewerSelecting([Store.shared.url]) }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
