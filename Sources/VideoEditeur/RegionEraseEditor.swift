import AppKit
import AVFoundation
import CoreImage
import SubtitleCore

extension EditorController {
    func sampleEraseColor(at point: CGPoint) {
        eraseSampleColor=nil
        guard let item=player.currentItem else { return }
        let token=UUID(); eraseSampleID=token
        let generator=AVAssetImageGenerator(asset:item.asset)
        generator.appliesPreferredTrackTransform=true
        generator.videoComposition=item.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time=player.currentTime()
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            do {
                let image=try generator.copyCGImage(at:time,actualTime:nil)
                let color=RegionColorSampler.sample(CIImage(cgImage:image),at:point)
                DispatchQueue.main.async {
                    guard let self,self.eraseSampleID == token,self.overlay.eraseMode else { return }
                    self.eraseSampleColor=color
                    self.statusLabel.stringValue=L("已取鼠标起点颜色 · 框选后按 Delete 应用")
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self,self.eraseSampleID == token else { return }
                    self.eraseSampleID=nil
                    self.statusLabel.stringValue=L("起点取色失败，请重新框选：{0}",[error.localizedDescription])
                }
            }
        }
    }
    func refreshRegionEraseButton() {
        guard let button=center.subviews.first(where:{$0.identifier?.rawValue == "regionErase"}) as? NSButton else { return }
        button.state=overlay.eraseMode ? .on : .off
        button.bezelColor=overlay.eraseMode ? accent : nil
        button.contentTintColor=overlay.eraseMode ? .black : nil
    }

    @objc func beginRegionErase() {
        guard !busy,let clip=targetClip else { return }
        if overlay.eraseMode { cancelRegionErase(); return }
        pauseForEditing(); clearSelection()
        if let p=project.placements.first(where:{$0.clip.id == clip.id}),!(p.start..<p.end).contains(current) { selectVideoClip(clip.id) }
        eraseSampleID=nil; eraseSampleColor=nil
        eraseClipID=clip.id; overlay.eraseMode=true; overlay.eraseRect=nil
        refreshRegionEraseButton()
        overlay.needsDisplay=true; overlay.window?.invalidateCursorRects(for:overlay); view.window?.makeFirstResponder(overlay)
        statusLabel.stringValue=L("从背景处按下鼠标取色并框选；Delete 去字，Esc 取消")
    }
    func cancelRegionErase() {
        eraseSampleID=nil; eraseSampleColor=nil
        eraseClipID=nil; overlay.eraseMode=false; overlay.eraseRect=nil
        refreshRegionEraseButton()
        overlay.needsDisplay=true; overlay.window?.invalidateCursorRects(for:overlay)
    }
    func applySelectedEraseRegion() {
        guard !busy,let box=overlay.eraseRect,let clip=project.clips.first(where:{$0.id == eraseClipID}) else { return }
        guard let color=eraseSampleColor else {
            statusLabel.stringValue=eraseSampleID == nil ? L("取色失败，请重新框选") : L("正在读取起点颜色，请稍后按 Delete")
            return
        }
        let region=VideoEraseRegion(x:box.minX,y:box.minY,width:box.width,height:box.height,sourceStart:clip.sourceStart,sourceEnd:clip.sourceEnd,color:color)
        editEraseRegion(region,clip:clip,isNew:true)
    }
    func editEraseRegion(_ original: VideoEraseRegion,clip: VideoClip,isNew: Bool) {
        pauseForEditing()
        let alert=NSAlert(); alert.messageText=isNew ? L("用背景色覆盖选区文字") : L("编辑去字区域")
        alert.informativeText=L("默认使用框选起点的视频颜色，可手动调整。勾选自动匹配后改用底边逐帧取色。时间相对于当前片段，Y 从底部计算。")
        let form=NSView(frame:NSRect(x:0,y:0,width:420,height:310))
        let values: [(String,Double)]=[(L("左侧 X %"),original.x*100),(L("底部 Y %"),original.y*100),(L("宽度 %"),original.width*100),(L("高度 %"),original.height*100),(L("开始 · 秒"),Double(max(clip.sourceStart,original.sourceStart)-clip.sourceStart)/1000),(L("结束 · 秒"),Double(min(clip.sourceEnd,original.sourceEnd)-clip.sourceStart)/1000)]
        var fields: [NSTextField]=[]
        for (i,value) in values.enumerated() {
            let title=label(value.0,size:12); title.frame=NSRect(x:0,y:278-i*34,width:155,height:24); form.addSubview(title)
            let field=NSTextField(string:String(format:"%.3f",value.1)); field.frame=NSRect(x:165,y:278-i*34,width:245,height:24); field.setAccessibilityLabel(value.0); form.addSubview(field); fields.append(field)
        }
        let automatic=NSButton(checkboxWithTitle:L("自动匹配底边背景色（取消勾选使用下方颜色）"),target:nil,action:nil)
        automatic.state=original.color == nil ? .on : .off; automatic.frame=NSRect(x:0,y:58,width:420,height:30); form.addSubview(automatic)
        let color=NSColorWell(frame:NSRect(x:165,y:18,width:245,height:28)); color.color=original.color?.ns ?? NSColor(srgbRed:0.09,green:0.15,blue:0.55,alpha:1); form.addSubview(color)
        let title=label(L("手动背景色"),size:12); title.frame=NSRect(x:0,y:20,width:155,height:24); form.addSubview(title)
        alert.accessoryView=form; alert.addButton(withTitle:isNew ? L("去字") : L("应用")); alert.addButton(withTitle:L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let numbers=fields.compactMap{Double($0.stringValue)}
        guard numbers.count == 6,numbers.allSatisfy({$0.isFinite && abs($0)<1e9}),numbers[4]>=0,numbers[5]<=Double(clip.duration)/1000 else { showError(SubtitleError.invalid(L("请输入有效坐标和片段内时间"))); return }
        var region=original
        region.x=numbers[0]/100; region.y=numbers[1]/100; region.width=numbers[2]/100; region.height=numbers[3]/100
        region.sourceStart=clip.sourceStart+Int64(numbers[4]*1000); region.sourceEnd=clip.sourceStart+Int64(numbers[5]*1000)
        var fill=RGBA(color.color); fill.a=1
        region.color=automatic.state == .on ? nil : fill
        var clips=project.clips; guard let i=clips.firstIndex(where:{$0.id == clip.id}) else { return }
        var regions=clips[i].eraseRegions ?? []
        if let j=regions.firstIndex(where:{$0.id == region.id}) { regions[j]=region } else { regions.append(region) }
        clips[i].eraseRegions=regions
        // This edit changes only appearance: preserve all existing subtitle boundaries and IDs.
        var next=project; next.videoClips=clips
        do { try next.validate() } catch { showError(error); return }
        commit(next,name:isNew ? L("添加区域去字") : L("修改区域去字"))
        if project == next { cancelRegionErase(); statusLabel.stringValue=L("已用背景色覆盖选区 · ⌘Z 撤销；视频剪辑菜单可管理去字区域") }
    }
    @objc func manageEraseRegions() {
        guard !busy,let clip=targetClip else { return }
        let regions=clip.eraseRegions ?? []
        guard !regions.isEmpty else { statusLabel.stringValue=L("此视频片段暂无去字区域，点击「区域去字」开始框选"); return }
        pauseForEditing()
        let alert=NSAlert(); alert.messageText=L("管理去字区域")
        let choice=NSPopUpButton(frame:NSRect(x:0,y:0,width:420,height:28))
        for (i,r) in regions.enumerated() { choice.addItem(withTitle:L("区域 {0} · {1} · {2}–{3} 秒", [String(describing: i+1), String(describing: r.color == nil ? L("自动背景色") : L("手动背景色")), String(describing: String(format:"%.2f",Double(r.sourceStart-clip.sourceStart)/1000)), String(describing: String(format:"%.2f",Double(r.sourceEnd-clip.sourceStart)/1000))])) }
        alert.accessoryView=choice; alert.addButton(withTitle:L("编辑")); alert.addButton(withTitle:L("删除区域")); alert.addButton(withTitle:L("取消"))
        let response=alert.runModal(),region=regions[max(0,choice.indexOfSelectedItem)]
        if response == .alertFirstButtonReturn { editEraseRegion(region,clip:clip,isNew:false) }
        else if response == .alertSecondButtonReturn {
            var next=project; next.videoClips=project.clips
            if let i=next.videoClips?.firstIndex(where:{$0.id == clip.id}) { next.videoClips?[i].eraseRegions?.removeAll{$0.id == region.id}; commit(next,name:L("删除去字区域")) }
        }
    }
}

/// Normalized bottom-left coordinates match the video overlay, including letterboxing.
enum RegionColorSampler {
    static func sample(_ image: CIImage, at point: CGPoint) -> RGBA {
        let extent=image.extent
        let x=extent.minX+min(extent.width-1,max(0,floor(point.x*extent.width)))
        let y=extent.minY+min(extent.height-1,max(0,floor(point.y*extent.height)))
        var pixel=[UInt8](repeating:0,count:4)
        CIContext().render(image,toBitmap:&pixel,rowBytes:4,bounds:CGRect(x:x,y:y,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
        return RGBA(Double(pixel[0])/255,Double(pixel[1])/255,Double(pixel[2])/255,1)
    }
}
