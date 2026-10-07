import Foundation

/// Proje üzerinde yapılabilen düzenlemeler. Kaynak medya hiçbir zaman
/// değişmez (tahribatsız düzenleme); yalnız proje modeli değişir.
public enum EditCommand: Equatable, Sendable {
    case insertClip(trackId: UUID, clip: Clip)
    case removeClip(clipId: UUID)
    case trimClip(clipId: UUID, sourceIn: MediaTime, sourceOut: MediaTime)
    case moveClip(clipId: UUID, timelineStart: MediaTime)
    case setRate(clipId: UUID, rate: Double)
    /// Klibi zaman çizelgesindeki bir anda ikiye böler. İkinci parça
    /// `newClipId` kimliğini alır.
    case splitClip(clipId: UUID, at: MediaTime, newClipId: UUID)
    /// Kelimenin görünen metnini düzeltir; nil düzeltmeyi kaldırır.
    case correctWord(captionTrackId: UUID, wordId: String, text: String?)
}

public enum EditError: Error, Equatable {
    case trackNotFound
    case clipNotFound
    case captionTrackNotFound
    case wordNotFound
    case splitOutsideClip
    case invalidProject([ProjectValidator.Issue])
}

extension ProjectDocument {
    /// Komutu uygular, sonucu doğrular. Geçersiz sonuç üreten komut hata
    /// verir ve projeyi değiştirmez.
    public func applying(_ command: EditCommand) throws -> ProjectDocument {
        var doc = self
        switch command {
        case let .insertClip(trackId, clip):
            guard let t = doc.tracks.firstIndex(where: { $0.trackId == trackId }) else { throw EditError.trackNotFound }
            doc.tracks[t].clips.append(clip)

        case let .removeClip(clipId):
            let (t, c) = try doc.requireClip(clipId)
            doc.tracks[t].clips.remove(at: c)

        case let .trimClip(clipId, sourceIn, sourceOut):
            let (t, c) = try doc.requireClip(clipId)
            doc.tracks[t].clips[c].sourceIn = sourceIn
            doc.tracks[t].clips[c].sourceOut = sourceOut

        case let .moveClip(clipId, timelineStart):
            let (t, c) = try doc.requireClip(clipId)
            doc.tracks[t].clips[c].timelineStart = timelineStart

        case let .setRate(clipId, rate):
            let (t, c) = try doc.requireClip(clipId)
            doc.tracks[t].clips[c].playbackRate = rate

        case let .splitClip(clipId, at, newClipId):
            let (t, c) = try doc.requireClip(clipId)
            let clip = doc.tracks[t].clips[c]
            guard at > clip.timelineRange.start, at < clip.timelineRange.end,
                  let splitSource = clip.sourceTime(forTimeline: at) else {
                throw EditError.splitOutsideClip
            }
            var first = clip
            first.sourceOut = splitSource
            var second = clip
            second.clipId = newClipId
            second.sourceIn = splitSource
            second.timelineStart = first.timelineRange.end
            doc.tracks[t].clips[c] = first
            doc.tracks[t].clips.insert(second, at: c + 1)

        case let .correctWord(captionTrackId, wordId, text):
            guard let i = doc.captionTracks.firstIndex(where: { $0.captionTrackId == captionTrackId }) else {
                throw EditError.captionTrackNotFound
            }
            guard doc.captionTracks[i].words.contains(where: { $0.id == wordId }) else { throw EditError.wordNotFound }
            if let text, !text.isEmpty {
                doc.captionTracks[i].corrections[wordId] = text
            } else {
                doc.captionTracks[i].corrections[wordId] = nil
            }
        }

        for i in doc.tracks.indices {
            doc.tracks[i].clips.sort { $0.timelineStart < $1.timelineStart }
        }
        let issues = ProjectValidator.validate(doc)
        guard issues.isEmpty else { throw EditError.invalidProject(issues) }
        return doc
    }

    func requireClip(_ clipId: UUID) throws -> (Int, Int) {
        guard let location = locateClip(clipId) else { throw EditError.clipNotFound }
        return (location.trackIndex, location.clipIndex)
    }
}

/// Geri al / yinele. Her başarılı komut önceki anlık görüntüyü saklar; proje
/// değer tipi olduğu için bu ucuzdur ve geri almayı her komut için ayrı ters
/// komut yazmaktan daha güvenilir kılar.
public struct EditHistory: Sendable {
    public private(set) var present: ProjectDocument
    private var undoStack: [ProjectDocument] = []
    private var redoStack: [ProjectDocument] = []
    public let limit: Int
    private let now: @Sendable () -> Date

    public init(_ document: ProjectDocument, limit: Int = 100, now: @escaping @Sendable () -> Date = { Date() }) {
        self.present = document
        self.limit = limit
        self.now = now
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func apply(_ command: EditCommand) throws {
        var next = try present.applying(command)
        next.revision = present.revision + 1
        next.updatedAt = ProjectTimestamp.normalize(now())
        undoStack.append(present)
        if undoStack.count > limit { undoStack.removeFirst() }
        redoStack.removeAll()
        present = next
    }

    /// Geri alma da yeni bir revision'dır: dışa aktarma ve otomatik kayıt
    /// değişikliği görebilsin diye revision geri sarılmaz.
    public mutating func undo() {
        guard var previous = undoStack.popLast() else { return }
        redoStack.append(present)
        previous.revision = present.revision + 1
        previous.updatedAt = ProjectTimestamp.normalize(now())
        present = previous
    }

    public mutating func redo() {
        guard var next = redoStack.popLast() else { return }
        undoStack.append(present)
        next.revision = present.revision + 1
        next.updatedAt = ProjectTimestamp.normalize(now())
        present = next
    }
}
