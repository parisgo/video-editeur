import AppKit
import AVFoundation
import UniformTypeIdentifiers
import SubtitleCore

extension EditorController {
    @objc func libraryDoubleClicked() { if showsMedia { editSelectedVideo() } }
    @objc func appendVideos() {
        guard !busy else { return }
        let panel=NSOpenPanel(); panel.allowedContentTypes=[.movie]; panel.allowsMultipleSelection=true; panel.title=L("添加视频到当前时间轴")
        guard panel.runModal() == .OK else { return }
        do {
            let additions=try panel.urls.map { url in VideoClip(path:url.path,duration:try MediaProbe(url.path).duration) }
            let next=try project.replacingClips(project.clips+additions)
            commit(next,name:L("添加视频")); if let id=additions.first?.id { selectVideoClip(id) }
        } catch { showError(error) }
    }
    func selectVideoClip(_ id: UUID) {
        guard let placement=project.placements.first(where:{$0.clip.id == id}) else { return }
        cancelRegionErase(); pauseForEditing(); clearSelection(); selectedClip=id; timeline.selectedClip=id; timeline.needsDisplay=true
        if showsMedia,let i=libraryEntries.firstIndex(where:{$0.clipID == id}) { setTableSelection(IndexSet(integer:i)) }
        current=placement.start; player.seek(to:CMTime(value:current,timescale:1000),toleranceBefore:.zero,toleranceAfter:.zero); refreshPlayback()
        if let info=try? MediaProbe(placement.clip.path) { statusLabel.stringValue=info.description+L(" · 双击视频片段编辑") }
    }
    func installPreview(for next: Project) throws {
        guard !next.clips.isEmpty else { player.pause(); player.replaceCurrentItem(with:nil); current=0; loadTimelineThumbnails(for:[]); return }
        let formats=try MediaProbe.formats(next).0
        let edited=try EditedAsset(project:next,color:formats.last ?? .sdr,subtitles:false)
        player.pause(); playButton.image=NSImage(systemSymbolName:"play.fill",accessibilityDescription:L("播放"))
        player.replaceCurrentItem(with:edited.playerItem()); overlay.videoSize=edited.size
        current=min(current,max(0,next.duration-1)); player.seek(to:CMTime(value:current,timescale:1000))
        loadTimelineThumbnails(for:next.clips)
    }

    func restoreEditedProject() {
        do {
            var next=project
            for clip in next.clips where !FileManager.default.fileExists(atPath:clip.path) {
                let alert=NSAlert(); alert.messageText=L("找不到视频素材"); alert.informativeText=clip.path; alert.addButton(withTitle:L("重新定位")); alert.addButton(withTitle:L("稍后"))
                guard alert.runModal() == .alertFirstButtonReturn else { refresh(); return }
                let panel=NSOpenPanel(); panel.allowedContentTypes=[.movie]
                guard panel.runModal() == .OK,let url=panel.url else { return }
                let probe=try MediaProbe(url.path)
                guard abs(probe.duration-clip.sourceDuration)<=1000 else { throw SubtitleError.invalid(L("素材时长不匹配，请选择原视频")) }
                for i in next.videoClips!.indices where next.videoClips![i].path == clip.path { next.videoClips![i].path=url.path }
            }
            next.videoPath=next.clips.first?.path ?? ""; try installPreview(for:next); project=next; refresh(); scheduleSave()
        } catch { showError(error) }
    }
    var targetClip: VideoClip? { project.clips.first{$0.id == selectedClip} ?? project.placements.first{$0.start<=current && current<$0.end}?.clip ?? project.clips.first }
    @objc func splitSelectedVideo() {
        guard !busy,let clip=targetClip else { return }
        pauseForEditing()
        do { commit(try project.splittingClip(clip.id,at:current),name:L("分割视频")) } catch { showError(error) }
    }
    func trimSelectedVideo(removeBefore: Bool) {
        guard !busy,let clip=targetClip else { return }
        pauseForEditing()
        do {
            let next=try project.trimmingClip(clip.id,at:current,removeBefore:removeBefore)
            commit(next,name:removeBefore ? L("删除片段左侧") : L("删除片段右侧"))
        } catch { showError(error) }
    }
    func refreshCutButtons() {
        let placement=targetClip.flatMap { clip in project.placements.first{$0.clip.id == clip.id} }
        let inside=placement.map{current>$0.start && current<$0.end} ?? false
        for name in ["splitVideo","trimVideoLeft","trimVideoRight"] {
            (bottom.subviews.first{$0.identifier?.rawValue == name} as? NSButton)?.isEnabled = !busy && inside
        }
    }
    @objc func moveVideoEarlier() { moveVideo(-1) }
    @objc func moveVideoLater() { moveVideo(1) }
    func moveVideo(_ offset: Int) {
        guard !busy,let clip=targetClip,let i=project.clips.firstIndex(where:{$0.id == clip.id}) else { return }
        var clips=project.clips; let j=i+offset; guard clips.indices.contains(j) else { return }
        clips.swapAt(i,j); normalizeTransitions(&clips)
        do { commit(try project.replacingClips(clips),name:L("调整视频顺序")); selectVideoClip(clip.id) } catch { showError(error) }
    }
    func normalizeTransitions(_ clips: inout [VideoClip]) {
        for i in clips.indices { clips[i].transition=i == 0 ? 0 : min(clips[i].transition,min(clips[i].duration,clips[i-1].duration)/2) }
    }
    @objc func deleteSelectedVideo() {
        guard !busy,let clip=targetClip else { return }
        var clips=project.clips.filter{$0.id != clip.id}; normalizeTransitions(&clips)
        do { commit(try project.replacingClips(clips),name:L("删除视频片段")); selectedClip=nil; timeline.selectedClip=nil } catch { showError(error) }
    }
    @objc func editSelectedVideo() {
        guard !busy,let original=targetClip else { return }
        pauseForEditing(); selectedClip=original.id; timeline.selectedClip=original.id; timeline.needsDisplay=true
        let alert=NSAlert(); alert.messageText=L("视频剪辑与特效")
        let info=(try? MediaProbe(original.path).description) ?? L("素材不可用")
        alert.informativeText=URL(fileURLWithPath:original.path).lastPathComponent+"\n"+info+L("\n时间单位：秒。叠化与前一片段重叠，字幕跟随剪辑。")
        let form=NSView(frame:NSRect(x:0,y:0,width:410,height:300))
        let values: [(String,Double)]=[(L("源视频起点"),Double(original.sourceStart)/1000),(L("源视频终点"),Double(original.sourceEnd)/1000),(L("与前片段叠化"),Double(original.transition)/1000),(L("淡入"),Double(original.effects.fadeIn)/1000),(L("淡出"),Double(original.effects.fadeOut)/1000),(L("亮度（-1～1）"),original.effects.brightness),(L("对比度（0～2）"),original.effects.contrast),(L("饱和度（0～2）"),original.effects.saturation)]
        var fields: [NSTextField]=[]
        for (i,value) in values.enumerated() {
            let title=label(value.0,size:12); title.frame=NSRect(x:0,y:268-i*36,width:180,height:24); form.addSubview(title)
            let field=NSTextField(string:String(format:"%.3f",value.1)); field.frame=NSRect(x:190,y:268-i*36,width:210,height:24); field.setAccessibilityLabel(value.0); form.addSubview(field); fields.append(field)
        }
        alert.accessoryView=form; alert.addButton(withTitle:L("应用")); alert.addButton(withTitle:L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let numbers=fields.compactMap{Double($0.stringValue)}
        guard numbers.count == 8,numbers.allSatisfy({$0.isFinite && abs($0)<1e9}) else { showError(SubtitleError.invalid(L("请输入有效数值"))); return }
        var clip=original
        clip.sourceStart=Int64(numbers[0]*1000); clip.sourceEnd=Int64(numbers[1]*1000); clip.transition=Int64(numbers[2]*1000)
        clip.effects.fadeIn=Int64(numbers[3]*1000); clip.effects.fadeOut=Int64(numbers[4]*1000)
        clip.effects.brightness=numbers[5]; clip.effects.contrast=numbers[6]; clip.effects.saturation=numbers[7]
        var clips=project.clips; guard let i=clips.firstIndex(where:{$0.id == clip.id}) else { return }; clips[i]=clip
        do { commit(try project.replacingClips(clips),name:L("视频裁剪与特效")) } catch { showError(error) }
    }
    func chooseExportColor() -> VideoColor? {
        do {
            let (formats,description)=try MediaProbe.formats(project)
            let alert=NSAlert(); alert.messageText=L("选择输出格式"); alert.informativeText=description
            let choice=NSPopUpButton(frame:NSRect(x:0,y:0,width:420,height:28)); choice.addItems(withTitles:formats.map(\.title)); choice.selectItem(at:formats.count-1)
            alert.accessoryView=choice; alert.addButton(withTitle:L("继续导出")); alert.addButton(withTitle:L("取消"))
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }; return formats[choice.indexOfSelectedItem]
        } catch { showError(error); return nil }
    }
}

extension EditorController {
    func prepareTranscriptionInput(project: Project,job: GenerationJob) throws -> URL {
        guard project.videoClips != nil else { return URL(fileURLWithPath:project.videoPath) }
        try FileManager.default.createDirectory(at:job.directory,withIntermediateDirectories:true)
        let destination=job.directory.appendingPathComponent("edited-audio.m4a")
        if FileManager.default.fileExists(atPath:destination.path) { return destination }
        DispatchQueue.main.async { [weak self] in self?.statusLabel.stringValue=L("正在混合剪辑音频…") }
        let edited=try EditedAsset(project:project,color:.sdr,subtitles:false)
        guard !edited.asset.tracks(withMediaType:.audio).isEmpty else { throw SubtitleError.invalid(L("时间轴没有音轨，无法生成语音字幕")) }
        guard let session=AVAssetExportSession(asset:edited.asset,presetName:AVAssetExportPresetAppleM4A) else { throw SubtitleError.invalid(L("无法创建剪辑音频")) }
        let temporary=job.directory.appendingPathComponent("edited-audio-partial.m4a")
        try? FileManager.default.removeItem(at:temporary)
        defer { try? FileManager.default.removeItem(at:temporary) }
        session.outputURL=temporary; session.outputFileType = .m4a; session.audioMix=edited.audio
        let done=DispatchSemaphore(value:0); session.exportAsynchronously{done.signal()}
        while done.wait(timeout:.now()+0.1) == .timedOut {
            if job.runner.isCancelled { session.cancelExport(); throw SubtitleError.invalid(L("音频准备已取消")) }
        }
        guard !job.runner.isCancelled,session.status == .completed else { throw session.error ?? SubtitleError.invalid(L("音频准备已取消或失败")) }
        try FileManager.default.moveItem(at:temporary,to:destination); return destination
    }
}
