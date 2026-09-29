// MKV playback. AVFoundation cannot open Matroska at all (still true on
// macOS 26), so an .mkv is remuxed into an MP4 first: the video stream is
// copied as is (HEVC retagged hvc1), audio AVFoundation can decode is copied
// too, the rest (DTS, TrueHD, FLAC, Opus, PCM…) becomes AAC. Subtitles are
// dropped. Needs ffmpeg/ffprobe from Homebrew.
//
// The MP4 goes next to the source as "<name>.mp4" and stays there: next time
// it is played directly, and the picker hides the .mkv behind it. While
// writing it is the hidden ".<name>.part.mp4", renamed only on success.
// The .mkv itself is never touched.

import Foundation

final class Remuxer {
    // Room left on the source's volume after the copy
    static let minFreeSpace: Int64 = 2 << 30

    // Audio codecs AVFoundation plays from an MP4 — copied without re-encoding
    private static let copyableAudio: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac"]

    enum Failure: Error {
        case noFFmpeg, noSpace, notWritable, failed(String)

        var message: String {
            switch self {
            case .noFFmpeg: return "MKV needs ffmpeg — run: brew install ffmpeg"
            case .noSpace: return "Not enough disk space next to the MKV for its MP4 copy"
            case .notWritable: return "Can't write the MP4 copy next to the MKV (read-only folder?)"
            case .failed: return "Could not prepare the MKV (see log)"
            }
        }
    }

    static func handles(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "mkv"
    }

    // "<name>.mp4" next to "<name>.mkv"
    static func remuxURL(for source: URL) -> URL {
        source.deletingPathExtension().appendingPathExtension("mp4")
    }

    // The playable copy, if it was made already
    static func existingRemux(for source: URL) -> URL? {
        let url = remuxURL(for: source)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func tool(_ name: String) -> String? {
        // Launched via `open`, the app does not get the shell's PATH
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return dirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    let source: URL
    // Both called on main; onProgress gets 0…1
    var onProgress: ((Double) -> Void)?
    var onFinish: ((Result<URL, Failure>) -> Void)?

    private let lock = NSLock()
    private var process: Process?
    private var partURL: URL?
    private var cancelled = false

    init(source: URL) {
        self.source = source
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = run()
            DispatchQueue.main.async { [self] in
                lock.lock()
                let wasCancelled = cancelled
                lock.unlock()
                if !wasCancelled {
                    onFinish?(result)
                }
            }
        }
    }

    // Stops ffmpeg; onFinish is not called. The partial file is removed by
    // run(), or right here with `wait` (on quit, when run() may never finish)
    func cancel(wait: Bool = false) {
        lock.lock()
        cancelled = true
        let p = process
        let part = partURL
        lock.unlock()
        guard let p else { return }
        p.terminate()
        if wait {
            p.waitUntilExit()
            if let part {
                try? FileManager.default.removeItem(at: part)
            }
        }
    }

    private func run() -> Result<URL, Failure> {
        guard let ffmpeg = Self.tool("ffmpeg"), let ffprobe = Self.tool("ffprobe") else {
            print("[remux] ffmpeg/ffprobe not found in /opt/homebrew/bin, /usr/local/bin or PATH")
            return .failure(.noFFmpeg)
        }
        let dir = source.deletingLastPathComponent()
        let out = Self.remuxURL(for: source)
        let part = dir.appendingPathComponent(
            "." + source.deletingPathExtension().lastPathComponent + ".part.mp4")
        guard FileManager.default.isWritableFile(atPath: dir.path) else {
            print("[remux] folder is not writable: \(dir.path)")
            return .failure(.notWritable)
        }

        // Streams and duration
        let probe = Self.execute(ffprobe, ["-v", "error", "-show_entries",
            "format=duration:stream=index,codec_type,codec_name,channels:stream_disposition=attached_pic",
            "-of", "json", source.path])
        guard probe.status == 0,
              let json = try? JSONSerialization.jsonObject(with: probe.stdout) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]] else {
            print("[remux] ffprobe failed: \(probe.stderrTail)")
            return .failure(.failed("ffprobe"))
        }
        let duration = Double((json["format"] as? [String: Any])?["duration"] as? String ?? "") ?? 0
        let video = streams.first {
            $0["codec_type"] as? String == "video"
                && ((($0["disposition"] as? [String: Any])?["attached_pic"] as? Int) ?? 0) == 0
        }
        guard let video else {
            print("[remux] no video stream in \(source.lastPathComponent)")
            return .failure(.failed("no video"))
        }
        let audio = streams.filter { $0["codec_type"] as? String == "audio" }

        // The copy is about the size of the source (AAC audio is smaller
        // than DTS/TrueHD, so this errs on the safe side)
        let sourceSize = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? 0
        let values = try? dir.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        // External disks report 0 for the "important usage" figure
        let free = values?.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? $0 : nil }
            ?? Int64(values?.volumeAvailableCapacity ?? 0)
        guard free - sourceSize >= Self.minFreeSpace else {
            print("[remux] not enough space: need \(sourceSize >> 20) MB + "
                + "\(Self.minFreeSpace >> 30) GB reserve, free \(free >> 20) MB")
            return .failure(.noSpace)
        }

        var args = ["-nostdin", "-y", "-v", "error", "-progress", "pipe:1", "-nostats",
                    "-fflags", "+genpts", "-i", source.path,
                    "-map", "0:\(video["index"] as? Int ?? 0)", "-map", "0:a?",
                    "-c:v", "copy", "-sn", "-dn", "-max_muxing_queue_size", "4096"]
        let videoCodec = video["codec_name"] as? String ?? "?"
        if videoCodec == "hevc" {
            args += ["-tag:v", "hvc1"]
        }
        var audioInfo: [String] = []
        for (i, a) in audio.enumerated() {
            let codec = a["codec_name"] as? String ?? "?"
            let channels = a["channels"] as? Int ?? 2
            if Self.copyableAudio.contains(codec) {
                args += ["-c:a:\(i)", "copy"]
                audioInfo.append(codec)
            } else {
                // AAC tops out at 5.1 in practice: 7.1 is downmixed
                args += ["-c:a:\(i)", "aac", "-b:a:\(i)", channels > 2 ? "384k" : "192k"]
                if channels > 6 {
                    args += ["-ac:a:\(i)", "6"]
                }
                audioInfo.append("\(codec)→aac")
            }
        }
        args += ["-f", "mp4", part.path]
        print("[remux] \(source.lastPathComponent): video \(videoCodec) copied, audio "
            + (audioInfo.isEmpty ? "none" : audioInfo.joined(separator: ", ")))

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = args
        let stdout = Pipe(), stderr = Pipe()
        p.standardOutput = stdout
        p.standardError = stderr
        let started = Date()
        do {
            try p.run()
        } catch {
            print("[remux] cannot start ffmpeg: \(error)")
            return .failure(.failed("launch"))
        }
        // Registered only once running: terminate() on a Process that was
        // never launched raises an exception
        lock.lock()
        process = p
        partURL = part
        let cancelledEarly = cancelled
        lock.unlock()
        if cancelledEarly {
            p.terminate()
        }
        // -progress prints key=value blocks; out_time_us is the muxed position
        var pending = Data()
        while true {
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let nl = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: pending[..<nl], as: UTF8.self)
                pending.removeSubrange(...nl)
                if line.hasPrefix("out_time_us="), duration > 0,
                   let us = Double(line.dropFirst("out_time_us=".count)) {
                    let fraction = max(0, min(1, us / 1e6 / duration))
                    DispatchQueue.main.async { [weak self] in self?.onProgress?(fraction) }
                }
            }
        }
        let errText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()

        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        guard p.terminationStatus == 0, !wasCancelled else {
            try? FileManager.default.removeItem(at: part)
            if wasCancelled {
                print("[remux] cancelled")
                return .failure(.failed("cancelled"))
            }
            let tail = errText.split(separator: "\n").suffix(5).joined(separator: "\n")
            print("[remux] ffmpeg failed (\(p.terminationStatus)):\n\(tail)")
            return .failure(.failed(tail))
        }
        do {
            try FileManager.default.moveItem(at: part, to: out)
        } catch {
            print("[remux] cannot finish \(out.path): \(error)")
            return .failure(.failed("rename"))
        }
        print(String(format: "[remux] done in %.0f s → %@", Date().timeIntervalSince(started), out.path))
        return .success(out)
    }

    private static func execute(_ tool: String, _ args: [String])
        -> (status: Int32, stdout: Data, stderrTail: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (-1, Data(), "\(error)") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data,
                String(decoding: errData, as: UTF8.self).split(separator: "\n").suffix(3).joined(separator: " "))
    }
}
