import AppKit
import AVKit
import UniformTypeIdentifiers
import SubtitleCore

final class EditorController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    var project=Project()
    var projectURL: URL?
    var selected: UUID?
    var current: Int64=0
    let history=UndoManager()
    let player=AVPlayer()
    var observer: Any?
    private var deleteKeyMonitor: Any?
    private var blankClickMonitor: Any?
    private var deselectedCueIDs: Set<UUID>?
    deinit { if let deleteKeyMonitor { NSEvent.removeMonitor(deleteKeyMonitor) }; if let blankClickMonitor { NSEvent.removeMonitor(blankClickMonitor) } }
    var generation: GenerationJob?
    var retryDirectory: URL?
    var exporter: VideoExporter?
    var busy=false
    var autosave: DispatchWorkItem?
    let root=LayoutView(), header=NSView(), left=NSView(), center=DropView(), right=NSView(), bottom=NSView()
    let preview=AVPlayerView(), overlay=PreviewOverlay(), table=SubtitleTableView(), tableScroll=NSScrollView()
    let panelDivider=PanelDivider(), leftDivider=PanelDivider(), rightDivider=PanelDivider()
    var mediaPanelWidth: CGFloat=CGFloat(max(250,UserDefaults.standard.double(forKey:"editor.mediaWidth")))
    var propertyPanelWidth: CGFloat=CGFloat(max(300,UserDefaults.standard.object(forKey:"editor.propertyWidth") == nil ? 300 : UserDefaults.standard.double(forKey:"editor.propertyWidth")))
    var timelinePanelHeight: CGFloat = {
        let saved=UserDefaults.standard.double(forKey:"editor.timelineHeight")
        return saved.isFinite && saved >= 140 ? CGFloat(saved) : 260
    }()
    let textTrackChoice=NSPopUpButton()
    let timeline=TimelineView(), timelineScroll=NSScrollView()
    let titleLabel=label("字幕工坊",size:18,bold:true), subtitleLabel=label("FR / ZH  ·  本地视频工作台",size:10,color:muted)
    let fileLabel=label("尚未导入视频",size:12,bold:true), statusLabel=label("准备就绪",size:11,color:muted)
    let timeLabel=label("00:00:00 / 00:00:00",size:11,color:accent)
    let emptyTitle=label("让每一句话，都被看见",size:24,color:.white,bold:true)
    let emptyHint=label("拖入法语视频，开始制作中文与法语字幕",size:13,color:muted)
    let progress=NSProgressIndicator(), scrub=NSSlider(), zoom=NSSlider()
    var importButton: ActionButton!, generateButton: ActionButton!, exportButton: ActionButton!, cancelButton: ActionButton!, playButton: ActionButton!
    let displayMode=NSSegmentedControl(labels:["法语","中文"],trackingMode:.selectAny,target:nil,action:nil)
    let languageChoice=NSSegmentedControl(labels:["法语","中文"],trackingMode:.selectAny,target:nil,action:nil)
    let panelToggles=NSSegmentedControl(labels:["素材", "字幕属性", "时间轴"],trackingMode:.selectAny,target:nil,action:nil)
    private let panelKeys=["editor.showMedia", "editor.showInspector", "editor.showTimeline"]
    let inspectorScroll=NSScrollView(), inspector=NSStackView()
    let textEditor=NSTextView(), fontChoice=NSPopUpButton(), startField=NSTextField(), endField=NSTextField(), sizeField=NSTextField(), widthField=NSTextField(), outlineField=NSTextField(), xField=NSTextField(), yField=NSTextField()
    let textColor=NSColorWell(), outlineColor=NSColorWell(), backgroundColor=NSColorWell(), backgroundEnabled=NSButton(checkboxWithTitle:"显示背景",target:nil,action:nil)
    let readabilityEnabled=NSButton(checkboxWithTitle:"增强可读性（对比描边与阴影）",target:nil,action:nil)
    let selectionLabel=label("选择字幕开始编辑",size:13,bold:true)
    var inspectorUpdating=false
    var inspectorPositioned=false
    var rows: [Cue] { project.displayedCues }
    var syncingSelection=false
    var preferredLanguage: Language = .zh
    var styleDragOriginal: Project?
    override var undoManager: UndoManager? { history }
    override func loadView() { view=root; root.frame=NSRect(x:0,y:0,width:1440,height:900); setup() }
    func setup() {
        root.wantsLayer=true; root.layer?.backgroundColor=NSColor(srgbRed:0.055,green:0.065,blue:0.078,alpha:1).cgColor
        for pane in [header,left,center,right,bottom] { pane.wantsLayer=true; pane.layer?.backgroundColor=panelColor.cgColor; pane.layer?.cornerRadius=8; root.addSubview(pane) }
        header.layer?.backgroundColor=NSColor.clear.cgColor
        importButton=ActionButton("导入视频",symbol:"plus",action:{[weak self] in self?.importVideo()})
        generateButton=ActionButton("生成法中字幕",symbol:"sparkles",action:{[weak self] in self?.generate()})
        exportButton=ActionButton("导出视频",symbol:"square.and.arrow.up",action:{[weak self] in self?.exportVideo()}); exportButton.contentTintColor=accent
        let save=ActionButton("保存",symbol:"square.and.arrow.down",action:{[weak self] in self?.saveProject()}); save.identifier=NSUserInterfaceItemIdentifier("save")
        let settings=ActionButton("",symbol:"gearshape",action:{[weak self] in self?.showSettings()}); settings.identifier=NSUserInterfaceItemIdentifier("settings")
        for v in [titleLabel,subtitleLabel,importButton!,generateButton!,exportButton!,save,settings] { header.addSubview(v) }
        panelToggles.target=self; panelToggles.action=#selector(panelsChanged(_:))
        panelToggles.setAccessibilityLabel("面板显示开关")
        panelToggles.toolTip="点击显示或收起面板；选中表示已展开"
        for index in panelKeys.indices {
            panelToggles.setSelected(UserDefaults.standard.object(forKey:panelKeys[index]) as? Bool ?? true,forSegment:index)
        }
        header.addSubview(panelToggles)
        let mediaTitle=label("素材 / 字幕",size:13,bold:true); mediaTitle.frame=NSRect(x:16,y:0,width:220,height:22); mediaTitle.identifier=NSUserInterfaceItemIdentifier("mediaTitle"); left.addSubview(mediaTitle)
        left.addSubview(fileLabel)
        table.headerView=nil; table.backgroundColor = .clear; table.rowHeight=61; table.intercellSpacing=NSSize(width:0,height:3)
        let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("subtitle")); column.width=240; table.addTableColumn(column); table.delegate=self; table.dataSource=self
        table.allowsMultipleSelection=true; table.selectionHighlightStyle = .regular; tableScroll.documentView=table; tableScroll.hasVerticalScroller=true; tableScroll.drawsBackground=false; left.addSubview(tableScroll)
        languageChoice.target=self; languageChoice.action=#selector(modeChanged(_:)); left.addSubview(languageChoice)
        let add=ActionButton("添加",symbol:"plus",action:{[weak self] in self?.addSubtitle()}); add.identifier=NSUserInterfaceItemIdentifier("add"); left.addSubview(add)
        let delete=ActionButton("",symbol:"trash",action:{[weak self] in self?.deleteSubtitle()}); delete.identifier=NSUserInterfaceItemIdentifier("delete"); left.addSubview(delete)
        center.drop={[weak self] in self?.loadVideo($0)}
        preview.player=player; preview.allowsVideoFrameAnalysis=false; preview.controlsStyle = .none; preview.videoGravity = .resizeAspect; center.addSubview(preview); center.addSubview(overlay)
        center.addSubview(emptyTitle); center.addSubview(emptyHint)
        let previewTitle=label("预览",size:12,color:muted); previewTitle.identifier=NSUserInterfaceItemIdentifier("previewTitle"); center.addSubview(previewTitle)
        displayMode.target=self; displayMode.action=#selector(modeChanged(_:)); center.addSubview(displayMode)
        playButton=ActionButton("",symbol:"play.fill",action:{[weak self] in self?.togglePlay()}); center.addSubview(playButton)
        scrub.minValue=0; scrub.maxValue=1; scrub.target=self; scrub.action=#selector(scrubChanged); scrub.isContinuous=true; center.addSubview(scrub); center.addSubview(timeLabel)
        table.onDeselect={[weak self] in self?.clearSelection() }
        overlay.onDeselect={[weak self] in self?.clearSelection() }
        timeline.onDeselect={[weak self] in self?.clearSelection() }
        overlay.onSelect={[weak self] in self?.pauseForEditing(); self?.select($0,seek:false)}
        overlay.onGestureBegan={[weak self] in self?.styleDragOriginal=self?.project }
        overlay.onStyleChange={[weak self] id,style,finished in self?.previewTrackStyle(id:id,style:style,finished:finished) }
        overlay.onGestureCancelled={[weak self] in
            guard let self,let original=self.styleDragOriginal else { return }
            self.styleDragOriginal=nil; self.project=original; self.refresh(); self.refreshInspector()
        }
        setupInspector()
        let timelineTitle=label("时间轴",size:12,bold:true); timelineTitle.identifier=NSUserInterfaceItemIdentifier("timelineTitle"); bottom.addSubview(timelineTitle)
        let tip=label("拖动片段调整时间 · 拖动边缘调整时长",size:10,color:muted); tip.identifier=NSUserInterfaceItemIdentifier("timelineTip"); bottom.addSubview(tip)
        let newTrack=ActionButton("新建文字轨道",symbol:"plus",action:{[weak self] in self?.addTextTrack()}); newTrack.identifier=NSUserInterfaceItemIdentifier("newTrack"); bottom.addSubview(newTrack)
        let newText=ActionButton("添加文字",symbol:"text.badge.plus",action:{[weak self] in self?.addTrackText()}); newText.identifier=NSUserInterfaceItemIdentifier("newText"); bottom.addSubview(newText)
        let deleteTrack=ActionButton("删除轨道",symbol:"trash",action:{[weak self] in self?.deleteTextTrack()}); deleteTrack.identifier=NSUserInterfaceItemIdentifier("deleteTrack"); deleteTrack.toolTip="删除所选文字轨道及全部文字片段（⌘Z 可撤销）"; bottom.addSubview(deleteTrack)
        textTrackChoice.setAccessibilityLabel("目标文字轨道"); bottom.addSubview(textTrackChoice)
        timelineScroll.hasVerticalScroller=true
        zoom.minValue=5; zoom.maxValue=150; zoom.doubleValue=65; zoom.target=self; zoom.action=#selector(zoomChanged); bottom.addSubview(zoom)
        timelineScroll.documentView=timeline; timelineScroll.hasHorizontalScroller=true; timelineScroll.drawsBackground=false; bottom.addSubview(timelineScroll)
        timeline.select={[weak self] in self?.pauseForEditing(); self?.select($0)}; timeline.seek={[weak self] in self?.seek($0)}
        timeline.edit={[weak self] id,start,end in self?.updateCue(id) { c,_ in c.start=start; c.end=end }; self?.refreshInspector() }
        root.addSubview(statusLabel); progress.style = .bar; progress.isIndeterminate=false; progress.minValue=0; progress.maxValue=1; root.addSubview(progress); progress.isHidden=true
        cancelButton=ActionButton("取消",action:{[weak self] in self?.generation?.cancel(); self?.exporter?.cancel(); self?.statusLabel.stringValue="正在取消…"}); root.addSubview(cancelButton); cancelButton.isHidden=true
        for (divider,title) in [(leftDivider,"素材面板"),(rightDivider,"字幕属性面板")] {
            divider.isVertical=true; divider.toolTip="左右拖动调整\(title)宽度；双击恢复默认"
            divider.setAccessibilityLabel("调整\(title)宽度"); root.addSubview(divider)
        }
        leftDivider.onResize={[weak self] delta,finished in self?.resizeSidePanel(left:true,delta:delta,finished:finished) }
        rightDivider.onResize={[weak self] delta,finished in self?.resizeSidePanel(left:false,delta:delta,finished:finished) }
        leftDivider.onReset={[weak self] in self?.resetSidePanel(left:true) }
        rightDivider.onReset={[weak self] in self?.resetSidePanel(left:false) }
        root.addSubview(panelDivider)
        panelDivider.onResize={[weak self] delta,finished in
            guard let self else { return }
            self.timelinePanelHeight=max(140,min(self.root.bounds.height-350,self.bottom.frame.height+delta))
            self.root.needsLayout=true; self.root.layoutSubtreeIfNeeded()
            if finished { UserDefaults.standard.set(Double(self.timelinePanelHeight),forKey:"editor.timelineHeight") }
        }
        panelDivider.onReset={[weak self] in
            guard let self else { return }
            self.timelinePanelHeight=260; UserDefaults.standard.set(260,forKey:"editor.timelineHeight")
            self.root.needsLayout=true; self.root.layoutSubtreeIfNeeded()
        }
        root.onLayout={[weak self] in self?.layoutEditor()}
        observer=player.addPeriodicTimeObserver(forInterval:CMTime(value:1,timescale:30),queue:.main) {[weak self] time in
            guard let self else { return }; let seconds=CMTimeGetSeconds(time); guard seconds.isFinite else { return }
            self.current=Int64(seconds*1000); self.refreshPlayback()
            if self.current >= self.project.duration-40, self.player.rate == 0 { self.playButton.image=NSImage(systemSymbolName:"play.fill",accessibilityDescription:"播放") }
        }
        blankClickMonitor=NSEvent.addLocalMonitorForEvents(matching:.leftMouseDown) { [weak self] event in
            guard let self,let window=self.view.window,event.window === window,window.attachedSheet == nil,NSApp.modalWindow == nil else { return event }
            var hit=self.root.hitTest(self.root.convert(event.locationInWindow,from:nil))
            while let v=hit {
                // These views handle their own selection or edit the current selection.
                if v is NSControl || v is NSTextView || v is NSScrollView || v === self.overlay || v === self.timeline || v === self.right || v === self.panelDivider || v === self.leftDivider || v === self.rightDivider { return event }
                hit=v.superview
            }
            self.clearSelection(); return event
        }
        deleteKeyMonitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard let self,let window=self.view.window,event.window === window,
                  window.isKeyWindow,window.attachedSheet == nil,NSApp.modalWindow == nil,
                  event.keyCode == 51 || event.keyCode == 117,
                  event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty,
                  !(window.firstResponder is NSText),!self.busy,self.selected != nil else { return event }
            // Holding Delete must not remove successive playback-selected clips.
            if !event.isARepeat { self.pauseForEditing(); self.deleteSubtitle() }
            return nil
        }
        NSColorPanel.shared.showsAlpha=true
        refresh(); refreshInspector(); restore()
    }
    @objc func panelsChanged(_ sender: NSSegmentedControl) {
        // Commit any field being edited before its panel is hidden.
        view.window?.makeFirstResponder(nil)
        for index in panelKeys.indices {
            UserDefaults.standard.set(sender.isSelected(forSegment:index),forKey:panelKeys[index])
        }
        root.needsLayout=true
        root.layoutSubtreeIfNeeded()
    }
    func resizeSidePanel(left isLeft:Bool,delta:CGFloat,finished:Bool) {
        let remaining=center.frame.width-320
        if isLeft { mediaPanelWidth=max(250,min(left.frame.width+delta,left.frame.width+remaining)) }
        else { propertyPanelWidth=max(300,min(right.frame.width-delta,right.frame.width+remaining)) }
        root.needsLayout=true; root.layoutSubtreeIfNeeded()
        if finished { UserDefaults.standard.set(Double(isLeft ? mediaPanelWidth : propertyPanelWidth),forKey:isLeft ? "editor.mediaWidth" : "editor.propertyWidth") }
    }
    func resetSidePanel(left isLeft:Bool) {
        if isLeft { mediaPanelWidth=250 } else { propertyPanelWidth=300 }
        UserDefaults.standard.set(isLeft ? 250 : 300,forKey:isLeft ? "editor.mediaWidth" : "editor.propertyWidth")
        root.needsLayout=true; root.layoutSubtreeIfNeeded()
    }
    func layoutEditor() {
        let w=root.bounds.width,h=root.bounds.height,margin:CGFloat=10,headerH:CGFloat=62,statusH:CGFloat=30
        let bottomH=max(140,min(timelinePanelHeight,h-350))
        header.frame=NSRect(x:margin,y:h-headerH,width:w-20,height:headerH)
        titleLabel.frame=NSRect(x:8,y:31,width:230,height:25); subtitleLabel.frame=NSRect(x:9,y:13,width:250,height:15)
        exportButton.frame=NSRect(x:header.bounds.width-114,y:20,width:110,height:32)
        generateButton.frame=NSRect(x:header.bounds.width-384,y:20,width:142,height:32)
        importButton.frame=NSRect(x:header.bounds.width-501,y:20,width:110,height:32)
        header.subviews.first{$0.identifier?.rawValue == "save"}?.frame=NSRect(x:header.bounds.width-237,y:20,width:74,height:32)
        header.subviews.first{$0.identifier?.rawValue == "settings"}?.frame=NSRect(x:header.bounds.width-160,y:20,width:40,height:32)
        panelToggles.frame=NSRect(x:270,y:22,width:262,height:28)
        left.isHidden = !panelToggles.isSelected(forSegment:0)
        right.isHidden = !panelToggles.isSelected(forSegment:1)
        bottom.isHidden = !panelToggles.isSelected(forSegment:2)
        panelDivider.isHidden=bottom.isHidden
        panelDivider.frame=NSRect(x:margin,y:statusH+bottomH,width:w-2*margin,height:10)
        let y=statusH+(bottom.isHidden ? 0 : bottomH+10), paneH=max(240,h-headerH-y-8)
        let available=w-2*margin-320-(left.isHidden ? 0 : 8)-(right.isHidden ? 0 : 8)
        let rightW=max(300,min(propertyPanelWidth,available-(left.isHidden ? 0 : 250)))
        let leftW=max(250,min(mediaPanelWidth,available-(right.isHidden ? 0 : rightW)))
        leftDivider.isHidden=left.isHidden; rightDivider.isHidden=right.isHidden
        leftDivider.frame=NSRect(x:margin+leftW,y:y,width:8,height:paneH)
        rightDivider.frame=NSRect(x:w-margin-rightW-8,y:y,width:8,height:paneH)
        let leftSpace:CGFloat=left.isHidden ? 0 : leftW+8
        let rightSpace:CGFloat=right.isHidden ? 0 : rightW+8
        left.frame=NSRect(x:margin,y:y,width:leftW,height:paneH); right.frame=NSRect(x:w-margin-rightW,y:y,width:rightW,height:paneH)
        center.frame=NSRect(x:margin+leftSpace,y:y,width:w-2*margin-leftSpace-rightSpace,height:paneH)
        left.subviews.first{$0.identifier?.rawValue == "mediaTitle"}?.frame=NSRect(x:16,y:paneH-37,width:220,height:22)
        fileLabel.frame=NSRect(x:16,y:paneH-65,width:leftW-32,height:21); fileLabel.lineBreakMode = .byTruncatingMiddle
        tableScroll.frame=NSRect(x:8,y:53,width:leftW-16,height:paneH-127)
        tableScroll.tile(); table.tableColumns.first?.width=max(1,tableScroll.contentSize.width)
        languageChoice.frame=NSRect(x:12,y:15,width:111,height:26)
        left.subviews.first{$0.identifier?.rawValue == "add"}?.frame=NSRect(x:126,y:13,width:77,height:30)
        left.subviews.first{$0.identifier?.rawValue == "delete"}?.frame=NSRect(x:205,y:13,width:34,height:30)
        let cw=center.bounds.width
        center.subviews.first{$0.identifier?.rawValue == "previewTitle"}?.frame=NSRect(x:16,y:paneH-33,width:80,height:20)
        displayMode.frame=NSRect(x:cw-188,y:paneH-35,width:173,height:25)
        preview.frame=NSRect(x:10,y:71,width:cw-20,height:max(100,paneH-119)); overlay.frame=preview.frame
        emptyTitle.frame=NSRect(x:20,y:paneH/2+6,width:cw-40,height:35); emptyTitle.alignment = .center
        emptyHint.frame=NSRect(x:20,y:paneH/2-26,width:cw-40,height:24); emptyHint.alignment = .center
        playButton.frame=NSRect(x:14,y:17,width:38,height:30); timeLabel.frame=NSRect(x:62,y:25,width:204,height:17)
        scrub.frame=NSRect(x:14,y:53,width:cw-28,height:14)
        inspectorScroll.frame=right.bounds.insetBy(dx:14,dy:16)
        inspectorScroll.tile()
        // Use the actual clip width: traditional scrollbars occupy layout space.
        inspector.frame.size.width=max(0,inspectorScroll.contentSize.width-8)
        inspector.layoutSubtreeIfNeeded()
        if !inspectorPositioned { inspector.layoutSubtreeIfNeeded(); inspectorScroll.contentView.scroll(to:NSPoint(x:0,y:max(0,inspector.frame.height-inspectorScroll.contentSize.height))); inspectorPositioned=true }
        bottom.frame=NSRect(x:margin,y:statusH,width:w-20,height:bottomH)
        bottom.subviews.first{$0.identifier?.rawValue == "timelineTitle"}?.frame=NSRect(x:15,y:bottomH-32,width:70,height:20)
        bottom.subviews.first{$0.identifier?.rawValue == "timelineTip"}?.frame=NSRect(x:89,y:bottomH-31,width:0,height:20)
        bottom.subviews.first{$0.identifier?.rawValue == "newTrack"}?.frame=NSRect(x:90,y:bottomH-35,width:136,height:28)
        textTrackChoice.frame=NSRect(x:235,y:bottomH-35,width:140,height:28)
        bottom.subviews.first{$0.identifier?.rawValue == "newText"}?.frame=NSRect(x:383,y:bottomH-35,width:112,height:28)
        bottom.subviews.first{$0.identifier?.rawValue == "deleteTrack"}?.frame=NSRect(x:503,y:bottomH-35,width:112,height:28)
        zoom.frame=NSRect(x:bottom.bounds.width-175,y:bottomH-33,width:156,height:24)
        timelineScroll.frame=NSRect(x:0,y:0,width:bottom.bounds.width,height:bottomH-42); resizeTimeline()
        statusLabel.frame=NSRect(x:17,y:6,width:w-330,height:17); progress.frame=NSRect(x:w-310,y:12,width:190,height:6); cancelButton.frame=NSRect(x:w-106,y:1,width:90,height:26)
    }
    func resizeTimeline() { timeline.frame=NSRect(x:0,y:0,width:max(timelineScroll.contentSize.width,CGFloat(project.duration)/1000*timeline.pointsPerSecond+120),height:max(timelineScroll.contentSize.height,timeline.contentHeight)); timeline.needsDisplay=true }
    func setupInspector() {
        inspector.orientation = .vertical; inspector.alignment = .leading; inspector.spacing=13; inspector.edgeInsets=NSEdgeInsets(top:0,left:0,bottom:20,right:0)
        inspectorScroll.documentView=inspector; inspectorScroll.hasVerticalScroller=true; inspectorScroll.hasHorizontalScroller=false; inspectorScroll.drawsBackground=false; right.addSubview(inspectorScroll)
        func add(_ view: NSView, height: CGFloat) { view.translatesAutoresizingMaskIntoConstraints=false; inspector.addArrangedSubview(view); view.widthAnchor.constraint(equalTo:inspector.widthAnchor).isActive=true; view.heightAnchor.constraint(equalToConstant:height).isActive=true }
        func heading(_ name: String) { add(label(name,size:11,color:muted),height:16) }
        func row(_ name: String,_ control: NSControl) {
            let row=NSView(); let l=label(name,size:12,color:muted)
            l.translatesAutoresizingMaskIntoConstraints=false; control.translatesAutoresizingMaskIntoConstraints=false
            row.addSubview(l); row.addSubview(control); add(row,height:30)
            NSLayoutConstraint.activate([
                l.leadingAnchor.constraint(equalTo:row.leadingAnchor), l.widthAnchor.constraint(equalToConstant:68), l.centerYAnchor.constraint(equalTo:row.centerYAnchor),
                control.leadingAnchor.constraint(equalTo:row.leadingAnchor,constant:75), control.trailingAnchor.constraint(equalTo:row.trailingAnchor),
                control.centerYAnchor.constraint(equalTo:row.centerYAnchor), control.heightAnchor.constraint(equalToConstant:28)
            ])
            control.target=self; control.action=#selector(inspectorChanged(_:))
            (control as? NSTextField)?.delegate=self
        }
        add(label("字幕属性",size:15,bold:true),height:24); add(selectionLabel,height:20); heading("文本内容")
        let scroll=TextEditorScrollView(); scroll.contentView=TextEditorClipView(); scroll.borderType = .bezelBorder; scroll.hasVerticalScroller=true; scroll.hasHorizontalScroller=false; scroll.documentView=textEditor
        textEditor.frame=NSRect(x:0,y:0,width:242,height:94); textEditor.minSize=NSSize(width:0,height:94); textEditor.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:10000); textEditor.autoresizingMask=[.width]
        textEditor.isVerticallyResizable=true; textEditor.isHorizontallyResizable=false; textEditor.textContainer?.widthTracksTextView=true; textEditor.textContainerInset=NSSize(width:12,height:8); textEditor.textContainer?.lineFragmentPadding=0
        textEditor.font = .systemFont(ofSize:14); textEditor.backgroundColor=NSColor(white:0.09,alpha:1); textEditor.textColor = .white; textEditor.isRichText=false; textEditor.delegate=self; add(scroll,height:98)
        heading("时间 · 秒"); row("开始",startField); row("结束",endField)
        heading("字体与样式")
        fontChoice.addItems(withTitles:NSFontManager.shared.availableFontFamilies.sorted()); row("字体",fontChoice)
        row("字号",sizeField); widthField.placeholderString="自动"; row("宽度 %",widthField); row("颜色",textColor); row("描边宽度",outlineField); row("描边颜色",outlineColor)
        readabilityEnabled.target=self; readabilityEnabled.action=#selector(inspectorChanged(_:)); add(readabilityEnabled,height:24)
        backgroundEnabled.target=self; backgroundEnabled.action=#selector(inspectorChanged(_:)); add(backgroundEnabled,height:24); row("背景颜色",backgroundColor)
        heading("位置 · %，Y 从底部计算"); row("水平 X",xField); row("垂直 Y",yField)
        add(label("位置和样式自动应用于同轨全部文字",size:10,color:accent),height:18)
        add(label("四角调字号 · 左右手柄调宽度",size:10,color:muted),height:18)
        inspector.translatesAutoresizingMaskIntoConstraints=true
        inspector.frame=NSRect(x:0,y:0,width:250,height:inspector.fittingSize.height)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cue=rows[row],cell=NSTableCellView(); cell.frame.size.width=tableColumn?.width ?? 240; let badge=label(cue.trackID != nil ? "文" : cue.language == .fr ? "FR" : "中",size:10,color:cue.language == .fr ? NSColor.systemPurple : accent,bold:true)
        badge.frame=NSRect(x:8,y:37,width:27,height:16); cell.addSubview(badge)
        let t=label(String(format:"%.2f — %.2f",Double(cue.start)/1000,Double(cue.end)/1000),size:10,color:muted); t.frame=NSRect(x:39,y:37,width:max(1,cell.frame.width-47),height:16); t.autoresizingMask=[.width]; cell.addSubview(t)
        let body=label(cue.text.replacingOccurrences(of:"\n",with:" "),size:12); body.lineBreakMode = .byTruncatingTail; body.frame=NSRect(x:8,y:8,width:max(1,cell.frame.width-16),height:22); body.autoresizingMask=[.width]; cell.addSubview(body); return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection else { return }
        let i=table.selectedRow
        if i >= 0,i < rows.count { select(rows[i].id) }
    }
    func setTableSelection(_ indexes: IndexSet) {
        syncingSelection=true; table.selectRowIndexes(indexes,byExtendingSelection:false); syncingSelection=false
    }
    func clearSelection() {
        guard !busy else { return }
        view.window?.makeFirstResponder(nil)
        deselectedCueIDs=Set(project.active(at:current).map(\.id))
        selected=nil; setTableSelection([])
        overlay.selected=nil; overlay.needsDisplay=true; overlay.window?.invalidateCursorRects(for:overlay)
        timeline.selected=nil; timeline.needsDisplay=true
        refreshInspector()
        (left.subviews.first{$0.identifier?.rawValue == "delete"} as? NSButton)?.isEnabled=false
    }
    func select(_ id: UUID, seek shouldSeek: Bool = true) {
        guard let cue=rows.first(where:{$0.id == id}) else { return }
        deselectedCueIDs=nil
        selected=id; preferredLanguage=cue.language
        if let id=cue.trackID,let item=textTrackChoice.itemArray.first(where:{$0.representedObject as? UUID == id}) { textTrackChoice.select(item) }
        if let i=rows.firstIndex(where:{$0.id == id}) { setTableSelection(IndexSet(integer:i)) }
        if shouldSeek { seek(cue.start) }
        overlay.selected=selected; overlay.needsDisplay=true; timeline.selected=selected; timeline.needsDisplay=true; refreshInspector()
    }
    func followCurrentSubtitles() {
        let displayed=rows, active=project.active(at:current), ids=Set(active.map(\.id))
        if let dismissed=deselectedCueIDs {
            if dismissed == ids { return }
            deselectedCueIDs=nil
        }
        let indexes=IndexSet(displayed.indices.filter{ids.contains(displayed[$0].id)})
        let next=active.first(where:{$0.id == selected})?.id ?? active.first(where:{$0.trackID == nil && $0.language == preferredLanguage})?.id ?? active.first?.id
        if table.selectedRowIndexes != indexes {
            setTableSelection(indexes)
            if let first=indexes.first { table.scrollRowToVisible(first) }
            if let last=indexes.last { table.scrollRowToVisible(last) }
        }
        if selected != next { selected=next; overlay.selected=next; timeline.selected=next; refreshInspector() }
        (left.subviews.first{$0.identifier?.rawValue == "delete"} as? NSButton)?.isEnabled = !busy && selected != nil
    }
    func refresh() {
        fileLabel.stringValue=project.videoPath.isEmpty ? "尚未导入视频" : URL(fileURLWithPath:project.videoPath).lastPathComponent
        syncingSelection=true; table.reloadData(); syncingSelection=false
        if let selected,let i=rows.firstIndex(where:{$0.id == selected}) { setTableSelection(IndexSet(integer:i)) }
        else { selected=nil; setTableSelection([]); refreshInspector() }
        overlay.editingEnabled = !busy; timeline.editingEnabled = !busy
        overlay.project=project; overlay.selected=selected; overlay.time=current; overlay.needsDisplay=true
        let chosen=textTrackChoice.selectedItem?.representedObject as? UUID
        textTrackChoice.removeAllItems()
        for track in project.tracks {
            textTrackChoice.addItem(withTitle:track.name); textTrackChoice.lastItem?.representedObject=track.id
        }
        if let chosen,let item=textTrackChoice.itemArray.first(where:{$0.representedObject as? UUID == chosen}) { textTrackChoice.select(item) }
        textTrackChoice.isEnabled = !busy && !project.tracks.isEmpty
        (bottom.subviews.first{$0.identifier?.rawValue == "deleteTrack"} as? NSButton)?.isEnabled = !busy && !project.tracks.isEmpty
        for v in bottom.subviews where ["newTrack","newText"].contains(v.identifier?.rawValue ?? "") { (v as? NSButton)?.isEnabled = !busy && project.duration > 0 }
        timeline.project=project; timeline.selected=selected; timeline.current=current; resizeTimeline()
        emptyTitle.isHidden = !project.videoPath.isEmpty; emptyHint.isHidden=emptyTitle.isHidden
        for control in [languageChoice,displayMode] {
            control.setSelected(project.showFrench,forSegment:0); control.setSelected(project.showChinese,forSegment:1); control.isEnabled = !busy
        }
        generateButton.isEnabled = !busy && !project.videoPath.isEmpty; exportButton.isEnabled=generateButton.isEnabled; importButton.isEnabled = !busy
        scrub.isEnabled = !project.videoPath.isEmpty; scrub.maxValue=max(1,Double(project.duration))
        (left.subviews.first{$0.identifier?.rawValue == "add"} as? NSButton)?.isEnabled = !busy && !project.videoPath.isEmpty
        (left.subviews.first{$0.identifier?.rawValue == "delete"} as? NSButton)?.isEnabled = !busy && selected != nil
        refreshPlayback()
    }
    func refreshPlayback() {
        timeLabel.stringValue="\(SRT.timestamp(current).replacingOccurrences(of:",",with:".")) / \(SRT.timestamp(project.duration).prefix(8))"
        if player.rate != 0 { followCurrentSubtitles() }
        scrub.doubleValue=Double(current); overlay.time=current; overlay.needsDisplay=true; timeline.current=current; timeline.needsDisplay=true
    }
    func refreshInspector() {
        inspectorUpdating=true; defer { inspectorUpdating=false }
        let enabled = !busy && project.cues.contains{$0.id == selected}
        for control in [fontChoice,startField,endField,sizeField,widthField,outlineField,xField,yField,textColor,outlineColor,backgroundColor,backgroundEnabled,readabilityEnabled] as [NSControl] { control.isEnabled=enabled }
        for button in inspector.arrangedSubviews.compactMap({$0 as? NSButton}) { button.isEnabled=enabled }
        guard let cue=project.cues.first(where:{$0.id == selected}) else { selectionLabel.stringValue="选择字幕开始编辑"; textEditor.string=""; textEditor.isEditable=false; return }
        textEditor.isEditable = !busy; selectionLabel.stringValue="\(project.tracks.first(where:{$0.id == cue.trackID})?.name ?? (cue.language.title+"字幕")) · \(cue.style == nil ? "轨道样式" : "自定义样式")"
        textEditor.string=cue.text; startField.stringValue=String(format:"%.3f",Double(cue.start)/1000); endField.stringValue=String(format:"%.3f",Double(cue.end)/1000)
        let s=project.style(for:cue); let family=NSFont(name:s.font,size:12)?.familyName ?? s.font
        if fontChoice.itemTitles.contains(family) { fontChoice.selectItem(withTitle:family) }
        widthField.stringValue=s.width.map { String(format:"%.1f",$0*100) } ?? ""
        sizeField.stringValue=String(format:"%.1f",s.size); outlineField.stringValue=String(format:"%.1f",s.outlineWidth); xField.stringValue=String(format:"%.1f",s.x*100); yField.stringValue=String(format:"%.1f",s.y*100)
        readabilityEnabled.state=s.enhancesReadability ? .on : .off
        textColor.color=s.color.ns; outlineColor.color=s.outline.ns; backgroundColor.color=s.background.a > 0 ? s.background.ns : NSColor(white:0,alpha:0.65); backgroundEnabled.state=s.background.a > 0 ? .on : .off
    }
    func commit(_ next: Project, name: String = "编辑字幕") {
        guard next != project else { return }
        do { try next.validate() } catch { showError(error); refreshInspector(); return }
        let old=project
        history.registerUndo(withTarget:self) { target in target.commit(old,name:name); target.refreshInspector() }; history.setActionName(name)
        project=next
        if !busy && retryDirectory != nil && next.cues != old.cues { retryDirectory=nil; UserDefaults.standard.removeObject(forKey:"pendingJob"); generateButton.title="生成法中字幕" }
        refresh(); scheduleSave()
    }
    func updateCue(_ id: UUID, _ edit: (inout Cue,Project)->Void) {
        guard !busy,let i=project.cues.firstIndex(where:{$0.id == id}) else { return }
        var next=project; edit(&next.cues[i],project); commit(next)
    }
    func pauseForEditing() {
        if player.rate != 0 { player.pause(); playButton.image=NSImage(systemSymbolName:"play.fill",accessibilityDescription:"播放") }
    }
    func textDidBeginEditing(_ notification: Notification) { pauseForEditing() }
    func controlTextDidBeginEditing(_ notification: Notification) { pauseForEditing() }
    func textDidChange(_ notification: Notification) {
        guard !inspectorUpdating,!busy,let id=selected,!textEditor.string.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        let text=textEditor.string; updateCue(id) { cue,_ in cue.text=cue.trackID == nil && cue.language == .zh ? text.components(separatedBy:.newlines).joined(separator:"，") : text }
    }
    func textDidEndEditing(_ notification: Notification) {
        if textEditor.string.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && selected != nil {
            refreshInspector(); statusLabel.stringValue="字幕内容不能为空；移除字幕请使用删除按钮"
        }
    }
    @objc func inspectorChanged(_ sender: NSControl) {
        guard !inspectorUpdating,!busy,let id=selected else { return }
        if sender === widthField,let cue=project.cues.first(where:{$0.id == id}) {
            let raw=widthField.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
            let value=Double(raw.replacingOccurrences(of:",",with:"."))
            guard raw.isEmpty || (value.map{$0.isFinite && (10...100).contains($0)} ?? false) else {
                showError(SubtitleError.invalid("宽度请输入 10 到 100，留空恢复自动宽度")); refreshInspector(); return
            }
            pauseForEditing(); var next=project; var style=project.style(for:cue); style.width=value.map{$0/100}
            next.applyStyle(style,for:cue); commit(next,name:"调整同语言字幕宽度"); refreshInspector(); return
        }
        let fields=[startField,endField,sizeField,outlineField,xField,yField]
        let values=fields.compactMap { Double($0.stringValue.replacingOccurrences(of:",",with:".")) }
        guard values.count == 6, values.allSatisfy(\.isFinite),abs(values[0])<1e9,abs(values[1])<1e9 else { showError(SubtitleError.invalid("请输入有效数值")); refreshInspector(); return }
        guard let index=project.cues.firstIndex(where:{$0.id == id}) else { return }
        pauseForEditing()
        var next=project
        if sender === startField || sender === endField {
            next.cues[index].start=Int64(values[0]*1000); next.cues[index].end=Int64(values[1]*1000)
        } else {
            let cue=project.cues[index]; var style=project.style(for:cue)
            if sender === fontChoice {
                style.font=NSFontManager.shared.font(withFamily:fontChoice.titleOfSelectedItem ?? "PingFang SC",traits:[],weight:5,size:12)?.fontName ?? style.font
            }
            if sender === sizeField { style.size=values[2] }
            if sender === readabilityEnabled { style.readability=readabilityEnabled.state == .on }
            if sender === textColor { style.color=RGBA(textColor.color) }
            if sender === outlineColor { style.outline=RGBA(outlineColor.color) }
            if sender === outlineField { style.outlineWidth=values[3] }
            if sender === backgroundEnabled || sender === backgroundColor { style.background=backgroundEnabled.state == .on ? RGBA(backgroundColor.color) : .clear }
            if sender === xField { style.x=values[4]/100 }
            if sender === yField { style.y=values[5]/100 }
            next.applyStyle(style,for:cue)
        }
        commit(next,name:"编辑字幕属性"); refreshInspector()
    }
    func previewTrackStyle(id: UUID, style: SubtitleStyle, finished: Bool) {
        guard !busy,let original=styleDragOriginal,let cue=original.cues.first(where:{$0.id == id}) else { return }
        var next=original; next.applyStyle(style,for:cue)
        if finished {
            styleDragOriginal=nil; project=original; commit(next,name:"调整同语言字幕样式")
        } else {
            project=next; overlay.project=next; overlay.needsDisplay=true; timeline.project=next; timeline.needsDisplay=true
        }
        refreshInspector()
    }
    func deleteTextTrack() {
        guard !busy,let id=textTrackChoice.selectedItem?.representedObject as? UUID,
              project.tracks.contains(where:{$0.id == id}) else { return }
        view.window?.makeFirstResponder(nil)
        pauseForEditing()
        var next=project
        next.cues.removeAll{$0.trackID == id}
        next.textTracks=next.tracks.filter{$0.id != id}
        if let selected,!next.cues.contains(where:{$0.id == selected}) { self.selected=nil }
        commit(next,name:"删除文字轨道"); refreshInspector()
    }
    func addTextTrack() {
        guard !busy,project.duration > 0 else { return }
        pauseForEditing()
        do {
            var next=project
            let track=TextTrack(name:"文字 \(next.tracks.count+1)")
            next.textTracks=next.tracks+[track]
            let cue=try next.newCue(language:.zh,at:min(current,max(0,next.duration-2000)),trackID:track.id)
            next.cues.append(cue); commit(next,name:"新建文字轨道")
            textTrackChoice.selectItem(at:next.tracks.count-1); select(cue.id)
            timeline.scrollToVisible(timeline.rect(cue))
        } catch { showError(error) }
    }
    func addTrackText() {
        guard !busy else { return }
        guard let id=textTrackChoice.selectedItem?.representedObject as? UUID else { addTextTrack(); return }
        pauseForEditing()
        do {
            let cue=try project.newCue(language:.zh,at:current,trackID:id)
            var next=project; next.cues.append(cue); commit(next,name:"添加说明文字"); select(cue.id)
            timeline.scrollToVisible(timeline.rect(cue))
        } catch { showError(error) }
    }
    func addSubtitle() {
        guard !busy else { return }
        guard project.showFrench || project.showChinese else { showError(SubtitleError.invalid("请先选中法语或中文")); return }
        let language: Language = project.visible(preferredLanguage) ? preferredLanguage : (project.showFrench ? .fr : .zh)
        do { let cue=try project.newCue(language:language,at:current); var next=project; next.cues.append(cue); commit(next,name:"添加字幕"); select(cue.id) } catch { showError(error) }
    }
    func deleteSubtitle() { guard !busy,let id=selected else { return }; var next=project; next.cues.removeAll{$0.id == id}; selected=nil; commit(next,name:"删除字幕"); refreshInspector() }
    @objc func modeChanged(_ sender: NSSegmentedControl) {
        guard !busy else { refresh(); return }
        var next=project; next.showFrench=sender.isSelected(forSegment:0); next.showChinese=sender.isSelected(forSegment:1)
        if sender.selectedSegment >= 0, sender.isSelected(forSegment:sender.selectedSegment) { preferredLanguage=sender.selectedSegment == 0 ? .fr : .zh }
        commit(next,name:"切换字幕显示"); followCurrentSubtitles(); refreshInspector()
    }
    @objc func zoomChanged() { timeline.pointsPerSecond=zoom.doubleValue; resizeTimeline() }
    @objc func scrubChanged() { seek(Int64(scrub.doubleValue)) }
    func seek(_ ms: Int64) { current=max(0,min(project.duration,ms)); player.seek(to:CMTime(value:current,timescale:1000),toleranceBefore:.zero,toleranceAfter:.zero); followCurrentSubtitles(); refreshPlayback() }
    @objc func togglePlay() {
        guard !project.videoPath.isEmpty else { return }
        if player.rate == 0 { if current >= project.duration-40 { seek(0) }; player.play(); playButton.image=NSImage(systemSymbolName:"pause.fill",accessibilityDescription:"暂停") }
        else { player.pause(); playButton.image=NSImage(systemSymbolName:"play.fill",accessibilityDescription:"播放") }
    }
    func showError(_ error: Error) { let alert=NSAlert(error:error); alert.runModal() }
    @objc func importVideo() {
        guard !busy else { return }
        let panel=NSOpenPanel(); panel.allowedContentTypes=[.movie]; panel.allowsMultipleSelection=false
        if panel.runModal() == .OK,let url=panel.url { loadVideo(url) }
    }
    func loadVideo(_ url: URL, preservingProject: Bool = false) {
        guard !busy else { return }
        if url.pathExtension == "frzh" { openProject(url); return }
        let asset=AVURLAsset(url:url)
        guard let track=asset.tracks(withMediaType:.video).first else { showError(SubtitleError.invalid("无法读取视频，请选择支持的 MP4 或 MOV 文件")); return }
        let seconds=CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite,seconds>0,seconds<1e9 else { showError(SubtitleError.invalid("视频时长无效")); return }
        if !preservingProject {
            archiveCurrentProject()
            project=Project(); project.duration=Int64(seconds*1000); project.videoPath=url.path; projectURL=nil; UserDefaults.standard.removeObject(forKey:"projectURL"); selected=nil; history.removeAllActions(); retryDirectory=nil; UserDefaults.standard.removeObject(forKey:"pendingJob"); generateButton.title="生成法中字幕"
        } else {
            guard abs(Int64(seconds*1000)-project.duration) <= 1000 else { showError(SubtitleError.invalid("所选视频时长与工程不一致，请选择原视频")); return }
            project.videoPath=url.path
        }
        player.pause(); player.replaceCurrentItem(with:AVPlayerItem(asset:asset)); current=0
        let rect=CGRect(origin:.zero,size:track.naturalSize).applying(track.preferredTransform); overlay.videoSize=CGSize(width:abs(rect.width),height:abs(rect.height))
        timeline.thumbnails=[]; refresh(); refreshInspector(); scheduleSave(); statusLabel.stringValue="视频已加载 · \(Int(overlay.videoSize.width)) × \(Int(overlay.videoSize.height))"
        let path=url.path
        DispatchQueue.global(qos:.utility).async {
            let generator=AVAssetImageGenerator(asset:asset); generator.appliesPreferredTrackTransform=true; generator.maximumSize=CGSize(width:220,height:140)
            var images: [NSImage]=[]
            for i in 0..<min(24,max(1,Int(seconds/3))) {
                let time=CMTime(seconds:seconds*Double(i)/Double(min(24,max(1,Int(seconds/3)))),preferredTimescale:600)
                if let cg=try? generator.copyCGImage(at:time,actualTime:nil) { images.append(NSImage(cgImage:cg,size:.zero)) }
            }
            DispatchQueue.main.async { [weak self] in guard self?.project.videoPath == path else { return }; self?.timeline.thumbnails=images; self?.timeline.needsDisplay=true }
        }
    }
    func archiveCurrentProject() {
        persistNow()
        if projectURL == nil && !project.cues.isEmpty {
            let dir=supportDirectory.appendingPathComponent("Recovered Projects")
            do { try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); try project.write(dir.appendingPathComponent("\(UUID().uuidString).frzh")) } catch { showError(error) }
        }
    }
    func scheduleSave() {
        autosave?.cancel(); let task=DispatchWorkItem { [weak self] in self?.persistNow() }; autosave=task; DispatchQueue.main.asyncAfter(deadline:.now()+0.6,execute:task)
    }
    func persistNow() {
        guard !project.videoPath.isEmpty else { return }
        do {
            try project.write(supportDirectory.appendingPathComponent("Recovery.frzh"))
            if let url=projectURL { try project.write(url) }
        } catch { statusLabel.stringValue="自动保存失败：\(error.localizedDescription)" }
    }
    @objc func saveProject() {
        guard !project.videoPath.isEmpty else { return }
        let panel=NSSavePanel(); panel.nameFieldStringValue=URL(fileURLWithPath:project.videoPath).deletingPathExtension().lastPathComponent+".frzh"
        panel.title="保存字幕工程"; panel.allowedContentTypes=[UTType(exportedAs:"local.videoediteur.project",conformingTo:.json)]
        if panel.runModal() == .OK,let url=panel.url { do { try project.write(url); projectURL=url; UserDefaults.standard.set(url.path,forKey:"projectURL"); statusLabel.stringValue="工程已保存：\(url.lastPathComponent)" } catch { showError(error) } }
    }
    @objc func chooseProject() {
        guard !busy else { return }
        let panel=NSOpenPanel(); panel.allowedContentTypes=[UTType(exportedAs:"local.videoediteur.project",conformingTo:.json)]; panel.allowsMultipleSelection=false
        if panel.runModal() == .OK,let url=panel.url { openProject(url) }
    }
    func openProject(_ url: URL) {
        guard !busy else { return }
        do { let loaded=try Project.read(url); archiveCurrentProject(); project=loaded; projectURL=url; UserDefaults.standard.set(url.path,forKey:"projectURL"); UserDefaults.standard.removeObject(forKey:"pendingJob"); selected=nil; retryDirectory=nil; history.removeAllActions(); attachProjectVideo() } catch { showError(error) }
    }
    func restore() {
        let url=supportDirectory.appendingPathComponent("Recovery.frzh")
        if let p=try? Project.read(url),!p.videoPath.isEmpty { project=p
            if let path=UserDefaults.standard.string(forKey:"projectURL") { projectURL=URL(fileURLWithPath:path) }
            if let path=UserDefaults.standard.string(forKey:"pendingJob"),FileManager.default.fileExists(atPath:path) { retryDirectory=URL(fileURLWithPath:path); generateButton.title="继续字幕生成" }
            DispatchQueue.main.async { [weak self] in self?.attachProjectVideo() } }
    }
    func attachProjectVideo() {
        let url=URL(fileURLWithPath:project.videoPath)
        if FileManager.default.fileExists(atPath:url.path) { loadVideo(url,preservingProject:true) }
        else {
            refresh(); let alert=NSAlert(); alert.messageText="找不到原视频"; alert.informativeText="字幕和样式已保留，请重新定位：\n\(url.path)"; alert.addButton(withTitle:"重新定位"); alert.addButton(withTitle:"稍后")
            if alert.runModal() == .alertFirstButtonReturn { let panel=NSOpenPanel(); panel.allowedContentTypes=[.movie]; if panel.runModal() == .OK,let new=panel.url { loadVideo(new,preservingProject:true) } }
        }
    }
    func setBusy(_ value: Bool, indeterminate: Bool = true) {
        busy=value; cancelButton.isHidden = !value; progress.isHidden = !value; progress.isIndeterminate=indeterminate
        if value && indeterminate { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        refresh(); refreshInspector()
    }
    func generate() {
        guard !busy,!project.videoPath.isEmpty else { return }
        if retryDirectory == nil && !project.cues.isEmpty {
            let alert=NSAlert(); alert.messageText="重新生成将替换现有字幕"; alert.informativeText="人工修改的字幕将被替换，完成后可通过撤销恢复。"; alert.addButton(withTitle:"重新生成"); alert.addButton(withTitle:"取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do { try ToolSettings.current.validate() } catch { showError(error); return }
        let original=project, job=GenerationJob(directory:retryDirectory ?? supportDirectory.appendingPathComponent("Jobs/\(UUID().uuidString)"))
        generation=job; retryDirectory=job.directory; UserDefaults.standard.set(job.directory.path,forKey:"pendingJob"); setBusy(true); player.pause()
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            do {
                let result=try job.run(video:URL(fileURLWithPath:original.videoPath),duration:original.duration,status:{ message in DispatchQueue.main.async { self?.statusLabel.stringValue=message } },partial:{ cues in DispatchQueue.main.async { guard let self else { return }; self.project.cues=cues+original.cues.filter{$0.trackID != nil}; self.selected=nil; self.refresh(); self.scheduleSave() } })
                DispatchQueue.main.async {
                    guard let self else { return }; self.project=original; var next=original; next.cues=result+original.cues.filter{$0.trackID != nil}; self.commit(next,name:"生成法中字幕")
                    self.generation=nil; self.retryDirectory=nil; UserDefaults.standard.removeObject(forKey:"pendingJob"); self.generateButton.title="生成法中字幕"; self.setBusy(false); self.statusLabel.stringValue="法中字幕已生成 · \(result.count/2) 组"; self.persistNow()
                    if let first=result.first { self.select(first.id) }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    let partial=self.project; self.project=original; self.commit(partial,name:"生成部分字幕")
                    self.generation=nil; self.setBusy(false); self.generateButton.title="继续字幕生成"; self.statusLabel.stringValue="生成已停止 · 已保留完成的字幕，可继续重试"
                    self.persistNow(); if !job.runner.isCancelled { self.showError(error) }
                }
            }
        }
    }
    func exportVideo() {
        guard !busy,!project.videoPath.isEmpty else { return }
        let panel=NSSavePanel(); panel.allowedContentTypes=[.mpeg4Movie]; panel.nameFieldStringValue=URL(fileURLWithPath:project.videoPath).deletingPathExtension().lastPathComponent+"-法中字幕.mp4"
        guard panel.runModal() == .OK,let url=panel.url else { return }
        let snapshot=project, job=VideoExporter(); exporter=job; setBusy(true,indeterminate:false); progress.doubleValue=0; statusLabel.stringValue="正在导出 H.264 视频…"
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            do {
                var last=Date.distantPast
                try job.run(project:snapshot,destination:url) { value in
                    if Date().timeIntervalSince(last)>0.15 || value == 1 { last=Date(); DispatchQueue.main.async { self?.progress.doubleValue=value; self?.statusLabel.stringValue="正在导出 · \(Int(value*100))%" } }
                }
                DispatchQueue.main.async { self?.exporter=nil; self?.setBusy(false); self?.statusLabel.stringValue="导出完成：\(url.lastPathComponent)"; NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch { DispatchQueue.main.async { self?.exporter=nil; self?.setBusy(false); self?.statusLabel.stringValue=error.localizedDescription; self?.showError(error) } }
        }
    }
    @objc func showSettings() {
        let alert=NSAlert(); alert.messageText="本机工具设置"; alert.informativeText="复用本机 Codex 登录。转写在本机进行，字幕文本发送到 Codex 翻译；首次转写可能下载模型。"
        let box=NSView(frame:NSRect(x:0,y:0,width:530,height:220)); let settings=ToolSettings.current
        var fields: [NSTextField]=[]
        for (i,pair) in [("ffmpeg",settings.ffmpeg),("Python",settings.python),("Codex",settings.codex),("Skill 目录",settings.skill)].enumerated() {
            let y=170-i*48, l=label(pair.0,size:11,color:muted); l.frame=NSRect(x:0,y:y+25,width:520,height:17); box.addSubview(l)
            let f=NSTextField(string:pair.1); f.frame=NSRect(x:0,y:y,width:525,height:24); box.addSubview(f); fields.append(f)
        }
        alert.accessoryView=box; alert.addButton(withTitle:"保存并检查"); alert.addButton(withTitle:"取消")
        if alert.runModal() == .alertFirstButtonReturn {
            var s=settings; s.ffmpeg=fields[0].stringValue; s.python=fields[1].stringValue; s.codex=fields[2].stringValue; s.skill=fields[3].stringValue; ToolSettings.current=s
            do { try s.validate(); statusLabel.stringValue="工具路径检查通过" } catch { showError(error) }
        }
    }
    @objc func undoAction() { guard !busy else { return }; history.undo() }
    @objc func redoAction() { guard !busy else { return }; history.redo() }
}
