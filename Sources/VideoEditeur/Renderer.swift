import AppKit
import AVFoundation
import CoreText
import SubtitleCore

extension RGBA {
    var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    init(_ color: NSColor) { let c = color.usingColorSpace(.sRGB) ?? .white; self.init(c.redComponent,c.greenComponent,c.blueComponent,c.alphaComponent) }
}
/// Both preview and export draw in bottom-left video coordinates with this renderer.
enum SubtitleRenderer {
    static func box(cue: Cue, project: Project, size: CGSize) -> (NSAttributedString, CGRect, CGFloat) {
        let s = project.style(for: cue), scale = size.height / 1080
        let font = NSFont(name: s.font, size: s.size*scale) ?? NSFont.systemFont(ofSize: s.size*scale, weight: .semibold)
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byWordWrapping
        var attributes: [NSAttributedString.Key:Any] = [.font:font,.foregroundColor:s.color.ns,.paragraphStyle:paragraph,
            .strokeColor:s.outline.ns,.strokeWidth: -s.outlineWidth / max(s.size,1) * 100]
        if s.enhancesReadability {
            let light=(0.2126*s.color.r+0.7152*s.color.g+0.0722*s.color.b)>0.5
            let contrast: NSColor=light ? .black : .white
            attributes[.strokeColor]=contrast
            attributes[.strokeWidth] = -max(3,s.outlineWidth) / max(s.size,1) * 100
            let shadow=NSShadow(); shadow.shadowColor=contrast.withAlphaComponent(0.85)
            shadow.shadowBlurRadius=4*scale; shadow.shadowOffset=NSSize(width:0,height:-2*scale)
            attributes[.shadow]=shadow
        }
        let text=NSAttributedString(string:cue.text,attributes:attributes)
        let pad = 10*scale, maxWidth = max(1,size.width*(s.width ?? 0.90) - pad*2)
        let bounds = text.boundingRect(with: CGSize(width: maxWidth, height: size.height), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let w = s.width.map { size.width*$0 } ?? min(size.width, ceil(bounds.width)+pad*2), h = min(size.height, ceil(bounds.height)+pad*1.2)
        return (text, VideoGeometry.anchoredBox(size: CGSize(width:w,height:h), video:size, x:s.x, y:s.y),pad)
    }
    /// The edit box controls wrapping; the background hugs the rendered text.
    static func backgroundRect(text: NSAttributedString, rect: CGRect, pad: CGFloat) -> CGRect {
        let measured=NSMutableAttributedString(attributedString:text)
        let paragraph=(text.attribute(.paragraphStyle,at:0,effectiveRange:nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        paragraph.alignment = .left
        measured.addAttribute(.paragraphStyle,value:paragraph,range:NSRange(location:0,length:measured.length))
        let bounds=measured.boundingRect(with:rect.insetBy(dx:pad,dy:pad*0.6).size,options:[.usesLineFragmentOrigin,.usesFontLeading])
        let width=min(rect.width,ceil(bounds.width)+pad*2)
        return CGRect(x:rect.midX-width/2,y:rect.minY,width:width,height:rect.height)
    }
    @discardableResult static func draw(project: Project, at ms: Int64, size: CGSize, context: CGContext) -> [(UUID,CGRect)] {
        var hit: [(UUID,CGRect)] = []
        context.saveGState()
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=graphics
        for cue in project.active(at: ms) {
            let (text, rect, pad) = box(cue:cue,project:project,size:size)
            project.style(for:cue).background.ns.setFill()
            NSBezierPath(roundedRect:backgroundRect(text:text,rect:rect,pad:pad),xRadius:6*size.height/1080,yRadius:6*size.height/1080).fill()
            let textRect=rect.insetBy(dx:pad,dy:pad*0.6)
            text.draw(with:textRect,options:[.usesLineFragmentOrigin,.usesFontLeading])
            if project.style(for:cue).enhancesReadability {
                // Paint the fill last so outlines never swallow thin/small glyphs.
                let fill=NSMutableAttributedString(attributedString:text)
                let range=NSRange(location:0,length:fill.length)
                fill.removeAttribute(.shadow,range:range)
                fill.addAttribute(.strokeWidth,value:0,range:range)
                fill.draw(with:textRect,options:[.usesLineFragmentOrigin,.usesFontLeading])
            }
            hit.append((cue.id,rect))
        }
        NSGraphicsContext.restoreGraphicsState(); context.restoreGState(); return hit
    }
}
final class SubtitleInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = false
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let trackID: CMPersistentTrackID
    let transform: CGAffineTransform
    let project: Project
    init(track: AVAssetTrack, duration: CMTime, project: Project) {
        timeRange=CMTimeRange(start:.zero,duration:duration); trackID=track.trackID
        requiredSourceTrackIDs=[NSNumber(value:track.trackID)]; transform=track.preferredTransform; self.project=project
    }
}
final class SubtitleCompositor: NSObject, AVVideoCompositing {
    var sourcePixelBufferAttributes: [String:Any]? { [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA] }
    var requiredPixelBufferAttributesForRenderContext: [String:Any] { [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA, kCVPixelBufferCGImageCompatibilityKey as String:true, kCVPixelBufferCGBitmapContextCompatibilityKey as String:true] }
    private let queue = DispatchQueue(label:"studio.compositor")
    private let ci = CIContext(options:[.cacheIntermediates:false,.workingColorSpace:NSNull(),.outputColorSpace:NSNull()])
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { autoreleasepool {
            guard let ins=request.videoCompositionInstruction as? SubtitleInstruction,
                  let source=request.sourceFrame(byTrackID:ins.trackID), let target=request.renderContext.newPixelBuffer() else {
                request.finish(with:SubtitleError.invalid("无法获取视频帧")); return
            }
            let size=request.renderContext.size
            // AV track transforms use top-left coordinates; Core Image uses bottom-left.
            let flip=CGAffineTransform(scaleX:1,y:-1)
            var frame=CIImage(cvPixelBuffer:source,options:[.colorSpace:NSNull()]).transformed(by:flip).transformed(by:ins.transform).transformed(by:flip)
            frame=frame.transformed(by:CGAffineTransform(translationX:-frame.extent.minX,y:-frame.extent.minY))
            frame=frame.transformed(by:CGAffineTransform(scaleX:size.width/frame.extent.width,y:size.height/frame.extent.height))
            self.ci.render(frame,to:target,bounds:CGRect(origin:.zero,size:size),colorSpace:nil)
            CVPixelBufferLockBaseAddress(target,[])
            guard let ctx=CGContext(data:CVPixelBufferGetBaseAddress(target),width:CVPixelBufferGetWidth(target),height:CVPixelBufferGetHeight(target),bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(target),space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
                CVPixelBufferUnlockBaseAddress(target,[]); request.finish(with:SubtitleError.invalid("无法创建字幕绘图上下文")); return
            }
            SubtitleRenderer.draw(project:ins.project,at:Int64(CMTimeGetSeconds(request.compositionTime)*1000),size:size,context:ctx)
            CVPixelBufferUnlockBaseAddress(target,[]); request.finish(withComposedVideoFrame:target)
        } }
    }
    func cancelAllPendingVideoCompositionRequests() { queue.sync {} }
}

/// Explicit H.264/AAC encoding through the custom compositor, preserving presentation timestamps.
final class VideoExporter {
    private let lock=NSLock()
    private var cancelled=false
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    func cancel() { lock.lock(); cancelled=true; let r=reader; let w=writer; lock.unlock(); r?.cancelReading(); w?.cancelWriting() }
    private var isCancelled: Bool { lock.lock(); defer {lock.unlock()}; return cancelled }
    func run(project: Project, destination: URL, progress: @escaping (Double)->Void) throws {
        try project.validate()
        guard URL(fileURLWithPath:project.videoPath).resolvingSymlinksInPath().standardizedFileURL != destination.resolvingSymlinksInPath().standardizedFileURL else { throw SubtitleError.invalid("不能覆盖源视频") }
        let asset=AVURLAsset(url:URL(fileURLWithPath:project.videoPath))
        guard let video=asset.tracks(withMediaType:.video).first else { throw SubtitleError.invalid("视频没有画面轨道") }
        let rect=CGRect(origin:.zero,size:video.naturalSize).applying(video.preferredTransform)
        let size=CGSize(width:max(2,ceil(abs(rect.width)/2)*2),height:max(2,ceil(abs(rect.height)/2)*2))
        let composition=AVMutableVideoComposition(); composition.customVideoCompositorClass=SubtitleCompositor.self
        composition.renderSize=size; composition.frameDuration=video.minFrameDuration.isValid && CMTimeGetSeconds(video.minFrameDuration)>0 ? video.minFrameDuration : CMTime(value:1,timescale:30)
        composition.instructions=[SubtitleInstruction(track:video,duration:asset.duration,project:project)]
        let temporary=destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at:temporary) }
        let reader=try AVAssetReader(asset:asset), writer=try AVAssetWriter(outputURL:temporary,fileType:.mp4)
        lock.lock(); self.reader=reader; self.writer=writer; lock.unlock()
        defer { lock.lock(); self.reader=nil; self.writer=nil; lock.unlock() }
        let output=AVAssetReaderVideoCompositionOutput(videoTracks:[video],videoSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]); output.videoComposition=composition
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:Int(size.width),AVVideoHeightKey:Int(size.height),AVVideoColorPropertiesKey:[AVVideoColorPrimariesKey:AVVideoColorPrimaries_ITU_R_709_2,AVVideoTransferFunctionKey:AVVideoTransferFunction_ITU_R_709_2,AVVideoYCbCrMatrixKey:AVVideoYCbCrMatrix_ITU_R_709_2],AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:max(2_000_000,Int(size.width*size.height*6)),AVVideoProfileLevelKey:AVVideoProfileLevelH264HighAutoLevel]])
        guard reader.canAdd(output),writer.canAdd(input) else { throw SubtitleError.invalid("视频编码设置不受支持") }
        reader.add(output); writer.add(input)
        var audioOutput: AVAssetReaderTrackOutput?, audioInput: AVAssetWriterInput?
        if let audio=asset.tracks(withMediaType:.audio).first {
            let ao=AVAssetReaderTrackOutput(track:audio,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM])
            let ai=AVAssetWriterInput(mediaType:.audio,outputSettings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVEncoderBitRateKey:192000])
            guard reader.canAdd(ao),writer.canAdd(ai) else { throw SubtitleError.invalid("音频编码设置不受支持") }
            reader.add(ao); writer.add(ai); audioOutput=ao; audioInput=ai
        }
        guard !isCancelled else { throw SubtitleError.invalid("导出已取消") }
        guard writer.startWriting(),reader.startReading() else { throw writer.error ?? reader.error ?? SubtitleError.invalid("无法开始导出") }
        writer.startSession(atSourceTime:.zero)
        let group=DispatchGroup(), queue=DispatchQueue(label:"studio.export.media")
        let duration=max(0.001,CMTimeGetSeconds(asset.duration))
        var pipelineError: Error?
        func pump(_ input: AVAssetWriterInput, _ output: AVAssetReaderOutput, isVideo: Bool) {
            group.enter(); var finished=false
            input.requestMediaDataWhenReady(on:queue) {
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    if self.isCancelled || pipelineError != nil || reader.status == .failed || writer.status == .failed {
                        finished=true; input.markAsFinished(); group.leave(); return
                    }
                    guard let sample=output.copyNextSampleBuffer() else { finished=true; input.markAsFinished(); group.leave(); return }
                    guard input.append(sample) else { pipelineError=writer.error ?? SubtitleError.invalid("写入视频失败"); finished=true; input.markAsFinished(); group.leave(); return }
                    if isVideo { progress(min(0.99,CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))/duration)) }
                }
            }
        }
        pump(input,output,isVideo:true)
        if let ai=audioInput,let ao=audioOutput { pump(ai,ao,isVideo:false) }
        // Timed polling also breaks out when cancellation makes an input stop requesting data.
        while group.wait(timeout:.now()+0.2) == .timedOut {
            if isCancelled { reader.cancelReading(); writer.cancelWriting(); throw SubtitleError.invalid("导出已取消") }
            if reader.status == .failed || writer.status == .failed { throw reader.error ?? writer.error ?? SubtitleError.invalid("导出失败") }
        }
        if isCancelled { throw SubtitleError.invalid("导出已取消") }
        if let error=pipelineError ?? reader.error ?? writer.error { writer.cancelWriting(); throw error }
        let done=DispatchSemaphore(value:0); writer.finishWriting { done.signal() }; done.wait()
        guard !isCancelled,writer.status == .completed else { throw writer.error ?? SubtitleError.invalid("导出已取消或未完成") }
        if FileManager.default.fileExists(atPath:destination.path) { _ = try FileManager.default.replaceItemAt(destination,withItemAt:temporary) }
        else { try FileManager.default.moveItem(at:temporary,to:destination) }
        progress(1)
    }
}
