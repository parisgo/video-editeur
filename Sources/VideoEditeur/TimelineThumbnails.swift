import AppKit
import AVFoundation
import SubtitleCore

final class TimelineThumbnailJob {
    private let lock=NSLock()
    private var stopped=false
    func cancel() { lock.lock(); stopped=true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func generate(clips: [VideoClip], update: @escaping (UUID,[NSImage?])->Void) {
        for clip in clips {
            guard !isCancelled else { return }
            let generator=AVAssetImageGenerator(asset:AVURLAsset(url:URL(fileURLWithPath:clip.path)))
            generator.appliesPreferredTrackTransform=true
            generator.maximumSize=CGSize(width:180,height:110)
            generator.requestedTimeToleranceBefore=CMTime(value:100,timescale:1000)
            generator.requestedTimeToleranceAfter=CMTime(value:100,timescale:1000)
            let count=min(160,max(1,Int(ceil(Double(clip.duration)/1400))))
            var images=[NSImage?](repeating:nil,count:count)
            for i in 0..<count {
                guard !isCancelled else { return }
                autoreleasepool {
                    // Sample inside the retained source range, including after a split or trim.
                    let offset=min(clip.duration-1,Int64((Double(i)+0.5)*Double(clip.duration)/Double(count)))
                    let time=CMTime(value:clip.sourceStart+offset,timescale:1000)
                    if let cg=try? generator.copyCGImage(at:time,actualTime:nil) {
                        images[i]=NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height))
                    }
                }
                if i == 0 || i%4 == 0 || i == count-1 { update(clip.id,images) }
            }
        }
    }
}
extension EditorController {
    func loadTimelineThumbnails(for clips: [VideoClip]) {
        thumbnailJob?.cancel()
        let job=TimelineThumbnailJob(); thumbnailJob=job
        timeline.clipThumbnails=[:]; timeline.needsDisplay=true
        DispatchQueue.global(qos:.utility).async { [weak self] in
            job.generate(clips:clips) { id,images in
                DispatchQueue.main.async {
                    guard let self,self.thumbnailJob === job,!job.isCancelled else { return }
                    self.timeline.clipThumbnails[id]=images; self.timeline.needsDisplay=true
                }
            }
        }
    }
}
