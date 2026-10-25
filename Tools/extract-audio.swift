import Foundation
import AVFoundation
let input = CommandLine.arguments[1]
let output = CommandLine.arguments[2]
let task = Task {
    do {
        let asset = AVURLAsset(url: URL(fileURLWithPath: input))
        let duration = try await asset.load(.duration)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        print("Duration: \(duration.seconds)s; audio tracks: \(audio.count)")
        guard !audio.isEmpty else { throw NSError(domain: "No audio track", code: 1) }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw NSError(domain: "Cannot export audio", code: 2) }
        export.outputURL = URL(fileURLWithPath: output)
        export.outputFileType = .m4a
        await export.export()
        guard export.status == .completed else { throw export.error ?? NSError(domain: "Export failed", code: 3) }
        print("Saved: \(output)")
        exit(0)
    } catch { fputs("\(error)\n", stderr); exit(1) }
}
RunLoop.main.run()
