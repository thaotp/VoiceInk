import Foundation
import os
import SwiftUI
import Mecab_Swift
import IPADic
import Dictionary

// MARK: - Bunsetsu (文節)

/// A bunsetsu unit: a content word (head) + attached function words (particles, auxiliaries).
struct Bunsetsu {
    let text: String                     // Full surface text of the bunsetsu
    let headSurface: String              // Surface of the head (content) word
    let headPOS: PartOfSpeech            // POS of the head word
    let headDictionaryForm: String       // Dictionary form of the head word
    let particles: [String]              // Trailing particle surfaces
    let auxiliaries: [String]            // Trailing auxiliary surfaces (.unknown tokens)
    
    /// The last particle in this bunsetsu, if any.
    var lastParticle: String? { particles.last }
    
    /// Whether this bunsetsu ends with a specific particle surface.
    func endsWith(particle: String) -> Bool {
        particles.contains(particle)
    }
    
    /// Whether the bunsetsu text ends with any of the given suffixes.
    func textEndsWith(anyOf suffixes: [String]) -> Bool {
        suffixes.contains { text.hasSuffix($0) }
    }
}

// MARK: - Sentence Component (for coloring)

enum SentenceComponent {
    case subject      // 主語 — noun before は/が
    case object       // 目的語 — noun before を/に
    case particle     // 助詞
    case predicate    // 述語 — verb/adjective
    case complement   // 補語 — other
    case filler       // フィラー
    case plain        // unstyled
}

// MARK: - Clause Chunk (for rendering)

struct ClauseChunk {
    let text: String
    let component: SentenceComponent
}

// MARK: - MeCab Formatter Service

/// Rule-based clause segmentation for Japanese speech transcripts.
///
/// **Pipeline**:
/// 1. MeCab tokenization
/// 2. Bunsetsu grouping (content word + function words)
/// 3. Clause boundary detection (rules S1–S7)
/// 4. Component role assignment (subject/object/predicate)
/// 5. AttributedString output with line breaks between clauses
///
/// Optimized for spoken Japanese: business speeches, panel discussions,
/// startup pitches, webinars, interviews.
@MainActor
final class MeCabFormatterService {
    
    static let shared = MeCabFormatterService()
    
    // MARK: - Public Properties
    
    private(set) var isAvailable: Bool = false
    
    // MARK: - Private Properties
    
    private let logger = Logger(subsystem: "com.voiceink", category: "MeCabFormatter")
    
    private var attributedCache: [String: AttributedString] = [:]
    private let cacheLimit = 500
    
    private let processingQueue = DispatchQueue(label: "com.voiceink.mecab", qos: .userInitiated)
    
    private var tokenizer: Tokenizer?
    
    // MARK: - Colors
    
    private static let subjectColor = Color(red: 0.35, green: 0.55, blue: 0.90)   // Blue
    private static let objectColor  = Color(red: 0.90, green: 0.55, blue: 0.25)   // Orange
    private static let particleColor = Color.secondary                              // Gray
    private static let predicateColor = Color(red: 0.30, green: 0.75, blue: 0.50) // Green
    
    // MARK: - Rule Word Lists
    
    // --- S1: Conjunctive particles (接続助詞) ---
    private static let conjunctiveParticles: Set<String> = [
        "ので", "から", "けれども", "けれど", "けど",
        "が", "し", "と", "ば", "たら", "ても", "ところで",
        "のに", "ながら", "つつ",
    ]
    
    // --- S2: Contrast markers (hard break after) ---
    private static let contrastSuffixes = ["けれども", "けれど", "けど"]
    
    // --- S3: Additive spoken markers ---
    private static let additiveMarkers: Set<String> = ["し", "あとは", "あと"]
    
    // --- S4: Discourse markers / conjunctions (break before) ---
    private static let discourseMarkers: Set<String> = [
        "でも", "そして", "だから", "ただ", "それで",
        "しかし", "しかも", "それから", "つまり", "または",
        "もしくは", "すなわち", "ところが", "ところで",
        "なので", "だけど", "だけども",
    ]
    
    // --- S5: Cognitive verbs (と/って + verb) ---
    private static let cognitiveVerbs: Set<String> = [
        "思う", "言う", "考える", "感じる", "思える",
        "思います", "言います", "考えます",
    ]
    
    // --- S7: Topic shift / filler markers (soft break before) ---
    private static let topicShiftMarkers: Set<String> = [
        "やっぱり", "やっぱ", "やはり",
        "まあ", "まー",
        "あの", "あのー", "あのう",
        "えー", "えーと", "えーっと", "ええと",
        "なんか", "なんていうか",
        "ほら", "ほらー",
        "こう", "こうー",
        "さあ", "さー",
    ]
    
    // --- Filler words (for visual fading) ---
    private static let fillerWords: Set<String> = [
        "えー", "えーと", "えーっと", "ええと", "ええっと",
        "あー", "あのー", "あの", "あのう",
        "うーん", "うん", "うーんと",
        "まあ", "まー",
        "その", "そのー",
        "なんか", "なんていうか",
        "ちょっと",
        "やっぱり", "やっぱ",
        "ほら", "ほらー",
        "ねえ", "ねー",
        "さあ", "さー",
        "こう", "こうー",
        "え", "あ",
    ]
    
    // --- Subject/Object particle markers ---
    private static let subjectMarkers: Set<String> = ["は", "が"]
    private static let objectMarkers: Set<String>  = ["を", "に"]
    
    // --- Sentence-final particles (absorbed into predicate) ---
    private static let sentenceFinalParticles: Set<String> = [
        "ね", "よ", "か", "な", "わ", "さ", "ぞ", "ぜ", "の",
    ]
    
    // MARK: - Initialization
    
    private init() {
        initializeTokenizer()
    }
    
    // MARK: - Public Methods
    
    /// Format Japanese text with clause segmentation, component coloring, and line breaks.
    func format(_ text: String) async -> AttributedString {
        guard isAvailable else { return AttributedString(text) }
        
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return AttributedString(text) }
        
        if let cached = attributedCache[trimmed] {
            return cached
        }
        
        let clauses = await withCheckedContinuation { continuation in
            processingQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: [[ClauseChunk(text: text, component: .plain)]])
                    return
                }
                let result = self.processText(trimmed)
                continuation.resume(returning: result)
            }
        }
        
        let attributed = Self.buildAttributedString(from: clauses)
        
        if attributedCache.count >= cacheLimit {
            attributedCache.removeAll()
        }
        attributedCache[trimmed] = attributed
        
        return attributed
    }
    
    /// Plain text with clause line breaks (for overlay view).
    func formatPlain(_ text: String) async -> String {
        guard isAvailable else { return text }
        
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        
        let clauses = await withCheckedContinuation { continuation in
            processingQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: [[ClauseChunk(text: text, component: .plain)]])
                    return
                }
                let result = self.processText(trimmed)
                continuation.resume(returning: result)
            }
        }
        
        return clauses.map { clause in
            clause.map { $0.text }.joined(separator: " ")
        }.joined(separator: "\n")
    }
    
    static func isJapanese(_ languageCode: String) -> Bool {
        let code = languageCode.lowercased()
        return code == "ja" || code.hasPrefix("ja-")
    }
    
    func clearCache() {
        attributedCache.removeAll()
    }
    
    // MARK: - Private: Initialization
    
    private func initializeTokenizer() {
        do {
            let ipaDic = IPADic()
            tokenizer = try Tokenizer(dictionary: ipaDic)
            isAvailable = true
            logger.info("MeCab formatter initialized successfully with IPADic")
        } catch {
            logger.warning("Failed to initialize MeCab tokenizer: \(error.localizedDescription)")
            isAvailable = false
        }
    }
    
    // MARK: - Private: Main Pipeline
    
    /// Full processing pipeline: tokenize → bunsetsu → clause boundaries → role assignment.
    /// Returns array of clauses, each clause being an array of ClauseChunks.
    private func processText(_ text: String) -> [[ClauseChunk]] {
        guard let tokenizer = tokenizer else {
            return [[ClauseChunk(text: text, component: .plain)]]
        }
        
        // Step 1: MeCab tokenization
        let annotations = tokenizer.tokenize(text: text)
        guard !annotations.isEmpty else {
            return [[ClauseChunk(text: text, component: .plain)]]
        }
        
        // Step 2: Bunsetsu grouping
        let bunsetsuList = groupIntoBunsetsu(annotations)
        guard !bunsetsuList.isEmpty else {
            return [[ClauseChunk(text: text, component: .plain)]]
        }
        
        // Step 3: Clause boundary detection (Rules S1–S7)
        let clauses = detectClauseBoundaries(bunsetsuList)
        
        // Step 4: Assign component roles within each clause
        return clauses.map { assignRoles(to: $0) }
    }
    
    // MARK: - Step 2: Bunsetsu Grouping
    
    /// Group MeCab annotations into bunsetsu units.
    ///
    /// A bunsetsu = content word (head) + following function words (particles, auxiliaries).
    /// A new bunsetsu starts when a content word appears (noun, verb, adj, adverb, prefix)
    /// or when a discourse marker / filler is detected.
    private func groupIntoBunsetsu(_ annotations: [Annotation]) -> [Bunsetsu] {
        var result: [Bunsetsu] = []
        
        // Collect raw tokens
        var tokens: [(surface: String, pos: PartOfSpeech, dictForm: String)] = []
        for ann in annotations {
            if !ann.base.isEmpty {
                tokens.append((ann.base, ann.partOfSpeech, ann.dictionaryForm))
            }
        }
        
        guard !tokens.isEmpty else { return [] }
        
        var i = 0
        while i < tokens.count {
            let (surface, pos, dictForm) = tokens[i]
            
            // Detect discourse markers (mapped to .unknown but known by surface)
            if Self.discourseMarkers.contains(surface) || Self.topicShiftMarkers.contains(surface) {
                result.append(Bunsetsu(
                    text: surface,
                    headSurface: surface,
                    headPOS: pos,
                    headDictionaryForm: dictForm,
                    particles: [],
                    auxiliaries: []
                ))
                i += 1
                continue
            }
            
            // Content word → start a new bunsetsu
            if Self.isContentWord(pos) {
                let headSurface = surface
                let headPOS = pos
                let headDictForm = dictForm
                var fullText = surface
                var particles: [String] = []
                var auxiliaries: [String] = []
                i += 1
                
                // Absorb following auxiliaries (.unknown = 助動詞 like です, ます, た, ない)
                while i < tokens.count && tokens[i].pos == .unknown {
                    let aux = tokens[i].surface
                    fullText += aux
                    auxiliaries.append(aux)
                    i += 1
                }
                
                // Absorb following particles
                while i < tokens.count && tokens[i].pos == .particle {
                    let part = tokens[i].surface
                    fullText += part
                    particles.append(part)
                    i += 1
                    
                    // If this particle is a conjunctive one, stop absorbing more
                    if Self.conjunctiveParticles.contains(part) {
                        break
                    }
                }
                
                result.append(Bunsetsu(
                    text: fullText,
                    headSurface: headSurface,
                    headPOS: headPOS,
                    headDictionaryForm: headDictForm,
                    particles: particles,
                    auxiliaries: auxiliaries
                ))
                continue
            }
            
            // Standalone particle or symbol or unknown (shouldn't happen often after grouping)
            result.append(Bunsetsu(
                text: surface,
                headSurface: surface,
                headPOS: pos,
                headDictionaryForm: dictForm,
                particles: pos == .particle ? [surface] : [],
                auxiliaries: pos == .unknown ? [surface] : []
            ))
            i += 1
        }
        
        return result
    }
    
    // MARK: - Step 3: Clause Boundary Detection
    
    /// Split bunsetsu into clauses at comma (、) boundaries.
    /// Each comma triggers a new line.
    private func detectClauseBoundaries(_ bunsetsuList: [Bunsetsu]) -> [[Bunsetsu]] {
        guard !bunsetsuList.isEmpty else { return [] }
        
        var clauses: [[Bunsetsu]] = []
        var currentClause: [Bunsetsu] = []
        
        for b in bunsetsuList {
            // Comma (、) → end current clause, start new one
            if b.headPOS == .symbol && b.text.contains("、") {
                // Append the comma to the current clause
                currentClause.append(b)
                clauses.append(currentClause)
                currentClause = []
            } else {
                currentClause.append(b)
            }
        }
        
        // Don't forget the last clause
        if !currentClause.isEmpty {
            clauses.append(currentClause)
        }
        
        return clauses
    }
    
    // MARK: - Step 4: Component Role Assignment
    
    /// Assign subject/object/predicate/filler roles to bunsetsu within a clause.
    /// Returns an array of ClauseChunks for rendering.
    private func assignRoles(to clause: [Bunsetsu]) -> [ClauseChunk] {
        var chunks: [ClauseChunk] = []
        
        for b in clause {
            // Check for filler
            if Self.isFillerWord(b.headSurface) {
                chunks.append(ClauseChunk(text: b.text, component: .filler))
                continue
            }
            
            // Discourse marker → plain
            if Self.discourseMarkers.contains(b.headSurface) {
                chunks.append(ClauseChunk(text: b.text, component: .plain))
                continue
            }
            
            // Noun/prefix — role determined by trailing particle
            if b.headPOS == .noun || b.headPOS == .prefix {
                if b.particles.contains(where: { Self.subjectMarkers.contains($0) }) {
                    chunks.append(ClauseChunk(text: b.text, component: .subject))
                } else if b.particles.contains(where: { Self.objectMarkers.contains($0) }) {
                    chunks.append(ClauseChunk(text: b.text, component: .object))
                } else {
                    chunks.append(ClauseChunk(text: b.text, component: .complement))
                }
                continue
            }
            
            // Verb/adjective → predicate
            if b.headPOS == .verb || b.headPOS == .adjective {
                chunks.append(ClauseChunk(text: b.text, component: .predicate))
                continue
            }
            
            // Particle alone, symbol, adverb, or other
            if b.headPOS == .particle {
                chunks.append(ClauseChunk(text: b.text, component: .particle))
            } else if b.headPOS == .adverb {
                chunks.append(ClauseChunk(text: b.text, component: .complement))
            } else {
                chunks.append(ClauseChunk(text: b.text, component: .plain))
            }
        }
        
        return chunks
    }
    
    // MARK: - Private: Helpers
    
    private static func isContentWord(_ pos: PartOfSpeech) -> Bool {
        switch pos {
        case .noun, .verb, .adjective, .adverb, .prefix:
            return true
        case .particle, .symbol, .unknown:
            return false
        }
    }
    
    private static func isFillerWord(_ surface: String) -> Bool {
        let normalized = surface.lowercased()
        if fillerWords.contains(normalized) { return true }
        let elongatedPattern = /^[えあうおー]{2,}$/
        if normalized.wholeMatch(of: elongatedPattern) != nil { return true }
        return false
    }
    
    // MARK: - Private: AttributedString Building
    
    /// Build AttributedString from clauses.
    /// Clauses are separated by line breaks.
    /// Within each clause, bunsetsu chunks are space-separated with role colors.
    private static func buildAttributedString(from clauses: [[ClauseChunk]]) -> AttributedString {
        var result = AttributedString()
        
        for (clauseIdx, clause) in clauses.enumerated() {
            for (chunkIdx, chunk) in clause.enumerated() {
                var part = AttributedString(chunk.text)
                
                switch chunk.component {
                case .subject:
                    part.foregroundColor = subjectColor
                case .object:
                    part.foregroundColor = objectColor
                case .particle:
                    part.foregroundColor = particleColor
                case .predicate:
                    part.foregroundColor = predicateColor
                case .filler:
                    part.foregroundColor = .secondary
                case .complement, .plain:
                    break
                }
                
                result.append(part)
                
                // Space between chunks within a clause
                if chunkIdx < clause.count - 1 {
                    result.append(AttributedString(" "))
                }
            }
            
            // Line break between clauses (not after the last one)
            if clauseIdx < clauses.count - 1 {
                result.append(AttributedString("\n"))
            }
        }
        
        return result
    }
}
