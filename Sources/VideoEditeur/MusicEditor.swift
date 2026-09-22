import AppKit
import AVFoundation
import UniformTypeIdentifiers
import SubtitleCore

extension EditorController {
    func setupMusicControls() {
        timeline.toggleVideoTrackControl={[weak self] index in
            guard let self,!self.busy,!self.project.clips.isEmpty else { return }
            self.pauseForEditing()
            var next=self.project
            let name: String
            switch index {
            case 0: next.lockVideoTrack = !next.isVideoLocked; name=L("锁定视频轨道")
            case 1: next.hideVideoTrack = !next.isVideoHidden; name=L("隐藏视频轨道")
            default: next.muteVideoAudio = !next.isVideoMuted; name=L("静音原视频")
            }
            self.commit(next,name:name)
        }
        timeline.selectMusic={[weak self] id in self?.selectMusicClip(id) }
        timeline.editMusic={[weak self] in self?.editMusic()}
        timeline.moveMusic={[weak self] value in
            guard let self,let index=self.project.music.firstIndex(where:{$0.id == value.id}) else { return }
            var next=self.project; next.backgroundMusic=self.project.music; next.backgroundMusic?[index]=value; self.commit(next,name:L("编辑音乐"))
        }
    }
    func selectMusicClip(_ id: UUID) {
        guard project.music.contains(where:{$0.id == id}) else { return }
        pauseForEditing(); clearSelection(); selectedMusic=id; timeline.selectedMusic=id
        if showsMedia,let index=libraryEntries.firstIndex(where:{$0.musicID == id}) { setTableSelection(IndexSet(integer:index)) }
        refreshMusicControls(); refreshCutButtons(); timeline.needsDisplay=true
    }
    func cutSelectedMusic(removeBefore: Bool? = nil) {
        guard !busy,let id=selectedMusic else { return }; pauseForEditing()
        do { commit(try project.cuttingMusic(id,at:current,removeBefore:removeBefore),name:removeBefore == nil ? L("分割音乐") : L("裁剪音乐")) }
        catch { showError(error) }
    }
    func refreshMusicControls() {
        if !project.music.contains(where:{$0.id == selectedMusic}) { selectedMusic=nil }
        timeline.selectedMusic=selectedMusic
    }
    func deleteMusic() {
        guard !busy,let id=selectedMusic else { return }
        var next=project; next.backgroundMusic=project.music.filter{$0.id != id}; commit(next,name:L("删除音乐"))
    }
    func editMusic() {
        guard !busy,let id=selectedMusic,let original=project.music.first(where:{$0.id == id}) else { return }
        pauseForEditing()
        let alert=NSAlert(); alert.messageText=L("编辑背景音乐"); alert.informativeText=URL(fileURLWithPath:original.path).lastPathComponent
        let form=NSView(frame:NSRect(x:0,y:0,width:410,height:155)); var fields:[NSTextField]=[]
        for (i,pair) in [(L("时间轴起点 · 秒"),Double(original.start)/1000),(L("音乐起点 · 秒"),Double(original.sourceStart)/1000),(L("音乐终点 · 秒"),Double(original.sourceEnd)/1000),(L("音量 %"),original.volume*100)].enumerated() {
            let title=label(pair.0); title.frame=NSRect(x:0,y:120-i*38,width:185,height:26); form.addSubview(title)
            let field=NSTextField(string:String(format:"%.3f",pair.1)); field.frame=NSRect(x:195,y:120-i*38,width:210,height:26); form.addSubview(field); fields.append(field)
        }
        alert.accessoryView=form; alert.addButton(withTitle:L("应用")); alert.addButton(withTitle:L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let values=fields.compactMap{Double($0.stringValue.replacingOccurrences(of:",",with:"."))}
        guard values.count==4,values.allSatisfy({$0.isFinite && abs($0)<1e9}),values[0]>=0,values[0]<Double(project.duration)/1000 else { showError(SubtitleError.invalid(L("背景音乐时间或音量无效"))); return }
        var music=original; music.start=Int64(values[0]*1000); music.sourceStart=Int64(values[1]*1000); music.sourceEnd=Int64(values[2]*1000); music.volume=values[3]/100
        var next=project; next.backgroundMusic=project.music.map{$0.id == id ? music : $0}; commit(next,name:L("编辑音乐"))
    }
}
