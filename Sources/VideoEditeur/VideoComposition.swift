import AppKit
import AVFoundation
import CoreImage
import VideoToolbox
import SubtitleCore

enum VideoColor: String {
    case sdr, hlg, pq
    var title: String { switch self { case .sdr:return "SDR · H.264 / BT.709"; case .hlg:return "HDR HLG · HEVC 10-bit / BT.2020"; case .pq:return "HDR PQ · HEVC 10-bit / BT.2020" } }
    var transfer: String { switch self { case .sdr:return AVVideoTransferFunction_ITU_R_709_2; case .hlg:return AVVideoTransferFunction_ITU_R_2100_HLG; case .pq:return AVVideoTransferFunction_SMPTE_ST_2084_PQ } }
    var primaries: String { self == .sdr ? AVVideoColorPrimaries_ITU_R_709_2 : AVVideoColorPrimaries_ITU_R_2020 }
    var matrix: String { self == .sdr ? AVVideoYCbCrMatrix_ITU_R_709_2 : AVVideoYCbCrMatrix_ITU_R_2020 }
    var space: CGColorSpace { CGColorSpace(name:self == .sdr ? CGColorSpace.itur_709 : self == .hlg ? CGColorSpace.itur_2100_HLG : CGColorSpace.itur_2100_PQ)! }
    var properties: [String:Any] { [AVVideoColorPrimariesKey:primaries,AVVideoTransferFunctionKey:transfer,AVVideoYCbCrMatrixKey:matrix] }
}
struct MediaProbe {
    let color: VideoColor
    let dolbyVision: Bool
    let duration: Int64
    let size: CGSize
    let fps: Float
    var description: String { "\(Int(size.width)) × \(Int(size.height)) · \(color == .sdr ? L("SDR / 未标记 HDR") : color == .hlg ? "HLG" : "PQ")\(dolbyVision ? L(" · Dolby Vision 基础层") : "")" }
    init(_ path: String) throws {
        let asset=AVURLAsset(url:URL(fileURLWithPath:path))
        guard let track=asset.tracks(withMediaType:.video).first else { throw SubtitleError.invalid(L("无法读取视频：{0}", [String(describing: path)])) }
        let seconds=CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite,seconds>0,seconds<1e9 else { throw SubtitleError.invalid(L("视频时长无效")) }
        duration=Int64(seconds*1000); fps=track.nominalFrameRate
        let rect=CGRect(origin:.zero,size:track.naturalSize).applying(track.preferredTransform)
        size=CGSize(width:abs(rect.width),height:abs(rect.height))
        guard let description=track.formatDescriptions.first else { throw SubtitleError.invalid(L("视频缺少格式信息")) }
        let format=description as! CMFormatDescription
        let extensions=(CMFormatDescriptionGetExtensions(format) as NSDictionary?) ?? NSDictionary()
        let transfer=extensions[kCMFormatDescriptionExtension_TransferFunction] as? String
        color=transfer == AVVideoTransferFunction_ITU_R_2100_HLG ? .hlg : transfer == AVVideoTransferFunction_SMPTE_ST_2084_PQ ? .pq : .sdr
        let atoms=extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? NSDictionary
        let codec=CMFormatDescriptionGetMediaSubType(format)
        dolbyVision=atoms?["dvcC"] != nil || atoms?["dvvC"] != nil || codec == 0x64766831 || codec == 0x64766865
    }
    static func formats(_ project: Project) throws -> ([VideoColor],String) {
        let probes=try project.clips.map{try MediaProbe($0.path)}
        let colors=Set(probes.map{$0.color.rawValue})
        var formats: [VideoColor]=[.sdr]
        if colors.count == 1,let color=probes.first?.color,color != .sdr { formats.append(color) }
        let detail=zip(project.clips,probes).map{URL(fileURLWithPath:$0.0.path).lastPathComponent+"："+$0.1.description}.joined(separator:"\n")
        let policy=colors.count>1 ? L("\n混合色彩格式：本版仅提供 SDR 输出，避免误标 HDR。") : ""
        let dv=probes.contains{$0.dolbyVision} ? L("\nDolby Vision 动态元数据不会保留，只可处理兼容基础层。") : ""
        return (formats,detail+policy+dv+L("\nHDR 为重新编码，非逐位无损；显示效果还取决于屏幕。"))
    }
}
struct RenderLayer {
    let trackID: CMPersistentTrackID
    let transform: CGAffineTransform
    let placement: ClipPlacement
    let outgoing: Int64
}
final class EditInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing=false
    let containsTweening=true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID=kCMPersistentTrackID_Invalid
    let layers: [RenderLayer]
    let project: Project
    let color: VideoColor
    let subtitles: Bool
    init(start: Int64,end: Int64,layers: [RenderLayer],project: Project,color: VideoColor,subtitles: Bool) {
        timeRange=CMTimeRange(start:CMTime(value:start,timescale:1000),duration:CMTime(value:end-start,timescale:1000))
        self.layers=layers; self.project=project; self.color=color; self.subtitles=subtitles
        requiredSourceTrackIDs=layers.map{NSNumber(value:$0.trackID)}
    }
}
struct EditedAsset {
    let asset: AVMutableComposition
    let video: AVMutableVideoComposition
    let audio: AVMutableAudioMix
    let size: CGSize
    init(project: Project,color: VideoColor,subtitles: Bool) throws {
        try project.validate()
        guard let first=project.clips.first else { throw SubtitleError.invalid(L("请先添加视频")) }
        let probe=try MediaProbe(first.path)
        size=CGSize(width:max(2,ceil(probe.size.width/2)*2),height:max(2,ceil(probe.size.height/2)*2))
        asset=AVMutableComposition(); video=AVMutableVideoComposition(); audio=AVMutableAudioMix()
        var layers: [RenderLayer]=[],parameters: [AVAudioMixInputParameters]=[]
        let places=project.placements
        var frameDuration=CMTime(value:1,timescale:30)
        for (i,p) in places.enumerated() {
            let source=AVURLAsset(url:URL(fileURLWithPath:p.clip.path))
            guard let v=source.tracks(withMediaType:.video).first,
                  let target=asset.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw SubtitleError.invalid(L("找不到视频：{0}", [String(describing: p.clip.path)])) }
            if i==0,v.minFrameDuration.isValid,CMTimeGetSeconds(v.minFrameDuration)>0 { frameDuration=v.minFrameDuration }
            let sourceRange=CMTimeRange(start:CMTime(value:p.clip.sourceStart,timescale:1000),duration:CMTime(value:p.clip.duration,timescale:1000))
            let range=CMTimeRangeGetIntersection(sourceRange,otherRange:v.timeRange)
            guard range.isValid,CMTimeGetSeconds(range.duration)>0 else { throw SubtitleError.invalid(L("所选区间没有可用视频画面")) }
            let destination=CMTime(value:p.start,timescale:1000)
            let leading=CMTimeSubtract(range.start,sourceRange.start)
            let trailing=CMTimeSubtract(CMTimeRangeGetEnd(sourceRange),CMTimeRangeGetEnd(range))
            let sampleDuration=CMTimeMinimum(range.duration,frameDuration)
            func holdFrame(sourceStart: CMTime,at position: CMTime,duration: CMTime) throws {
                guard CMTimeGetSeconds(duration)>0 else { return }
                try target.insertTimeRange(CMTimeRange(start:sourceStart,duration:sampleDuration),of:v,at:position)
                target.scaleTimeRange(CMTimeRange(start:position,duration:sampleDuration),toDuration:duration)
            }
            try holdFrame(sourceStart:range.start,at:destination,duration:leading)
            try target.insertTimeRange(range,of:v,at:CMTimeAdd(destination,leading))
            try holdFrame(sourceStart:CMTimeSubtract(CMTimeRangeGetEnd(range),sampleDuration),at:CMTimeAdd(CMTimeAdd(destination,leading),range.duration),duration:trailing)
            let outgoing=i+1<places.count ? places[i+1].clip.transition : 0
            layers.append(RenderLayer(trackID:target.trackID,transform:v.preferredTransform,placement:p,outgoing:outgoing))
            if let a=source.tracks(withMediaType:.audio).first,let at=asset.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) {
                let r=CMTimeRangeGetIntersection(sourceRange,otherRange:a.timeRange)
                if CMTimeGetSeconds(r.duration)>0 {
                    try at.insertTimeRange(r,of:a,at:CMTimeAdd(CMTime(value:p.start,timescale:1000),CMTimeSubtract(r.start,sourceRange.start)))
                    let param=AVMutableAudioMixInputParameters(track:at)
                    let fadeIn=max(p.clip.transition,p.clip.effects.fadeIn),fadeOut=max(outgoing,p.clip.effects.fadeOut)
                    param.setVolume(1,at:CMTime(value:p.start,timescale:1000))
                    if fadeIn>0 { param.setVolumeRamp(fromStartVolume:0,toEndVolume:1,timeRange:CMTimeRange(start:CMTime(value:p.start,timescale:1000),duration:CMTime(value:fadeIn,timescale:1000))) }
                    if fadeOut>0 { param.setVolumeRamp(fromStartVolume:1,toEndVolume:0,timeRange:CMTimeRange(start:CMTime(value:p.end-fadeOut,timescale:1000),duration:CMTime(value:fadeOut,timescale:1000))) }
                    parameters.append(param)
                }
            }
        }
        audio.inputParameters=parameters
        video.customVideoCompositorClass=EditCompositor.self
        video.renderSize=size; video.frameDuration=frameDuration
        video.colorPrimaries=color.primaries; video.colorTransferFunction=color.transfer; video.colorYCbCrMatrix=color.matrix
        let boundaries=Set(places.flatMap{[$0.start,$0.end]}).sorted()
        video.instructions=zip(boundaries,boundaries.dropFirst()).map { a,b in
            EditInstruction(start:a,end:b,layers:layers.filter{$0.placement.start<=a && $0.placement.end>a},project:project,color:color,subtitles:subtitles)
        }
    }
    func playerItem() -> AVPlayerItem {
        let item=AVPlayerItem(asset:asset); item.videoComposition=video; item.audioMix=audio; return item
    }
}
/// Float compositing retains values above SDR white until the final output conversion.
final class EditCompositor: NSObject, AVVideoCompositing {
    var supportsHDRSourceFrames: Bool { true }
    var supportsWideColorSourceFrames: Bool { true }
    var sourcePixelBufferAttributes: [String:Any]? { [kCVPixelBufferPixelFormatTypeKey as String:[kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,kCVPixelFormatType_32BGRA]] }
    var requiredPixelBufferAttributesForRenderContext: [String:Any] { [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_64RGBAHalf,kCVPixelBufferMetalCompatibilityKey as String:true] }
    private let queue=DispatchQueue(label:"studio.edit.compositor")
    private let context=CIContext(options:[.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearITUR_2020)!, .workingFormat:CIFormat.RGBAh,.cacheIntermediates:false])
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { autoreleasepool {
            guard let instruction=request.videoCompositionInstruction as? EditInstruction,let target=request.renderContext.newPixelBuffer() else { request.finish(with:SubtitleError.invalid(L("无法创建合成画面"))); return }
            let size=request.renderContext.size,bounds=CGRect(origin:.zero,size:size)
            let ms=Int64(CMTimeGetSeconds(request.compositionTime)*1000)
            var result=CIImage(color:CIColor(red:0,green:0,blue:0)).cropped(to:bounds)
            for layer in instruction.layers {
                guard let buffer=request.sourceFrame(byTrackID:layer.trackID) else { request.finish(with:SubtitleError.invalid(L("读取视频片段失败"))); return }
                let flip=CGAffineTransform(scaleX:1,y:-1)
                var frame=CIImage(cvPixelBuffer:buffer).transformed(by:flip).transformed(by:layer.transform).transformed(by:flip)
                frame=frame.transformed(by:CGAffineTransform(translationX:-frame.extent.minX,y:-frame.extent.minY))
                let scale=min(size.width/frame.extent.width,size.height/frame.extent.height)
                frame=frame.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
                frame=frame.transformed(by:CGAffineTransform(translationX:(size.width-frame.extent.width)/2,y:(size.height-frame.extent.height)/2))
                let e=layer.placement.clip.effects,elapsed=ms-layer.placement.start,remaining=layer.placement.end-ms
                if e.brightness != 0 || e.contrast != 1 || e.saturation != 1 {
                    frame=frame.applyingFilter("CIColorControls",parameters:[kCIInputBrightnessKey:e.brightness,kCIInputContrastKey:e.contrast,kCIInputSaturationKey:e.saturation])
                }
                let sourceTime=layer.placement.clip.sourceStart+elapsed
                frame=VideoRegionRenderer.apply(to:frame,clip:layer.placement.clip,sourceTime:sourceTime,size:size)
                // Only the incoming image fades in for a dissolve; the outgoing image remains opaque underneath.
                var alpha=1.0
                if layer.placement.clip.transition>0 { alpha=min(alpha,Double(elapsed)/Double(layer.placement.clip.transition)) }
                if e.fadeIn>0 { alpha=min(alpha,Double(elapsed)/Double(e.fadeIn)) }
                if e.fadeOut>0 { alpha=min(alpha,Double(remaining)/Double(e.fadeOut)) }
                frame=frame.composited(over:CIImage(color:CIColor(red:0,green:0,blue:0)).cropped(to:bounds))
                if alpha<1 { frame=frame.applyingFilter("CIColorMatrix",parameters:["inputAVector":CIVector(x:0,y:0,z:0,w:max(0,alpha))]) }
                result=frame.composited(over:result)
            }
            if instruction.subtitles,!instruction.project.active(at:ms).isEmpty {
                guard let cg=CGContext(data:nil,width:Int(size.width),height:Int(size.height),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { request.finish(with:SubtitleError.invalid(L("无法绘制字幕"))); return }
                SubtitleRenderer.draw(project:instruction.project,at:ms,size:size,context:cg)
                if let image=cg.makeImage() { result=CIImage(cgImage:image).composited(over:result) }
            }
            self.context.render(result,to:target,bounds:bounds,colorSpace:instruction.color.space)
            CVBufferSetAttachment(target,kCVImageBufferColorPrimariesKey,instruction.color.primaries as CFString,.shouldPropagate)
            CVBufferSetAttachment(target,kCVImageBufferTransferFunctionKey,instruction.color.transfer as CFString,.shouldPropagate)
            CVBufferSetAttachment(target,kCVImageBufferYCbCrMatrixKey,instruction.color.matrix as CFString,.shouldPropagate)
            request.finish(withComposedVideoFrame:target)
        } }
    }
    func cancelAllPendingVideoCompositionRequests() { queue.sync {} }
}

/// Solid-background text removal; this does not reconstruct textured or moving scenery.
enum VideoRegionRenderer {
    static func apply(to image: CIImage,clip: VideoClip,sourceTime: Int64,size: CGSize) -> CIImage {
        var result=image
        for region in clip.eraseRegions ?? [] where region.sourceStart<=sourceTime && sourceTime<region.sourceEnd {
            let box=CGRect(x:region.x*size.width,y:region.y*size.height,width:region.width*size.width,height:region.height*size.height)
            let fill: CIImage
            if let color=region.color {
                fill=CIImage(color:CIColor(color:color.ns)!).cropped(to:box)
            } else {
                // Keep a thin blank border inside the selection for reliable auto sampling.
                let inset=min(2,box.width/4),stripHeight=min(3,max(1,box.height*0.04))
                let strip=CGRect(x:box.minX+inset,y:box.minY+min(1,box.height/8),width:max(1,box.width-2*inset),height:stripHeight).intersection(image.extent)
                guard !strip.isNull,!strip.isEmpty else { continue }
                fill=image.applyingFilter("CIAreaAverage",parameters:[kCIInputExtentKey:CIVector(cgRect:strip)]).clampedToExtent().cropped(to:box)
            }
            result=fill.composited(over:result)
        }
        return result
    }
}
