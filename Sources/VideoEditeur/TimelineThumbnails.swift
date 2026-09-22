import AppKit
import AVFoundation
import SubtitleCore

final class TimelineThumbnailJob {
    private let lock=NSLock()
    private var stopped=false
    func cancel() { lock.lock(); stopped=true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func generateWaveforms(clips: [VideoClip], update: @escaping (UUID,[Float])->Void) {
        for clip in clips {
            guard !isCancelled else { return }
            autoreleasepool {
                let asset=AVURLAsset(url:URL(fileURLWithPath:clip.path))
                guard let track=asset.tracks(withMediaType:.audio).first,
                      let reader=try? AVAssetReader(asset:asset) else { return }
                let output=AVAssetReaderTrackOutput(track:track,outputSettings:[
                    AVFormatIDKey:kAudioFormatLinearPCM, AVLinearPCMBitDepthKey:16,
                    AVLinearPCMIsFloatKey:false, AVLinearPCMIsBigEndianKey:false,
                    AVLinearPCMIsNonInterleaved:false
                ])
                output.alwaysCopiesSampleData=false
                guard reader.canAdd(output) else { return }; reader.add(output)
                reader.timeRange=CMTimeRange(start:CMTime(value:clip.sourceStart,timescale:1000),duration:CMTime(value:clip.duration,timescale:1000))
                guard reader.startReading() else { return }
                let count=min(12000,max(1,Int(ceil(Double(clip.duration)/20))))
                var peaks=[Float](repeating:0,count:count)
                while !isCancelled,let buffer=output.copyNextSampleBuffer() {
                    autoreleasepool {
                        guard let block=CMSampleBufferGetDataBuffer(buffer),
                              let format=CMSampleBufferGetFormatDescription(buffer),
                              let description=CMAudioFormatDescriptionGetStreamBasicDescription(format) else { return }
                        let rate=description.pointee.mSampleRate,channels=Int(description.pointee.mChannelsPerFrame)
                        guard rate>0,channels>0 else { return }
                        let bytes=CMBlockBufferGetDataLength(block)
                        guard bytes>=2 else { return }
                        var samples=[Int16](repeating:0,count:bytes/2)
                        let status=samples.withUnsafeMutableBytes { data in
                            CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:data.count,destination:data.baseAddress!)
                        }
                        guard status == kCMBlockBufferNoErr else { return }
                        let start=CMSampleBufferGetPresentationTimeStamp(buffer).seconds-Double(clip.sourceStart)/1000
                        guard start.isFinite else { return }
                        for frame in 0..<(samples.count/channels) {
                            let time=start+Double(frame)/rate
                            guard time>=0,time<Double(clip.duration)/1000 else { continue }
                            let bin=min(count-1,Int(time*1000/Double(clip.duration)*Double(count)))
                            for channel in 0..<channels {
                                peaks[bin]=max(peaks[bin],abs(Float(samples[frame*channels+channel]))/32768)
                            }
                        }
                    }
                }
                if isCancelled { reader.cancelReading(); return }
                if reader.status == .completed { update(clip.id,peaks) }
            }
        }
    }
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
        timeline.clipThumbnails=[:]; timeline.clipWaveforms=[:]; timeline.needsDisplay=true
        DispatchQueue.global(qos:.utility).async { [weak self] in
            job.generateWaveforms(clips:clips) { id,peaks in
                DispatchQueue.main.async {
                    guard let self,self.thumbnailJob === job,!job.isCancelled else { return }
                    self.timeline.clipWaveforms[id]=peaks; self.timeline.needsDisplay=true
                }
            }
        }
        DispatchQueue.global(qos:.utility).async { [weak self] in
            job.generate(clips:clips) { id,images in
                DispatchQueue.main.async {
                    guard let self,self.thumbnailJob === job,!job.isCancelled else { return }
                    self.timeline.clipThumbnails[id]=images; self.timeline.needsDisplay=true
                    if let image=images.compactMap({$0}).first,
                       let card=self.mediaGrid.cards.first(where:{$0.identifier?.rawValue == id.uuidString}) { card.thumbnail=image }
                    // Update only the image, preserving selection and any active editing.
                    if let image=images.compactMap({$0}).first,
                       let row=self.libraryEntries.firstIndex(where:{$0.clipID == id}),
                       let cell=self.table.view(atColumn:0,row:row,makeIfNecessary:false),
                       let thumbnail=cell.subviews.first(where:{$0.identifier?.rawValue == "mediaThumbnail"}) as? NSImageView {
                        thumbnail.image=image
                    }
                }
            }
        }
    }
}
