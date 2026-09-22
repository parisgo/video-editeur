import AppKit
import AVFoundation
import CoreText
import VideoToolbox
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
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = s.textAlignment == .left ? .left : (s.textAlignment == .right ? .right : .center); paragraph.lineBreakMode = .byWordWrapping
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
        let alignment=paragraph.alignment
        paragraph.alignment = .left
        measured.addAttribute(.paragraphStyle,value:paragraph,range:NSRange(location:0,length:measured.length))
        let bounds=measured.boundingRect(with:rect.insetBy(dx:pad,dy:pad*0.6).size,options:[.usesLineFragmentOrigin,.usesFontLeading])
        let width=min(rect.width,ceil(bounds.width)+pad*2)
        let x=alignment == .left ? rect.minX : (alignment == .right ? rect.maxX-width : rect.midX-width/2)
        return CGRect(x:x,y:rect.minY,width:width,height:rect.height)
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
final class VideoExporter {
    private let lock=NSLock()
    private var cancelled=false
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    func cancel() { lock.lock(); cancelled=true; let r=reader; let w=writer; lock.unlock(); r?.cancelReading(); w?.cancelWriting() }
    private var isCancelled: Bool { lock.lock(); defer {lock.unlock()}; return cancelled }
    func run(project: Project, destination: URL, color: VideoColor = .sdr, progress: @escaping (Double)->Void) throws {
        try project.validate()
        guard !(project.allClips.map(\.path)+project.music.map(\.path)).contains(where:{URL(fileURLWithPath:$0).resolvingSymlinksInPath().standardizedFileURL == destination.resolvingSymlinksInPath().standardizedFileURL}) else { throw SubtitleError.invalid(L("不能覆盖源视频")) }
        let supported=try MediaProbe.formats(project).0
        guard supported.contains(color) else { throw SubtitleError.invalid(L("素材色彩格式不一致，无法保真导出所选 HDR 格式")) }
        let edited=try EditedAsset(project:project,color:color,subtitles:true,applySpeed:true)
        let asset=edited.asset, composition=edited.video,size=edited.size
        let temporary=destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at:temporary) }
        let reader=try AVAssetReader(asset:asset), writer=try AVAssetWriter(outputURL:temporary,fileType:.mp4)
        lock.lock(); self.reader=reader; self.writer=writer; lock.unlock()
        defer { lock.lock(); self.reader=nil; self.writer=nil; lock.unlock() }
        let output=AVAssetReaderVideoCompositionOutput(videoTracks:asset.tracks(withMediaType:.video),videoSettings:[kCVPixelBufferPixelFormatTypeKey as String:color == .sdr ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]); output.videoComposition=composition
        let settings: [String:Any]=[AVVideoCodecKey:color == .sdr ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,AVVideoWidthKey:Int(size.width),AVVideoHeightKey:Int(size.height),AVVideoColorPropertiesKey:color.properties,AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:max(2_000_000,Int(size.width*size.height*(color == .sdr ? 6 : 12))),AVVideoProfileLevelKey:color == .sdr ? AVVideoProfileLevelH264HighAutoLevel : kVTProfileLevel_HEVC_Main10_AutoLevel as String]]
        guard writer.canApply(outputSettings:settings,forMediaType:.video) else { throw SubtitleError.invalid(L("此 Mac 不支持所选视频编码格式，请选择 SDR 或更换设备")) }
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:settings)
        guard reader.canAdd(output),writer.canAdd(input) else { throw SubtitleError.invalid(L("视频编码设置不受支持")) }
        reader.add(output); writer.add(input)
        var audioOutput: AVAssetReaderAudioMixOutput?, audioInput: AVAssetWriterInput?
        if !asset.tracks(withMediaType:.audio).isEmpty {
            let ao=AVAssetReaderAudioMixOutput(audioTracks:asset.tracks(withMediaType:.audio),audioSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:48000,AVNumberOfChannelsKey:2]); ao.audioMix=edited.audio
            let ai=AVAssetWriterInput(mediaType:.audio,outputSettings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVEncoderBitRateKey:192000])
            guard reader.canAdd(ao),writer.canAdd(ai) else { throw SubtitleError.invalid(L("音频编码设置不受支持")) }
            reader.add(ao); writer.add(ai); audioOutput=ao; audioInput=ai
        }
        guard !isCancelled else { throw SubtitleError.invalid(L("导出已取消")) }
        guard writer.startWriting(),reader.startReading() else { throw writer.error ?? reader.error ?? SubtitleError.invalid(L("无法开始导出")) }
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
                    guard input.append(sample) else { pipelineError=writer.error ?? SubtitleError.invalid(L("写入视频失败")); finished=true; input.markAsFinished(); group.leave(); return }
                    if isVideo { progress(min(0.99,CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))/duration)) }
                }
            }
        }
        pump(input,output,isVideo:true)
        if let ai=audioInput,let ao=audioOutput { pump(ai,ao,isVideo:false) }
        // Timed polling also breaks out when cancellation makes an input stop requesting data.
        while group.wait(timeout:.now()+0.2) == .timedOut {
            if isCancelled { reader.cancelReading(); writer.cancelWriting(); throw SubtitleError.invalid(L("导出已取消")) }
            if reader.status == .failed || writer.status == .failed { throw reader.error ?? writer.error ?? SubtitleError.invalid(L("导出失败")) }
        }
        if isCancelled { throw SubtitleError.invalid(L("导出已取消")) }
        if let error=pipelineError ?? reader.error ?? writer.error { writer.cancelWriting(); throw error }
        let done=DispatchSemaphore(value:0); writer.finishWriting { done.signal() }; done.wait()
        guard !isCancelled,writer.status == .completed else { throw writer.error ?? SubtitleError.invalid(L("导出已取消或未完成")) }
        if FileManager.default.fileExists(atPath:destination.path) { _ = try FileManager.default.replaceItemAt(destination,withItemAt:temporary) }
        else { try FileManager.default.moveItem(at:temporary,to:destination) }
        progress(1)
    }
}
