import Foundation
import AVFoundation
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
