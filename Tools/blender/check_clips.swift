// Verify every clip in Assets/Animations/manifest.json by decoding it through AVFoundation
// (the same path the SwiftUI app uses). Reports size, fps, frame count, alpha range and,
// for loops, the seam: the last->first frame difference vs the typical frame-to-frame step.
//   swift -suppress-warnings Tools/blender/check_clips.swift Assets/Animations > check_report.json
import AVFoundation
import Foundation

struct Frame { let a: [UInt8]; let rgb: [UInt8] }

func decode(_ url: URL) -> (w: Int, h: Int, fps: Float, frames: [Frame])? {
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .video).first, let reader = try? AVAssetReader(asset: asset) else { return nil }
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(out); reader.startReading()
    var frames: [Frame] = []; var W = 0, H = 0
    while let sb = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        W = w; H = h
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        var a = [UInt8](), rgb = [UInt8]()
        a.reserveCapacity(w * h / 4); rgb.reserveCapacity(w * h * 3 / 4)
        for y in stride(from: 0, to: h, by: 2) { for x in stride(from: 0, to: w, by: 2) {
            let p = y * bpr + x * 4
            a.append(base[p + 3]); rgb.append(base[p]); rgb.append(base[p + 1]); rgb.append(base[p + 2]) } }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        frames.append(Frame(a: a, rgb: rgb))
    }
    return (W, H, track.nominalFrameRate, frames)
}

func diff(_ x: Frame, _ y: Frame) -> Double {
    var s = 0
    for i in 0..<x.a.count { s += abs(Int(x.a[i]) - Int(y.a[i])) }
    for i in 0..<x.rgb.count { s += abs(Int(x.rgb[i]) - Int(y.rgb[i])) / 3 }
    return Double(s) / Double(x.a.count)
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Assets/Animations")
let manifest = try! JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("manifest.json"))) as! [String: Any]
var report: [[String: Any]] = []
var problems = 0
for clip in manifest["clips"] as! [[String: Any]] {
    let mov = dir.appendingPathComponent(clip["mov"] as! String)
    guard let d = decode(mov), !d.frames.isEmpty else { report.append(["name": clip["name"]!, "error": "decode failed"]); problems += 1; continue }
    var minA = 255, maxA = 0
    for f in d.frames { for v in f.a { minA = min(minA, Int(v)); maxA = max(maxA, Int(v)) } }
    var r: [String: Any] = ["slot": clip["slot"]!, "name": clip["name"]!, "width": d.w, "height": d.h, "fps": d.fps,
                            "frames": d.frames.count, "alpha_min": minA, "alpha_max": maxA]
    var ok = d.w == clip["width"] as! Int && d.h == clip["height"] as! Int && d.frames.count == clip["frames"] as! Int
        && abs(d.fps - 30) < 0.01 && minA == 0
    if clip["loop"] as! Bool, d.frames.count > 2 {
        var steps: [Double] = []
        for i in 1..<d.frames.count { steps.append(diff(d.frames[i - 1], d.frames[i])) }
        let typical = steps.sorted()[steps.count / 2]
        let seam = diff(d.frames.last!, d.frames.first!)
        let maxStep = steps.max()!
        r["seam"] = (seam * 1000).rounded() / 1000; r["typical_step"] = (typical * 1000).rounded() / 1000
        r["max_step"] = (maxStep * 1000).rounded() / 1000
        // a seam is visible if the wrap jump is clearly bigger than the largest in-loop step
        let seamOK = seam <= max(maxStep * 1.25, 0.05)
        r["seam_ok"] = seamOK
        ok = ok && seamOK
    }
    r["ok"] = ok
    if !ok { problems += 1 }
    report.append(r)
}
let outObj: [String: Any] = ["checked": report.count, "problems": problems, "clips": report]
let data = try! JSONSerialization.data(withJSONObject: outObj, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
