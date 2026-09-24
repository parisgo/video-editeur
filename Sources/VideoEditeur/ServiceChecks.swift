import Foundation
import AVFoundation
import AppKit
import CoreImage
import SubtitleCore

func runServiceChecks(video: URL, directory: URL) throws {
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    var passed=0
    func require(_ condition: Bool,_ name: String) throws { guard condition else { throw SubtitleError.invalid("CHECK_FAILED: \(name)") }; passed+=1; print("PASS \(name)") }
    let tools=ToolSettings(ffmpeg:"/missing/ffmpeg",python:"/usr/bin/true",codex:"/usr/bin/false",skill:directory.path)
    do { try tools.validate(); throw SubtitleError.invalid("missing dependency accepted") } catch { try require(error.localizedDescription.contains("ffmpeg"),"Missing dependency reports tool name") }
    let runner=CommandRunner(); let started=Date()
    DispatchQueue.global().asyncAfter(deadline:.now()+0.15) { runner.cancel() }
    do { _=try runner.run("/bin/sleep",["10"],directory:directory); throw SubtitleError.invalid("cancel accepted") }
    catch { try require(runner.isCancelled && Date().timeIntervalSince(started)<4,"Cancellation stops subprocess") }
    let timeout=CommandRunner()
    do { _=try timeout.run("/bin/sleep",["10"],directory:directory,timeout:0.1); throw SubtitleError.invalid("timeout accepted") }
    catch { try require(error.localizedDescription.contains("超时"),"Subprocess timeout is actionable") }
    let jobDir=directory.appendingPathComponent("job")
    try FileManager.default.createDirectory(at:jobDir.appendingPathComponent("scripts"),withIntermediateDirectories:true)
    try "Translate into Chinese".write(to:jobDir.appendingPathComponent("SKILL.md"),atomically:true,encoding:.utf8)
    try "# test fixture".write(to:jobDir.appendingPathComponent("scripts/transcribe_srt.py"),atomically:true,encoding:.utf8)
    let source=[Cue(language:.fr,start:0,end:1000,text:"Bonjour"),Cue(language:.fr,start:1000,end:2000,text:"Merci")]
    try JSONEncoder().encode(source).write(to:jobDir.appendingPathComponent("source.json"))
    let fixtureTools=ToolSettings(ffmpeg:"/usr/bin/true",python:"/usr/bin/true",codex:"/usr/bin/false",skill:jobDir.path)
    var partial: [Cue]=[]
    do { _=try GenerationJob(directory:jobDir,tools:fixtureTools).run(video:video,duration:3000,status:{_ in},partial:{partial=$0}); throw SubtitleError.invalid("translation should fail") }
    catch { try require(partial == source && error.localizedDescription.contains("false"),"Translation failure preserves completed French cues") }
    let translations=[Translation(id:source[0].id,text:"你好"),Translation(id:source[1].id,text:"谢谢")]
    let json=try JSONSerialization.data(withJSONObject:["translations":translations.map { ["id":$0.id.uuidString,"text":$0.text] }])
    try json.write(to:jobDir.appendingPathComponent("batch-0.json"))
    let result=try GenerationJob(directory:jobDir,tools:fixtureTools).run(video:video,duration:3000,status:{_ in},partial:{_ in})
    try require(result.count == 4 && result[2].text == "你好","Retry uses completed transcription and translation checkpoint")
    let asset=AVURLAsset(url:video); var project=Project(); project.videoPath=video.path; project.duration=Int64(CMTimeGetSeconds(asset.duration)*1000)
    project.cues=[Cue(language:.zh,start:0,end:project.duration,text:"取消测试")]
    let protected=directory.appendingPathComponent("cancelled.mp4"),original=Data("existing destination".utf8)
    try original.write(to:protected)
    let exporter=VideoExporter()
    do { try exporter.run(project:project,destination:protected) { value in if value>0 { exporter.cancel() } }; throw SubtitleError.invalid("export cancel should fail") }
    catch { try require(error.localizedDescription.contains("取消"),"Export cancellation exits cleanly") }
    try require(try Data(contentsOf:protected) == original,"Cancelled export preserves existing destination")
    let leftovers=try FileManager.default.contentsOfDirectory(atPath:directory.path).filter{$0.hasPrefix(".") && $0.hasSuffix(".mp4")}
    try require(leftovers.isEmpty,"Cancelled export removes temporary movie")
    do { try VideoExporter().run(project:project,destination:video) {_ in}; throw SubtitleError.invalid("source overwrite should fail") }
    catch { try require(error.localizedDescription.contains("不能覆盖"),"Source video overwrite is rejected") }
    print("SERVICE_CHECKS_OK \(passed)")
}

func runEditingChecks(directory: URL) throws {
    let a=directory.appendingPathComponent("a.mp4"),b=directory.appendingPathComponent("b.mp4")
    var project=Project()
    var first=VideoClip(path:a.path,duration:try MediaProbe(a.path).duration)
    var second=VideoClip(path:b.path,duration:try MediaProbe(b.path).duration)
    first.sourceStart=500; first.effects.fadeIn=300; first.effects.saturation=0.6
    second.transition=500; second.effects.fadeOut=300
    project=try project.replacingClips([first,second])
    project.cues=[Cue(language:.zh,start:0,end:project.duration,text:"多视频测试"),Cue(language:.fr,start:0,end:project.duration,text:"Bonjour, montage !")]
    try project.write(directory.appendingPathComponent("editing.frzh"))
    try VideoExporter().run(project:project,destination:directory.appendingPathComponent("edited.mp4")) {_ in}
    guard project.duration == first.duration+second.duration-500 else { throw SubtitleError.invalid("incorrect edit duration") }
    print("PASS multi-clip effects and dissolve export")
    let job=GenerationJob(directory:directory.appendingPathComponent("audio-"+UUID().uuidString))
    let mixedAudio=try EditorController().prepareTranscriptionInput(project:project,job:job)
    let audioAsset=AVURLAsset(url:mixedAudio)
    guard abs(CMTimeGetSeconds(audioAsset.duration)-Double(project.duration)/1000)<0.15 else { throw SubtitleError.invalid("mixed transcription audio duration mismatch") }
    print("PASS transcription uses edited mixed audio")
    for (file,color) in [("hlg",VideoColor.hlg),("pq",VideoColor.pq)] {
        let source=directory.appendingPathComponent(file+".mp4")
        let info=try MediaProbe(source.path)
        guard info.color == color else { throw SubtitleError.invalid("HDR detection failed") }
        var hdr=Project(); hdr.videoPath=source.path; hdr.duration=info.duration
        hdr.cues=[Cue(language:.zh,start:0,end:hdr.duration,text:"HDR 字幕测试")]
        try VideoExporter().run(project:hdr,destination:directory.appendingPathComponent(file+"-out.mp4"),color:color) {_ in}
        print("PASS \(file) 10-bit export")
        try VideoExporter().run(project:hdr,destination:directory.appendingPathComponent(file+"-sdr.mp4")) {_ in}
        var mixed=project; mixed=try mixed.replacingClips([first,VideoClip(path:source.path,duration:info.duration)])
        guard try MediaProbe.formats(mixed).0 == [.sdr] else { throw SubtitleError.invalid("Mixed HDR unexpectedly offered") }
        print("PASS mixed color limits HDR output")
    }
}

func runRegionEraseChecks(source: URL,destination: URL) throws {
    let blue=CIImage(color:CIColor(red:0,green:0,blue:1)).cropped(to:CGRect(x:0,y:0,width:100,height:100))
    let white=CIImage(color:CIColor(red:1,green:1,blue:1)).cropped(to:CGRect(x:20,y:20,width:60,height:20)).composited(over:blue)
    var clip=VideoClip(path:source.path,duration:2000)
    clip.eraseRegions=[VideoEraseRegion(x:0.1,y:0.1,width:0.8,height:0.4,sourceStart:500,sourceEnd:1500)]
    let context=CIContext()
    func pixel(_ image: CIImage) -> [UInt8] {
        var bytes=[UInt8](repeating:0,count:4)
        context.render(image,toBitmap:&bytes,rowBytes:4,bounds:CGRect(x:40,y:30,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
        return bytes
    }
    let automatic=pixel(VideoRegionRenderer.apply(to:white,clip:clip,sourceTime:1000,size:CGSize(width:100,height:100)))
    guard automatic[0]<5,automatic[1]<5,automatic[2]>250 else { throw SubtitleError.invalid("Automatic background sample mismatch: \(automatic)") }
    let inactive=pixel(VideoRegionRenderer.apply(to:white,clip:clip,sourceTime:1600,size:CGSize(width:100,height:100)))
    guard inactive[0]>250,inactive[1]>250 else { throw SubtitleError.invalid("Region time range failed") }
    clip.eraseRegions?[0].color=RGBA(1,0,0)
    let manual=pixel(VideoRegionRenderer.apply(to:white,clip:clip,sourceTime:1000,size:CGSize(width:100,height:100)))
    guard manual[0]>250,manual[1]<5,manual[2]<5 else { throw SubtitleError.invalid("Manual fill mismatch") }
    print("PASS automatic background, manual fill and time window")
    let probe=try MediaProbe(source.path); clip=VideoClip(path:source.path,duration:probe.duration)
    clip.eraseRegions=[VideoEraseRegion(x:90.0/640,y:90.0/360,width:420.0/640,height:80.0/360,sourceStart:0,sourceEnd:probe.duration)]
    var project=try Project().replacingClips([clip])
    project.cues=[Cue(language:.zh,start:0,end:project.duration,text:"新增字幕保留")]
    try VideoExporter().run(project:project,destination:destination){_ in}
    print("PASS region erase export")
}

func runSubtitleAlignmentChecks() throws {
    for alignment in SubtitleAlignment.allCases {
        var project=Project(); project.duration=2000
        var style=SubtitleStyle(); style.width=0.8; style.alignment=alignment
        let cue=Cue(language:.fr,start:0,end:2000,text:"Bonjour docteur,\nComment allez-vous ?",style:style)
        project.cues=[cue]
        let (text,rect,pad)=SubtitleRenderer.box(cue:cue,project:project,size:CGSize(width:1920,height:1080))
        let background=SubtitleRenderer.backgroundRect(text:text,rect:rect,pad:pad)
        let paragraph=text.attribute(.paragraphStyle,at:0,effectiveRange:nil) as? NSParagraphStyle
        let expected: NSTextAlignment=alignment == .left ? .left : (alignment == .right ? .right : .center)
        let delta=alignment == .left ? background.minX-rect.minX : (alignment == .right ? background.maxX-rect.maxX : background.midX-rect.midX)
        guard paragraph?.alignment == expected,abs(delta)<0.01,background.width<rect.width else { throw SubtitleError.invalid("字幕对齐校验失败：\(alignment)") }
        print("PASS subtitle layout and fitted background: \(alignment)")
    }
}

func runRegionColorChecks() throws {
    let lower=CIImage(color:CIColor(red:1,green:0,blue:0)).cropped(to:CGRect(x:0,y:0,width:100,height:50))
    let upper=CIImage(color:CIColor(red:0,green:0,blue:1)).cropped(to:CGRect(x:0,y:50,width:100,height:50))
    let image=upper.composited(over:lower)
    let red=RegionColorSampler.sample(image,at:CGPoint(x:0,y:0))
    let blue=RegionColorSampler.sample(image,at:CGPoint(x:1,y:1))
    guard red.r>0.99,red.b<0.01,blue.b>0.99,blue.r<0.01,red.a==1,blue.a==1 else { throw SubtitleError.invalid("Point color orientation / bounds check failed") }
    print("PASS drag-start pixel color, bottom-left coordinates and edge clamping")
}

func runMusicChecks(directory: URL) throws {
    var project=Project(); project.videoPath=directory.appendingPathComponent("video.mp4").path; project.duration=2000
    var music=BackgroundMusic(path:directory.appendingPathComponent("背景 音乐.mp3").path,duration:3000); music.start=500; music.sourceStart=250; music.sourceEnd=2250; music.volume=0.5
    project.backgroundMusic=[music]
    let preview=try EditedAsset(project:project,color:.sdr,subtitles:false)
    guard preview.asset.tracks(withMediaType:.audio).count==2,abs(CMTimeGetSeconds(preview.asset.duration)-2)<0.02 else { throw SubtitleError.invalid("Mixed preview tracks/duration failed") }
    try VideoExporter().run(project:project,destination:directory.appendingPathComponent("mixed.mp4"),progress:{_ in})
    project.muteVideoAudio=true
    let muted=try EditedAsset(project:project,color:.sdr,subtitles:false)
    guard muted.asset.tracks(withMediaType:.audio).count==1 else { throw SubtitleError.invalid("Original video audio was not removed") }
    try VideoExporter().run(project:project,destination:directory.appendingPathComponent("muted.mp4"),progress:{_ in})
    print("PASS music preview mix, clipped duration, original audio mute and both exports")
}

func runMultiTrackChecks(directory: URL) throws {
    let a=directory.appendingPathComponent("a.mp4"),b=directory.appendingPathComponent("b.mp4")
    var p=try Project().replacingClips([VideoClip(path:a.path,duration:2000)])
    var upper=VideoLayer(clip:VideoClip(path:b.path,duration:2000),start:500)
    // Legacy geometry must no longer create a small image.
    upper.x=0.75; upper.y=0.75; upper.scale=0.4
    p=try p.replacingLayers([upper]); p=try p.cuttingLayer(upper.id,at:1500)
    try p.write(directory.appendingPathComponent("multitrack.frzh"))
    func pixel(_ frame:CGImage,_ x:Int,_ y:Int)->[UInt8] {
        var bytes=[UInt8](repeating:0,count:4)
        CIContext().render(CIImage(cgImage:frame),toBitmap:&bytes,rowBytes:4,bounds:CGRect(x:x,y:y,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
        return bytes
    }
    func requireBlue(_ frame:CGImage) throws {
        for point in [(20,20),(160,90),(300,160)] {
            let color=pixel(frame,point.0,point.1)
            guard color[2]>150,color[0]<80 else { throw SubtitleError.invalid("Upper track did not fill canvas: \(color)") }
        }
    }
    let preview=try EditedAsset(project:p,color:.sdr,subtitles:false)
    let generator=AVAssetImageGenerator(asset:preview.asset); generator.videoComposition=preview.video
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    try requireBlue(generator.copyCGImage(at:CMTime(value:1000,timescale:1000),actualTime:nil))
    let outputURL=directory.appendingPathComponent("multitrack.mp4")
    try VideoExporter().run(project:p,destination:outputURL) {_ in}
    let output=AVURLAsset(url:outputURL),images=AVAssetImageGenerator(asset:output)
    images.requestedTimeToleranceBefore = .zero; images.requestedTimeToleranceAfter = .zero
    try requireBlue(images.copyCGImage(at:CMTime(value:2000,timescale:1000),actualTime:nil))
    guard abs(CMTimeGetSeconds(output.duration)-2.5)<0.1 else { throw SubtitleError.invalid("Multitrack output duration failed") }
    let emptyTimeline=TimelineView(frame:NSRect(x:0,y:0,width:900,height:400))
    guard emptyTimeline.subtitleRowCount == 0, emptyTimeline.layerY == 51 else { throw SubtitleError.invalid("Empty subtitle rows should be hidden") }
    emptyTimeline.project.textTracks=[TextTrack(name:"Title")]
    let textCue=Cue(language:.fr,start:0,end:1000,text:"Title",trackID:emptyTimeline.project.tracks[0].id)
    guard emptyTimeline.rect(textCue).minY == 47 else { throw SubtitleError.invalid("Hidden subtitle rows left a gap") }
    emptyTimeline.subtitleTracksRequested=true
    guard emptyTimeline.subtitleRowCount == 2, emptyTimeline.rect(textCue).minY == 135 else { throw SubtitleError.invalid("Generate must reveal subtitle rows") }
    emptyTimeline.subtitleTracksRequested=false
    emptyTimeline.project.cues=[Cue(language:.zh,start:0,end:1000,text:"字幕")]
    guard emptyTimeline.subtitleRowCount == 2 else { throw SubtitleError.invalid("Existing subtitles must remain visible") }
    let timeline=TimelineView(frame:NSRect(x:0,y:0,width:900,height:400)); timeline.project=p; timeline.pointsPerSecond=180
    let window=NSWindow(contentRect:timeline.bounds,styleMask:[.titled],backing:.buffered,defer:false)
    window.contentView=timeline; timeline.layoutSubtreeIfNeeded()
    guard timeline.videoRowY(p.layers[0].id)==timeline.videoRowY(p.layers[1].id) else { throw SubtitleError.invalid("Split moved to another row") }
    let controls=timeline.subviews.compactMap{$0 as? NSButton}.filter{$0.identifier?.rawValue==upper.trackIdentifier.uuidString}.sorted{$0.tag<$1.tag}
    var calls:[Int]=[]
    timeline.toggleLayerTrackControl={ id,control in
        guard id==upper.trackIdentifier else { return }; calls.append(control)
        var values=timeline.project.layers
        for i in values.indices {
            switch control { case 0: values[i].locked=true; case 1: values[i].hidden=true; default: values[i].muted=true }
        }
        timeline.project.videoLayers=values; timeline.layoutSubtreeIfNeeded()
    }
    guard controls.count==3 else { throw SubtitleError.invalid("Multitrack controls missing") }
    for button in controls { button.performClick(nil) }
    guard calls==[0,1,2],controls.allSatisfy({$0.state == .on}) else { throw SubtitleError.invalid("Multitrack controls failed") }
    let hidden=try EditedAsset(project:timeline.project,color:.sdr,subtitles:false)
    guard hidden.asset.tracks(withMediaType:.audio).count==1 else { throw SubtitleError.invalid("Track mute did not affect all clips") }
    let hiddenFrames=AVAssetImageGenerator(asset:hidden.asset); hiddenFrames.videoComposition=hidden.video
    let red=pixel(try hiddenFrames.copyCGImage(at:CMTime(value:1000,timescale:1000),actualTime:nil),160,90)
    guard red[0]>150,red[2]<80 else { throw SubtitleError.invalid("Hidden upper track did not reveal lower video") }
    timeline.project=p; timeline.layoutSubtreeIfNeeded()
    func event(_ type:NSEvent.EventType,_ point:NSPoint)->NSEvent {
        NSEvent.mouseEvent(with:type,location:timeline.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
    }
    var moved:VideoLayer?; timeline.moveVideoLayer={moved=$0}
    timeline.transferVideoClip={id,destination,time in
        moved=(try? timeline.project.transferringClip(id,to:destination,at:time))?.layers.first{$0.id == id}
    }
    let source=NSPoint(x:timeline.x(2000),y:timeline.videoRowY(p.layers[1].id)+35)
    timeline.mouseDown(with:event(.leftMouseDown,source))
    let target=NSPoint(x:source.x+90,y:source.y)
    timeline.mouseDragged(with:event(.leftMouseDragged,target)); timeline.mouseUp(with:event(.leftMouseUp,target))
    guard moved?.start==2000,moved?.trackIdentifier==upper.trackIdentifier else { throw SubtitleError.invalid("Track clip movement failed") }
    let cross=try p.addingLayer(from:p.clips[0].id,at:3000)
    timeline.project=cross; timeline.layoutSubtreeIfNeeded(); moved=nil
    let crossSource=NSPoint(x:timeline.x(2000),y:timeline.videoRowY(p.layers[1].id)+35)
    let crossTarget=NSPoint(x:crossSource.x,y:timeline.videoRowY(cross.layers[0].id)+35)
    timeline.mouseDown(with:event(.leftMouseDown,crossSource))
    timeline.mouseDragged(with:event(.leftMouseDragged,crossTarget)); timeline.mouseUp(with:event(.leftMouseUp,crossTarget))
    guard moved?.trackIdentifier==cross.layers[0].trackIdentifier,moved?.start==1500 else { throw SubtitleError.invalid("Cross-track drag failed") }
    var contextAction:Int?
    timeline.editVideoTrack={_,action in contextAction=action}
    guard let menu=timeline.menu(for:event(.rightMouseDown,NSPoint(x:20,y:crossTarget.y))),menu.items.count==3 else { throw SubtitleError.invalid("Track context menu missing") }
    menu.performActionForItem(at:0)
    guard contextAction==0 else { throw SubtitleError.invalid("Track deletion menu callback failed") }
    let main=try Project().replacingClips([VideoClip(path:a.path,duration:2000),VideoClip(path:b.path,duration:2000)])
    timeline.project=main; timeline.layoutSubtreeIfNeeded()
    var reordered:UUID?; var insertion:Int64?
    timeline.transferVideoClip={id,destination,time in if destination == .main { reordered=id; insertion=time } }
    let mainStart=NSPoint(x:timeline.x(1000),y:timeline.videoY+35),mainEnd=NSPoint(x:timeline.x(6000),y:timeline.videoY+35)
    timeline.mouseDown(with:event(.leftMouseDown,mainStart)); timeline.mouseDragged(with:event(.leftMouseDragged,mainEnd)); timeline.mouseUp(with:event(.leftMouseUp,mainEnd))
    guard reordered==main.clips[0].id,insertion==5000 else { throw SubtitleError.invalid("Main track absolute movement failed") }
    var transferred:Project?; var transferCount=0
    timeline.transferVideoClip={id,destination,time in
        transferred=try? timeline.project.transferringClip(id,to:destination,at:time); transferCount+=1
    }
    timeline.project=main; timeline.layoutSubtreeIfNeeded()
    let existing=try main.addingLayer(from:main.clips[0].id,at:5000)
    timeline.project=existing; timeline.layoutSubtreeIfNeeded()
    let fromMain=NSPoint(x:timeline.x(1000),y:timeline.videoY+35)
    let toUpper=NSPoint(x:fromMain.x,y:timeline.videoRowY(existing.layers[0].id)+35)
    timeline.mouseDown(with:event(.leftMouseDown,fromMain)); timeline.mouseDragged(with:event(.leftMouseDragged,toUpper)); timeline.mouseUp(with:event(.leftMouseUp,toUpper))
    guard let onUpper=transferred,onUpper.layerTracks[0].count==2,onUpper.clips.count==1,onUpper.layers.contains(where:{$0.id==main.clips[0].id}),transferCount==1 else { throw SubtitleError.invalid("Main-to-existing timeline transfer failed") }
    timeline.project=onUpper; timeline.layoutSubtreeIfNeeded(); transferred=nil
    let fromUpper=NSPoint(x:timeline.x(1000),y:timeline.videoRowY(main.clips[0].id)+35)
    let toNew=NSPoint(x:fromUpper.x,y:timeline.newLayerY+20)
    timeline.mouseDown(with:event(.leftMouseDown,fromUpper)); timeline.mouseDragged(with:event(.leftMouseDragged,toNew)); timeline.mouseUp(with:event(.leftMouseUp,toNew))
    guard let onNew=transferred,onNew.layerTracks.count==2,onNew.layers.first?.id==main.clips[0].id,transferCount==2 else { throw SubtitleError.invalid("Timeline new-track transfer failed") }
    timeline.project=onNew; timeline.layoutSubtreeIfNeeded(); transferred=nil
    let backStart=NSPoint(x:timeline.x(1000),y:timeline.videoRowY(main.clips[0].id)+35),backEnd=NSPoint(x:timeline.x(1000),y:timeline.videoY+35)
    timeline.mouseDown(with:event(.leftMouseDown,backStart)); timeline.mouseDragged(with:event(.leftMouseDragged,backEnd)); timeline.mouseUp(with:event(.leftMouseUp,backEnd))
    guard let back=transferred,back.clips.map(\.id)==main.clips.map(\.id),transferCount==3 else { throw SubtitleError.invalid("Timeline transfer back to main failed") }
    timeline.project=back; timeline.layoutSubtreeIfNeeded(); transferred=nil
    let cancelStart=NSPoint(x:timeline.x(1000),y:timeline.videoY+35),cancelEnd=NSPoint(x:timeline.x(1000),y:timeline.newLayerY+20)
    timeline.mouseDown(with:event(.leftMouseDown,cancelStart)); timeline.mouseDragged(with:event(.leftMouseDragged,cancelEnd)); timeline.cancelOperation(nil); timeline.mouseUp(with:event(.leftMouseUp,cancelEnd))
    guard transferred==nil,transferCount==3 else { throw SubtitleError.invalid("Cancelled timeline transfer committed") }
    print("PASS main/existing/new track transfers, stable clip IDs, single completion and Esc cancellation")
    let delayed=try Project().replacingClips([VideoClip(path:a.path,duration:2000)])
    let delayedProject=try delayed.movingMainClip(delayed.clips[0].id,to:5000)
    let delayedURL=directory.appendingPathComponent("delayed-main.mp4")
    try VideoExporter().run(project:delayedProject,destination:delayedURL) {_ in}
    let delayedAsset=AVURLAsset(url:delayedURL),delayedFrames=AVAssetImageGenerator(asset:AVURLAsset(url:delayedURL))
    delayedFrames.requestedTimeToleranceBefore = .zero; delayedFrames.requestedTimeToleranceAfter = .zero
    let empty=pixel(try delayedFrames.copyCGImage(at:CMTime(value:1000,timescale:1000),actualTime:nil),160,90)
    let filled=pixel(try delayedFrames.copyCGImage(at:CMTime(value:5500,timescale:1000),actualTime:nil),160,90)
    guard empty.prefix(3).allSatisfy({$0<15}),filled[0]>150,filled[2]<80,abs(CMTimeGetSeconds(delayedAsset.duration)-7)<0.1 else { throw SubtitleError.invalid("Delayed main video export timing failed") }
    timeline.project=try cross.movingMainClip(cross.clips[0].id,to:5000); timeline.layoutSubtreeIfNeeded()
    if let bitmap=timeline.bitmapImageRepForCachingDisplay(in:timeline.bounds) {
        timeline.cacheDisplay(in:timeline.bounds,to:bitmap)
        try bitmap.representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent("tracks-"+InterfaceLanguage.current.rawValue+".png"))
    }
    print("MULTITRACK_CHECKS_OK full-canvas preview/export, split row, track controls, mute, hide, timeline movement, cross-track drag, track menu and main movement to 5 seconds with leading black export")
}

// Uses temporary project files; never touches the user's recovery or saved projects.
func runCloseChecks() throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:directory) }
    let editor=EditorController(); _=editor.view
    guard !editor.needsSaveBeforeClosing else { throw SubtitleError.invalid("Blank project should close directly") }
    editor.project.videoPath=directory.appendingPathComponent("source.mp4").path
    editor.project.duration=2000
    guard editor.needsSaveBeforeClosing else { throw SubtitleError.invalid("New project must prompt") }
    let url=directory.appendingPathComponent("Saved.frzh")
    try editor.project.write(url); editor.projectURL=url
    guard !editor.needsSaveBeforeClosing else { throw SubtitleError.invalid("Saved project should close directly") }
    editor.project.cues=[Cue(language:.zh,start:0,end:1000,text:"未保存")]
    guard editor.needsSaveBeforeClosing else { throw SubtitleError.invalid("Edited project must prompt") }
    for (response,expected) in [(NSApplication.ModalResponse.alertThirdButtonReturn,false),(.alertSecondButtonReturn,true)] {
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { NSApp.stopModal(withCode:response) }
        guard editor.confirmSaveBeforeClosing() == expected else { throw SubtitleError.invalid("Close confirmation response failed") }
    }
    guard try Project.read(url).cues.isEmpty else { throw SubtitleError.invalid("Discard changed saved file") }
    try editor.project.write(url)
    guard !editor.needsSaveBeforeClosing else { throw SubtitleError.invalid("Saving must clear pending changes") }
    print("CLOSE_OK blank, new, saved, modified, cancel, discard and saved-file preservation")
}
