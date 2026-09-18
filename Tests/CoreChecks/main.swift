import Foundation
import CoreGraphics
import SubtitleCore
var failures=0, passed=0
func check(_ name: String,_ body: () throws -> Bool) {
    do { if try body() { passed+=1; print("PASS \(name)") } else { failures+=1; print("FAIL \(name)") } }
    catch { failures+=1; print("FAIL \(name): \(error)") }
}
func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
let fr="1\r\n00:00:00,000 --> 00:00:01,500\r\nBonjour\r\n\r\n2\r\n00:00:01,500 --> 00:00:03,000\r\nUne histoire\r\n"
let cues=try SRT.parse(fr,language:.fr)
check("SRT CRLF and touching boundaries") { cues.count == 2 && cues[1].start == 1500 }
check("SRT round trip") { let decoded=try SRT.parse(SRT.encode(cues),language:.fr); return decoded.map(\.text) == cues.map(\.text) && decoded.map(\.end) == cues.map(\.end) }
check("BOM and Chinese single line") { let c=try SRT.parse("\u{FEFF}1\n00:00:00,000 --> 00:00:01,000\n你好\n世界\n",language:.zh); return c[0].text == "你好，世界" }
check("Reject malformed time") { rejects { _ = try SRT.time("00:61:00,000") } }
check("Reject overlapping SRT") { rejects { _ = try SRT.parse(fr.replacingOccurrences(of:"00:00:01,500 -->",with:"00:00:01,000 -->"),language:.fr) } }
check("Reject reversed interval") { rejects { _ = try SRT.parse("1\n00:00:02,000 --> 00:00:01,000\nX",language:.fr) } }
check("SRT hour formatting") { SRT.timestamp(3_661_007) == "01:01:01,007" }
var p=Project(); p.duration=5000; p.cues=cues
check("Active end is exclusive") { p.active(at:1500).count == 1 && p.active(at:1500)[0].text == "Une histoire" }
check("Add clipped at video end") { let c=try p.newCue(language:.zh,at:4500); return c.end == 5000 }
check("Add clips to next subtitle") { var q=p; q.cues=[Cue(language:.zh,start:1000,end:2000,text:"已有")]; return try q.newCue(language:.zh,at:500).end == 1000 }
check("Reject add in occupied interval") { rejects { _ = try p.newCue(language:.fr,at:1000) } }
check("Reject add at end") { rejects { _ = try p.newCue(language:.zh,at:5000) } }
check("Track edit range") { p.allowedRange(for:cues[1]) == 1500...5000 }
check("Language visibility") { var q=p; q.showFrench=false; return q.active(at:500).isEmpty }
check("Project detects duplicate IDs") { var q=p; q.cues.append(cues[0]); return rejects { try q.validate() } }
check("Project rejects unsupported version") { var q=p; q.version=99; return rejects { try q.validate() } }
check("Project rejects off-video cue") { var q=p; q.cues[1].end=6000; return rejects { try q.validate() } }
check("Project style override and round trip") {
    var q=p; var s=SubtitleStyle.standard(.zh); s.font="Helvetica"; s.x=0.3; s.color=RGBA(0.2,0.4,0.6); q.cues[0].style=s
    let url=FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).frzh"); defer { try? FileManager.default.removeItem(at:url) }
    try q.write(url); let loaded=try Project.read(url); return loaded == q && loaded.style(for:loaded.cues[0]) == s
}
check("Translation reorders by ID preserving times") {
    let result=try Translator.merge([Translation(id:cues[1].id,text:"一个故事"),Translation(id:cues[0].id,text:"你好\n朋友")],source:cues)
    return result[0].text == "你好，朋友" && result[1].start == 1500 && result.allSatisfy{$0.language == .zh}
}
check("Translation rejects missing IDs") { rejects { _ = try Translator.merge([Translation(id:cues[0].id,text:"你好")],source:cues) } }
check("Translation rejects duplicate IDs") { rejects { _ = try Translator.merge([Translation(id:cues[0].id,text:"你好"),Translation(id:cues[0].id,text:"你好")],source:cues) } }
check("Translation rejects untranslated French") { rejects { _ = try Translator.merge(cues.map { Translation(id:$0.id,text:$0.text) },source:cues) } }
check("Punctuation cue does not reject a translated batch") {
    let source=[Cue(language:.fr,start:0,end:1000,text:"Bonjour"),Cue(language:.fr,start:1000,end:1500,text:"?")]
    let result=try Translator.merge([Translation(id:source[0].id,text:"你好"),Translation(id:source[1].id,text:"？")],source:source)
    return result.count == 2 && result[1].text == "？" && result[1].start == 1000 && result[1].end == 1500
}
check("Numeric cue allows equivalent full-width digits") {
    let cue=Cue(language:.fr,start:0,end:1000,text:"2026")
    return try Translator.merge([Translation(id:cue.id,text:"２０２６")],source:[cue])[0].text == "２０２６"
}
check("Numeric cue rejects changed digits") {
    let cue=Cue(language:.fr,start:0,end:1000,text:"2026")
    return rejects { _=try Translator.merge([Translation(id:cue.id,text:"2025")],source:[cue]) }
}
check("French words cannot be replaced with punctuation") {
    return rejects { _=try Translator.merge(cues.map{Translation(id:$0.id,text:"？")},source:cues) }
}
check("Punctuation source still rejects blank output") {
    let cue=Cue(language:.fr,start:0,end:1000,text:"?")
    return rejects { _=try Translator.merge([Translation(id:cue.id,text:" \n ")],source:[cue]) }
}
check("Nonverbal normalization preserves multiline cue punctuation") {
    let cue=Cue(language:.fr,start:0,end:1000,text:"?\n!")
    return try Translator.merge([Translation(id:cue.id,text:"？！")],source:[cue]).count == 1
}
check("Language switches filter both displayed and active cues") {
    var q=Project(); q.duration=3000
    q.cues=[Cue(language:.zh,start:0,end:1000,text:"你好"),Cue(language:.fr,start:0,end:1000,text:"Bonjour")]
    for (fr,zh,expected) in [(true,false,[Language.fr]),(false,true,[Language.zh]),(true,true,[Language.fr,.zh]),(false,false,[])] {
        q.showFrench=fr; q.showChinese=zh
        if q.displayedCues.map(\.language) != expected || q.active(at:500).map(\.language) != expected { return false }
    }
    return true
}
check("Playback following changes only at cue boundaries and clears gaps") {
    var q=Project(); q.duration=3000
    q.cues=[Cue(language:.fr,start:0,end:1000,text:"Bonjour"),Cue(language:.zh,start:0,end:1000,text:"你好"),Cue(language:.zh,start:1500,end:2500,text:"再见")]
    return q.active(at:999).count == 2 && q.active(at:1000).isEmpty && q.active(at:1499).isEmpty && q.active(at:1500).map(\.text) == ["再见"] && q.active(at:2500).isEmpty
}
check("Track style applies to every cue and clears old overrides") {
    var q=Project(); q.duration=5000
    var old=SubtitleStyle.standard(.fr); old.size=80
    q.cues=[Cue(language:.fr,start:0,end:1000,text:"Bonjour",style:old),Cue(language:.fr,start:1000,end:2000,text:"Merci"),Cue(language:.zh,start:0,end:2000,text:"你好",style:.standard(.zh))]
    let originals=q.cues, chinese=q.cues[2], oldChineseStyle=q.chineseStyle
    var updated=old; updated.size=64; updated.x=0.2; updated.y=0.6; updated.font="Helvetica"; updated.color=RGBA(1,0,0)
    q.applyStyle(updated,to:.fr)
    return q.cues.prefix(2).allSatisfy{$0.style == nil && q.style(for:$0) == updated} && q.cues[2] == chinese && q.chineseStyle == oldChineseStyle && q.cues.map(\.text) == originals.map(\.text) && q.cues.map(\.start) == originals.map(\.start) && q.cues.map(\.end) == originals.map(\.end) && q.cues.map(\.id) == originals.map(\.id)
}
check("New subtitles inherit edited language style") {
    var q=Project(); q.duration=5000; var style=SubtitleStyle.standard(.zh); style.size=71; style.y=0.3
    q.applyStyle(style,to:.zh)
    let cue=try q.newCue(language:.zh,at:1000)
    return q.style(for:cue) == style
}
check("Corner resizing grows and shrinks consistently at all four corners") {
    let center=CGPoint(x:200,y:150)
    for (dx,dy) in [(-100.0,-20.0),(100,-20),(-100,20),(100,20)] {
        let handle=CGPoint(x:center.x+dx,y:center.y+dy)
        let large=CGPoint(x:center.x+dx*1.5,y:center.y+dy*1.5)
        let small=CGPoint(x:center.x+dx*0.5,y:center.y+dy*0.5)
        if abs(VideoGeometry.resizedFontSize(initial:40,anchor:center,handle:handle,pointer:large)-60)>0.001 { return false }
        if abs(VideoGeometry.resizedFontSize(initial:40,anchor:center,handle:handle,pointer:small)-20)>0.001 { return false }
    }
    return true
}
check("Corner resizing clamps font size and handles degenerate geometry") {
    let center=CGPoint.zero,handle=CGPoint(x:10,y:10)
    return VideoGeometry.resizedFontSize(initial:40,anchor:center,handle:handle,pointer:CGPoint(x:1000,y:1000)) == 200 && VideoGeometry.resizedFontSize(initial:40,anchor:center,handle:handle,pointer:CGPoint(x:-10,y:-10)) == 8 && VideoGeometry.resizedFontSize(initial:40,anchor:center,handle:center,pointer:handle) == 40
}
check("Width drag fixes the opposite edge and allows expansion") {
    let box=CGRect(x:200,y:30,width:400,height:80)
    let left=VideoGeometry.resizedTextBox(box,delta:-100,leftEdge:true,videoWidth:1000)
    let right=VideoGeometry.resizedTextBox(box,delta:100,leftEdge:false,videoWidth:1000)
    return left.minX == 100 && left.maxX == 600 && right.minX == 200 && right.maxX == 700 && left.height == box.height
}
check("Width drag clamps to video bounds and a minimum width") {
    let box=CGRect(x:200,y:30,width:400,height:80)
    return VideoGeometry.resizedTextBox(box,delta:-9999,leftEdge:true,videoWidth:1000).minX == 0 && VideoGeometry.resizedTextBox(box,delta:9999,leftEdge:false,videoWidth:1000).maxX == 1000 && VideoGeometry.resizedTextBox(box,delta:9999,leftEdge:true,videoWidth:1000).width == 100
}
check("Old style JSON without width still decodes") {
    var legacy=SubtitleStyle.standard(.fr); legacy.size=44
    let data=try JSONEncoder().encode(legacy)
    var object=try JSONSerialization.jsonObject(with:data) as! [String:Any]; object.removeValue(forKey:"width")
    let restored=try JSONDecoder().decode(SubtitleStyle.self,from:JSONSerialization.data(withJSONObject:object))
    return restored.width == nil && restored.size == 44
}
check("Width persists and propagates without changing font size") {
    var q=Project(); q.duration=3000; q.cues=[Cue(language:.fr,start:0,end:1000,text:"Bonjour"),Cue(language:.fr,start:1000,end:2000,text:"Merci")]
    var style=q.frenchStyle; style.width=0.97; q.applyStyle(style,to:.fr)
    let restored=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(q)); try restored.validate()
    return restored.cues.allSatisfy{restored.style(for:$0).width == 0.97 && restored.style(for:$0).size == style.size}
}
check("Invalid persisted subtitle width is rejected") {
    var q=Project(); q.duration=1000; q.cues=[Cue(language:.fr,start:0,end:1000,text:"Bonjour")]; q.frenchStyle.width=1.1
    return rejects { try q.validate() }
}
check("Portrait aspect fit") { VideoGeometry.aspectFit(video:CGSize(width:1080,height:1920),container:CGRect(x:0,y:0,width:800,height:600)) == CGRect(x:231.25,y:0,width:337.5,height:600) }
check("Landscape letterboxing") { VideoGeometry.aspectFit(video:CGSize(width:1920,height:1080),container:CGRect(x:0,y:0,width:800,height:600)) == CGRect(x:0,y:75,width:800,height:450) }
check("Subtitle box clamps to visible video") { VideoGeometry.anchoredBox(size:CGSize(width:300,height:100),video:CGSize(width:1080,height:1920),x:1,y:0) == CGRect(x:780,y:0,width:300,height:100) }
if CommandLine.arguments.count == 3 {
    check("Actual cached translation batch") {
        let source=try JSONDecoder().decode([Cue].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        let batch=try JSONDecoder().decode(TranslationBatch.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2])))
        let ids=Set(batch.translations.map(\.id))
        let result=try Translator.merge(batch.translations,source:source.filter{ids.contains($0.id)})
        return result.count == batch.translations.count
    }
}
check("Legacy project without text tracks decodes") {
    let data=try JSONEncoder().encode(p)
    var json=try JSONSerialization.jsonObject(with:data) as! [String:Any]; json.removeValue(forKey:"textTracks")
    let loaded=try JSONDecoder().decode(Project.self,from:JSONSerialization.data(withJSONObject:json))
    try loaded.validate(); return loaded.tracks.isEmpty
}
check("Text tracks overlap languages but not their own clips") {
    var q=p; let t=TextTrack(name:"说明"); q.textTracks=[t]
    let c=try q.newCue(language:.zh,at:0,trackID:t.id); q.cues.append(c)
    try q.validate()
    return rejects { _=try q.newCue(language:.zh,at:500,trackID:t.id) } && q.allowedRange(for:c) == 0...5000
}
check("Independent text tracks remain visible without subtitles") {
    var q=p; let a=TextTrack(name:"标题"),b=TextTrack(name:"说明"); q.textTracks=[a,b]
    q.cues.append(try q.newCue(language:.zh,at:0,trackID:a.id)); q.cues.append(try q.newCue(language:.zh,at:0,trackID:b.id))
    q.showFrench=false; q.showChinese=false; try q.validate()
    return q.active(at:0).count == 2 && q.active(at:2000).isEmpty
}
check("Text style is isolated and persists with track IDs") {
    var q=p; let t=TextTrack(name:"说明"); q.textTracks=[t]
    let c=try q.newCue(language:.zh,at:0,trackID:t.id); q.cues.append(c)
    var style=SubtitleStyle(); style.size=72; style.y=0.7
    q.applyStyle(style,for:c)
    q.applyStyle(SubtitleStyle.standard(.zh),to:.zh)
    let decoded=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(q)); try decoded.validate()
    return decoded == q && decoded.style(for:c) == style && decoded.frenchStyle == p.frenchStyle
}
check("Text clip boundary and missing track validation") {
    var q=p; let t=TextTrack(name:"说明"); q.textTracks=[t]
    let c=try q.newCue(language:.zh,at:4500,trackID:t.id); q.cues.append(c)
    q.textTracks=[]
    return c.end == 5000 && rejects { try q.validate() }
}
check("Readability defaults protect light text, preserve dark backed text") {
    SubtitleStyle.standard(.fr).enhancesReadability && !SubtitleStyle.standard(.zh).enhancesReadability
}
check("Readability preference persists and can be disabled") {
    var style=SubtitleStyle.standard(.fr); style.readability=false
    let loaded=try JSONDecoder().decode(SubtitleStyle.self,from:JSONEncoder().encode(style))
    return !loaded.enhancesReadability && loaded == style
}

check("Legacy video becomes one non-destructive clip") {
    var p=Project(); p.videoPath="/video.mp4"; p.duration=4000
    return p.clips.count == 1 && p.clips[0].duration == 4000 && p.placements[0].start == 0
}
check("Append, trim and reorder carry captions with source") {
    var p=Project(); p.videoPath="/a.mp4"; p.duration=4000
    p.cues=[Cue(language:.zh,start:1500,end:2500,text:"原字幕")]
    var a=p.clips[0]; a.sourceStart=1000
    let b=VideoClip(path:"/b.mp4",duration:3000)
    let trimmed=try p.replacingClips([a,b])
    let reordered=try trimmed.replacingClips([b,a])
    return trimmed.duration == 6000 && trimmed.cues[0].start == 500 && reordered.cues[0].start == 3500
}
check("Split preserves source boundaries and splits crossing caption IDs") {
    var p=Project(); p.videoPath="/a.mp4"; p.duration=4000
    p.cues=[Cue(language:.fr,start:1000,end:3000,text:"Bonjour")]
    let q=try p.splittingClip(p.clips[0].id,at:2000)
    return q.duration == 4000 && q.clips.count == 2 && q.clips[1].sourceStart == 2000 && q.cues.count == 2 && Set(q.cues.map(\.id)).count == 2 && q.cues.map{$0.end-$0.start}.reduce(0,+) == 2000
}
check("Dissolve shortens timeline without overlapping captions") {
    var p=Project(); p.videoPath="/a.mp4"; p.duration=4000
    let a=p.clips[0]; var b=VideoClip(path:"/b.mp4",duration:4000)
    p=try p.replacingClips([a,b]); p.cues=[Cue(language:.zh,start:0,end:4000,text:"一"),Cue(language:.zh,start:4000,end:8000,text:"二")]
    b.transition=1000; let q=try p.replacingClips([a,b]); try q.validate()
    return q.duration == 7000 && q.cues[0].end == 3500 && q.cues[1].start == 3500
}
check("Clip edits reject invalid source bounds and excessive transitions") {
    var p=Project(); var c=VideoClip(path:"a.mp4",duration:4000); c.sourceEnd=5000
    let bounds=rejects{_ = try p.replacingClips([c])}
    c.sourceEnd=4000; c.transition=1000
    let first=rejects{_ = try p.replacingClips([c])}
    c.transition=0; c.effects.contrast = .nan
    return bounds && first && rejects{_ = try p.replacingClips([c])}
}
check("Clip effects and source trims persist; old JSON remains readable") {
    var p=Project(); var c=VideoClip(path:"含 空格.mp4",duration:4000); c.sourceStart=1000; c.effects.saturation=0.5
    p=try p.replacingClips([c]); let q=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(p)); try q.validate()
    return q == p && q.clips[0].sourceStart == 1000
}
check("Removing a clip removes its captions and ripples remaining material") {
    var p=Project(); p.videoPath="a.mp4"; p.duration=2000; let a=p.clips[0],b=VideoClip(path:"b.mp4",duration:2000)
    p=try p.replacingClips([a,b]); p.cues=[Cue(language:.zh,start:500,end:1000,text:"一"),Cue(language:.zh,start:2500,end:3000,text:"二")]
    let q=try p.replacingClips([b]); return q.duration == 2000 && q.cues.count == 1 && q.cues[0].text == "二" && q.cues[0].start == 500
}
check("Trim-left button maps source in-point and carries captions") {
    var p=Project(); p.videoPath="a.mp4"; p.duration=4000
    p.cues=[Cue(language:.zh,start:1000,end:3000,text:"中间")]
    let q=try p.trimmingClip(p.clips[0].id,at:2000,removeBefore:true)
    return q.duration == 2000 && q.clips[0].sourceStart == 2000 && q.cues[0].start == 0 && q.cues[0].end == 1000
}
check("Trim-right button clips captions and ripples following video") {
    var p=Project(); p.videoPath="a.mp4"; p.duration=4000
    let a=p.clips[0],b=VideoClip(path:"b.mp4",duration:2000)
    p=try p.replacingClips([a,b]); p.cues=[Cue(language:.fr,start:1000,end:3000,text:"Un"),Cue(language:.fr,start:4500,end:5000,text:"Deux")]
    let q=try p.trimmingClip(a.id,at:2000,removeBefore:false)
    return q.duration == 4000 && q.cues[0].end == 2000 && q.cues[1].start == 2500 && q.placements[1].start == 2000
}
check("Trim buttons reject boundaries and wrong clip IDs") {
    var p=Project(); p.videoPath="a.mp4"; p.duration=4000
    return rejects{_ = try p.trimmingClip(p.clips[0].id,at:0,removeBefore:true)} && rejects{_ = try p.trimmingClip(p.clips[0].id,at:4000,removeBefore:false)} && rejects{_ = try p.trimmingClip(UUID(),at:1000,removeBefore:true)}
}
check("Erase regions persist and survive source-based split") {
    var p=Project(); var clip=VideoClip(path:"a.mp4",duration:4000)
    let region=VideoEraseRegion(x:0.1,y:0.1,width:0.7,height:0.2,sourceStart:500,sourceEnd:3500)
    clip.eraseRegions=[region]; p=try p.replacingClips([clip])
    let split=try p.splittingClip(clip.id,at:2000)
    let decoded=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(split)); try decoded.validate()
    return decoded.clips.count == 2 && decoded.clips.allSatisfy{$0.eraseRegions == [region]}
}
check("Erase regions reject invalid rectangles, colors and times") {
    var p=Project(); var clip=VideoClip(path:"a.mp4",duration:4000)
    clip.eraseRegions=[VideoEraseRegion(x:0.9,y:0,width:0.2,height:0.2,sourceStart:0,sourceEnd:4000)]
    let outside=rejects{_ = try p.replacingClips([clip])}
    clip.eraseRegions=[VideoEraseRegion(x:0,y:0,width:0.2,height:0.2,sourceStart:4000,sourceEnd:4000)]
    let emptyTime=rejects{_ = try p.replacingClips([clip])}
    clip.eraseRegions=[VideoEraseRegion(x:0,y:0,width:0.2,height:0.2,sourceStart:0,sourceEnd:4000,color:RGBA(.nan,0,0))]
    return outside && emptyTime && rejects{_ = try p.replacingClips([clip])}
}
check("Legacy styles default to centered alignment") {
    let data=try JSONEncoder().encode(SubtitleStyle())
    var json=try JSONSerialization.jsonObject(with:data) as! [String:Any]
    json.removeValue(forKey:"alignment")
    return try JSONDecoder().decode(SubtitleStyle.self,from:JSONSerialization.data(withJSONObject:json)).textAlignment == .center
}
check("Alignment survives project persistence and applies only to selected track") {
    var q=p; var style=SubtitleStyle(); style.alignment = .right
    q.applyStyle(style,for:q.cues[0])
    let restored=try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(q))
    return restored.cues.allSatisfy { restored.style(for:$0).textAlignment == .right } && restored.style(for:Cue(language:.zh,start:0,end:1000,text:"测试")).textAlignment == .center
}
check("UI localization renders both languages without altering arguments") {
    let payload="字幕 {1} / 中文.mp4"
    return UILocalization.text("导出完成：{0}",arguments:[payload],language:.en) == "Export complete: \(payload)"
        && UILocalization.text("导出完成：{0}",arguments:[payload],language:.zh) == "导出完成：\(payload)"
        && UILocalization.text("unknown",language:.en) == "unknown"
}
check("Every English translation preserves placeholder indices") {
    let regex=try NSRegularExpression(pattern:"\\{[0-9]+\\}")
    func tokens(_ s:String)->Set<String> { let ns=s as NSString; return Set(regex.matches(in:s,range:NSRange(location:0,length:ns.length)).map{ns.substring(with:$0.range)}) }
    return UILocalization.english.allSatisfy { tokens($0.key) == tokens($0.value) && !$0.value.isEmpty }
}
print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0:1)
