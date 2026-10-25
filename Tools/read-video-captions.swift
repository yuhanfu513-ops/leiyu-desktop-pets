import AppKit
import AVFoundation
import Vision
let url=URL(fileURLWithPath:CommandLine.arguments[1])
let asset=AVURLAsset(url:url)
let generator=AVAssetImageGenerator(asset:asset)
generator.appliesPreferredTrackTransform=true
generator.maximumSize=CGSize(width:1080,height:1920)
var rows:[[String:Any]]=[]
let saved:Set<Int>=[2,10,30,50,70,90]
for i in 0..<103 {
    let seconds=Double(i)*0.5
    do {
        let cg=try generator.copyCGImage(at:CMTime(seconds:seconds,preferredTimescale:600),actualTime:nil)
        if saved.contains(i) {
            let bitmap=NSBitmapImageRep(cgImage:cg)
            try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"Work/audio-analysis/frame-\(i).png"))
        }
        let request=VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages=["zh-Hans","en-US"]
        request.usesLanguageCorrection=true
        try VNImageRequestHandler(cgImage:cg,options:[:]).perform([request])
        let lines=(request.results ?? []).compactMap { r -> [String:Any]? in
            guard let t=r.topCandidates(1).first else { return nil }
            return ["text":t.string,"y":r.boundingBox.minY,"x":r.boundingBox.minX,"confidence":t.confidence]
        }
        rows.append(["time":seconds,"lines":lines])
        if i%10==0 { print("OCR \(seconds)s", terminator:"\n");fflush(stdout) }
    } catch { print("Frame \(seconds): \(error)") }
}
try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"Work/audio-analysis/video-ocr.json"))
print("OCR complete")
