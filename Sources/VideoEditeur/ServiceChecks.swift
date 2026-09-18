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
