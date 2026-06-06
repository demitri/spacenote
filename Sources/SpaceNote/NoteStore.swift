import AppKit

/// Owns the persisted note set: manifest.json + one .rtf per note in
/// Application Support (PLAN.md §3). Atomic writes, debounced autosave.
/// Main-thread only.
final class NoteStore {
    static let saveDebounce: TimeInterval = 1.0

    let directory: URL
    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    private(set) var notes: [Note] = []          // manifest order (status-menu order)
    private var pendingRTF: [UUID: Data] = [:]   // text edits awaiting flush
    private var manifestDirty = false
    private var saveTimer: Timer?
    private var retryTimer: Timer?

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask)[0]
        directory = appSupport.appendingPathComponent("SpaceNote", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
        } catch {
            // Without a store directory nothing can persist — crash loudly.
            fatalError("SpaceNote: cannot create \(directory.path): \(error)")
        }
    }

    // MARK: - Load

    /// Loads all notes plus their parsed text. A missing manifest is a normal
    /// first launch (returns []); a corrupt manifest or unreadable RTF is
    /// quarantined and surfaced, never overwritten silently.
    func loadAll() -> [(note: Note, text: NSAttributedString?)] {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return [] }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self,
                                                from: try Data(contentsOf: manifestURL))
        } catch {
            quarantineCorruptManifest(error)
            return []
        }
        notes = manifest.notes
        var result: [(note: Note, text: NSAttributedString?)] = []
        for index in notes.indices {
            let note = notes[index]
            let url = directory.appendingPathComponent(note.rtfFilename)
            guard FileManager.default.fileExists(atPath: url.path) else {
                NSLog("SpaceNote: \(note.rtfFilename) missing — opening note empty")
                result.append((note, nil))
                continue
            }
            do {
                let data = try Data(contentsOf: url)
                if let text = NSAttributedString(rtf: data, documentAttributes: nil) {
                    result.append((note, text))
                    continue
                }
                // Unparseable: move aside so the first edit can't overwrite it.
                let stamp = ISO8601DateFormatter().string(from: Date())
                let backup = directory.appendingPathComponent("\(note.rtfFilename).unreadable-\(stamp)")
                try FileManager.default.moveItem(at: url, to: backup)
                NSLog("SpaceNote: \(note.rtfFilename) is not valid RTF — preserved as \(backup.lastPathComponent), opening empty")
                result.append((note, nil))
            } catch {
                // Can't read (or can't quarantine) the original: NEVER leave it
                // where the first edit would overwrite it — divert all future
                // saves for this note to a fresh file.
                let stamp = ISO8601DateFormatter().string(from: Date())
                notes[index].rtfFilename = "\(note.id.uuidString)-recovered-\(stamp).rtf"
                manifestDirty = true
                NSLog("SpaceNote: cannot read/quarantine \(note.rtfFilename): \(error) — original left untouched; this note now saves to \(notes[index].rtfFilename)")
                result.append((notes[index], nil))
            }
        }
        return result
    }

    private func quarantineCorruptManifest(_ error: Error) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let backup = directory.appendingPathComponent("manifest.corrupt-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: manifestURL, to: backup)
        } catch {
            fatalError("SpaceNote: manifest corrupt AND cannot be quarantined — refusing to run (would overwrite it): \(error)")
        }
        NSLog("SpaceNote: manifest corrupt (\(error)) — preserved as \(backup.lastPathComponent)")
        let alert = NSAlert()
        alert.messageText = "SpaceNote could not read its notes manifest"
        alert.informativeText = """
        The damaged file was preserved as \(backup.lastPathComponent) in \
        \(directory.path). Note text (.rtf files) is untouched. Starting with \
        an empty note list.

        Error: \(error.localizedDescription)
        """
        alert.runModal()
    }

    // MARK: - CRUD

    func create(frame: CGRect, color: NoteColor) -> Note {
        let note = Note(color: color, frame: frame)
        notes.append(note)
        manifestDirty = true
        saveNow()   // creation is rare and user-explicit; make it durable immediately
        return note
    }

    func update(_ note: Note) {
        guard let idx = notes.firstIndex(where: { $0.id == note.id }) else {
            NSLog("SpaceNote: update for unknown note \(note.id) — ignoring (deleted?)")
            return
        }
        notes[idx] = note
        manifestDirty = true
        scheduleSave()
    }

    func textChanged(id: UUID, rtf: Data) {
        pendingRTF[id] = rtf
        scheduleSave()
    }

    func delete(id: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        let note = notes.remove(at: idx)
        pendingRTF[id] = nil
        manifestDirty = true
        let url = directory.appendingPathComponent(note.rtfFilename)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            NSLog("SpaceNote: could not delete \(note.rtfFilename): \(error) — orphan left behind")
        }
        saveNow()   // deletion is user-explicit; flush immediately
    }

    // MARK: - Saving

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: NoteStore.saveDebounce,
                                         repeats: false) { [weak self] _ in
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        retryTimer?.invalidate()
        retryTimer = nil

        for (id, data) in pendingRTF {
            guard let note = notes.first(where: { $0.id == id }) else { continue }
            let url = directory.appendingPathComponent(note.rtfFilename)
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("SpaceNote: FAILED to save \(note.rtfFilename): \(error) — keeping pending")
                continue
            }
            pendingRTF[id] = nil
        }

        if manifestDirty {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(Manifest(version: Manifest.currentVersion, notes: notes))
                try data.write(to: manifestURL, options: .atomic)
                manifestDirty = false
            } catch {
                NSLog("SpaceNote: FAILED to save manifest: \(error)")
            }
        }

        // Anything still unsaved retries on its own — never sit indefinitely
        // on in-memory-only edits waiting for the user's next keystroke.
        if manifestDirty || !pendingRTF.isEmpty {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                self?.saveNow()
            }
        }
    }
}
