import AppKit
import AVFoundation
import SubtitleCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var pendingURL: URL?
    let editor=EditorController()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance=NSAppearance(named:.darkAqua)
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:1440,height:900),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="字幕工坊 · Video Éditeur"; window.minSize=NSSize(width:1140,height:760); window.contentViewController=editor; window.center(); window.makeKeyAndOrderFront(nil)
        let main=NSMenu()
        func menu(_ title: String) -> NSMenu { let item=NSMenuItem(); item.title=title; let submenu=NSMenu(title:title); item.submenu=submenu; main.addItem(item); return submenu }
        func item(_ menu: NSMenu,_ title: String,_ action: Selector,_ key: String,_ target: AnyObject?,shift: Bool=false) { let i=NSMenuItem(title:title,action:action,keyEquivalent:key); i.target=target; if shift { i.keyEquivalentModifierMask=[.command,.shift] }; menu.addItem(i) }
        let app=menu("字幕工坊"); item(app,"设置…",#selector(EditorController.showSettings),",",editor); app.addItem(.separator()); item(app,"退出字幕工坊",#selector(NSApplication.terminate(_:)),"q",NSApp)
        let file=menu("文件"); item(file,"导入视频…",#selector(EditorController.importVideo),"o",editor); item(file,"打开工程…",#selector(EditorController.chooseProject),"o",editor,shift:true); item(file,"保存工程…",#selector(EditorController.saveProject),"s",editor)
        let edit=menu("编辑"); item(edit,"撤销",#selector(EditorController.undoAction),"z",editor); item(edit,"重做",#selector(EditorController.redoAction),"z",editor,shift:true)
        edit.addItem(.separator()); item(edit,"剪切",#selector(NSText.cut(_:)),"x",nil); item(edit,"复制",#selector(NSText.copy(_:)),"c",nil); item(edit,"粘贴",#selector(NSText.paste(_:)),"v",nil); item(edit,"全选",#selector(NSText.selectAll(_:)),"a",nil)
        let playback=menu("播放"); item(playback,"播放 / 暂停",#selector(EditorController.togglePlay)," ",editor)
        let windowMenu=menu("窗口"); item(windowMenu,"最小化",#selector(NSWindow.miniaturize(_:)),"m",nil); NSApp.windowsMenu=windowMenu
        NSApp.mainMenu=main; NSApp.activate(ignoringOtherApps:true)
        if let url=pendingURL { DispatchQueue.main.async { self.editor.openProject(url) }; pendingURL=nil }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url=urls.first else { return }; if window != nil { editor.openProject(url) } else { pendingURL=url }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if editor.busy {
            let alert=NSAlert(); alert.messageText="任务正在进行"; alert.informativeText="退出会取消当前任务，已完成字幕仍会保存。"; alert.addButton(withTitle:"取消任务并退出"); alert.addButton(withTitle:"继续工作")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
            editor.generation?.cancel(); editor.exporter?.cancel()
        }
        editor.persistNow(); return .terminateNow
    }
}

// CLI smoke-test hooks exercise the same renderer, exporter and generation pipeline as the app.
if CommandLine.arguments.count >= 4,CommandLine.arguments[1] == "--smoke-services" {
    _=NSApplication.shared
    do { try runServiceChecks(video:URL(fileURLWithPath:CommandLine.arguments[2]),directory:URL(fileURLWithPath:CommandLine.arguments[3])) } catch { fputs("\(error)\n",stderr); exit(1) }
} else if CommandLine.arguments.count >= 4,CommandLine.arguments[1] == "--smoke-export" {
    let source=URL(fileURLWithPath:CommandLine.arguments[2]),destination=URL(fileURLWithPath:CommandLine.arguments[3])
    let asset=AVURLAsset(url:source); var p=Project(); p.videoPath=source.path; p.duration=Int64(CMTimeGetSeconds(asset.duration)*1000)
    p.cues=[Cue(language:.fr,start:0,end:min(1500,p.duration),text:"Bonjour ! Une nouvelle histoire."),Cue(language:.zh,start:0,end:min(1500,p.duration),text:"你好 一段新的故事"),Cue(language:.zh,start:min(1500,p.duration),end:p.duration,text:"让每一句话 都被看见")].filter{$0.end>$0.start}
    let app=NSApplication.shared; _=app
    do { try VideoExporter().run(project:p,destination:destination) { _ in }; print("EXPORT_OK \(destination.path)") } catch { fputs("\(error)\n",stderr); exit(1) }
} else if CommandLine.arguments.count >= 4,CommandLine.arguments[1] == "--smoke-generate" {
    let source=URL(fileURLWithPath:CommandLine.arguments[2]),directory=URL(fileURLWithPath:CommandLine.arguments[3])
    do {
        let duration=Int64(CMTimeGetSeconds(AVURLAsset(url:source).duration)*1000)
        let cues=try GenerationJob(directory:directory).run(video:source,duration:duration,status:{print($0)},partial:{print("PARTIAL \($0.count)")})
        print("GENERATION_OK \(cues.count)")
    } catch { fputs("\(error)\n",stderr); exit(1) }
} else {
    let app=NSApplication.shared; let delegate=AppDelegate(); app.delegate=delegate; app.setActivationPolicy(.regular); app.run()
}
