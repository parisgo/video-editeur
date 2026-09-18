import AppKit
import AVKit
import SubtitleCore

let accent=NSColor(srgbRed:0.10,green:0.83,blue:0.80,alpha:1)
let panelColor=NSColor(srgbRed:0.115,green:0.125,blue:0.14,alpha:1)
let muted=NSColor(srgbRed:0.55,green:0.59,blue:0.64,alpha:1)
func label(_ text: String, size: CGFloat = 12, color: NSColor = .labelColor, bold: Bool = false) -> NSTextField {
    let l=NSTextField(labelWithString:text); l.font=bold ? .systemFont(ofSize:size,weight:.semibold) : .systemFont(ofSize:size); l.textColor=color; return l
}
final class ActionButton: NSButton {
    var actionBlock: (()->Void)?
    convenience init(_ title: String, symbol: String? = nil, action: @escaping ()->Void) {
        self.init(frame:.zero); self.title=title; if InterfaceLanguage.current == .en { font = .systemFont(ofSize:11) }; bezelStyle = .rounded; target=self; self.action=#selector(invoke); actionBlock=action
        if let symbol { image=NSImage(systemSymbolName:symbol,accessibilityDescription:title); imagePosition = .imageLeading }
    }
    @objc func invoke() { actionBlock?() }
}
final class PanelDivider: NSView {
    var onResize: ((CGFloat,Bool)->Void)?
    var onReset: (()->Void)?
    var isVertical=false
    private var previousY: CGFloat?
    private func coordinate(_ event:NSEvent) -> CGFloat { isVertical ? event.locationInWindow.x : event.locationInWindow.y }
    override init(frame:NSRect) {
        super.init(frame:frame)
        toolTip=L("上下拖动调整预览与时间轴高度；双击恢复默认")
        setAccessibilityElement(true); setAccessibilityRole(.splitter)
        setAccessibilityLabel(L("调整预览与时间轴高度"))
    }
    required init?(coder:NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds,cursor:isVertical ? .resizeLeftRight : .resizeUpDown) }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.white.withAlphaComponent(0.35).setFill()
        let grip=isVertical ? CGRect(x:bounds.midX-1.5,y:bounds.midY-24,width:3,height:48) : CGRect(x:bounds.midX-24,y:bounds.midY-1.5,width:48,height:3)
        NSBezierPath(roundedRect:grip,xRadius:1.5,yRadius:1.5).fill()
    }
    override func mouseDown(with event:NSEvent) {
        if event.clickCount == 2 { previousY=nil; onReset?(); return }
        previousY=coordinate(event)
    }
    override func mouseDragged(with event:NSEvent) {
        guard let y=previousY else { return }
        previousY=coordinate(event)
        onResize?(coordinate(event)-y,false)
    }
    override func mouseUp(with event:NSEvent) {
        guard previousY != nil else { return }
        previousY=nil; onResize?(0,true)
    }
}
final class LayoutView: NSView {
    var onLayout: (()->Void)?
    override func layout() { super.layout(); onLayout?() }
}
/// A wrapping editor must never horizontally scroll its first character away.
final class TextEditorClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect=super.constrainBoundsRect(proposedBounds)
        rect.origin.x=0
        return rect
    }
}
final class TextEditorScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let text=documentView as? NSTextView else { return }
        let width=max(1,contentSize.width)
        if text.frame.width != width || text.frame.minX != 0 {
            text.setFrameOrigin(NSPoint(x:0,y:text.frame.minY))
            text.setFrameSize(NSSize(width:width,height:text.frame.height))
        }
        if contentView.bounds.minX != 0 {
            contentView.scroll(to:NSPoint(x:0,y:contentView.bounds.minY))
        }
    }
}
final class SubtitleTableView: NSTableView {
    var onDeselect: (()->Void)?
    override func mouseDown(with event: NSEvent) {
        let blank=row(at:convert(event.locationInWindow,from:nil)) < 0
        super.mouseDown(with:event)
        if blank { onDeselect?() }
    }
}
final class DropView: NSView {
    var drop: ((URL)->Void)?
    override init(frame: NSRect) { super.init(frame:frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url=(sender.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:nil) as? [URL])?.first else { return false }; drop?(url); return true
    }
}
final class PreviewOverlay: NSView {
    var project=Project(); var time: Int64=0; var videoSize=CGSize(width:16,height:9)
    var editingEnabled=true
    var onDeselect: (()->Void)?
    var selected: UUID?; var onSelect: ((UUID)->Void)?
    var onGestureBegan: (()->Void)?
    var onStyleChange: ((UUID,SubtitleStyle,Bool)->Void)?
    var onGestureCancelled: (()->Void)?
    var eraseMode=false
    var eraseRect: CGRect?
    private var eraseAnchor: CGPoint?
    var onEraseStarted: ((CGPoint)->Void)?
    var onEraseSelected: (()->Void)?
    var onEraseCancelled: (()->Void)?
    var hitBoxes: [(UUID,CGRect)] = []
    private struct Gesture {
        var id: UUID
        var style: SubtitleStyle
        var origin: CGPoint
        var center: CGPoint
        var resizing: Bool
        var widthEdge: Int?
        var box: CGRect
        var changed=false
    }
    private var gesture: Gesture?
    override var acceptsFirstResponder: Bool { true }
    private func handles(_ rect: CGRect) -> [CGPoint] {
        let r=rect.insetBy(dx:-4,dy:-4)
        return [CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),CGPoint(x:r.minX,y:r.maxY),CGPoint(x:r.maxX,y:r.maxY)]
    }
    private func sideHandles(_ box: CGRect) -> [CGPoint] {
        [CGPoint(x:box.minX-4,y:box.midY),CGPoint(x:box.maxX+4,y:box.midY)]
    }
    private func resizeTarget(at point: CGPoint, box: CGRect) -> (corner: Bool, edge: Int?)? {
        // Small text brings corner and side hit areas together. Choose the nearest
        // visible control instead of letting a side handle steal corner drags.
        let corners=handles(box).map { ($0,true,Optional<Int>.none) }
        let sides=sideHandles(box).enumerated().map { ($0.element,false,Optional($0.offset)) }
        guard let target=(corners+sides).filter({ abs($0.0.x-point.x)<=10 && abs($0.0.y-point.y)<=10 })
            .min(by:{ hypot($0.0.x-point.x,$0.0.y-point.y) < hypot($1.0.x-point.x,$1.0.y-point.y) }) else { return nil }
        return (target.1,target.2)
    }
    var videoRect: CGRect {
        VideoGeometry.aspectFit(video:videoSize, container:bounds)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx=NSGraphicsContext.current?.cgContext else { return }
        let rect=videoRect
        ctx.saveGState(); ctx.translateBy(x:rect.minX,y:rect.minY)
        hitBoxes=SubtitleRenderer.draw(project:project,at:time,size:rect.size,context:ctx)
        if let item=hitBoxes.first(where: { $0.0 == selected }) {
            ctx.saveGState()
            ctx.setShadow(offset:CGSize(width:0,height:-1),blur:2,color:NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
            ctx.setLineWidth(1); ctx.stroke(item.1.insetBy(dx:-4,dy:-4))
            ctx.setFillColor(NSColor.white.cgColor)
            for point in handles(item.1) {
                ctx.fillEllipse(in:CGRect(x:point.x-4.5,y:point.y-4.5,width:9,height:9))
            }
            for point in sideHandles(item.1) {
                let grip=CGRect(x:point.x-2.5,y:point.y-5,width:5,height:10)
                ctx.addPath(CGPath(roundedRect:grip,cornerWidth:2.5,cornerHeight:2.5,transform:nil)); ctx.fillPath()
            }
            ctx.restoreGState()
        }
        if eraseMode,let region=eraseRect {
            let box=CGRect(x:region.minX*rect.width,y:region.minY*rect.height,width:region.width*rect.width,height:region.height*rect.height)
            ctx.setFillColor(accent.withAlphaComponent(0.13).cgColor); ctx.fill(box)
            ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1.5); ctx.setLineDash(phase:0,lengths:[5,3]); ctx.stroke(box)
            ctx.setLineDash(phase:0,lengths:[]); ctx.setFillColor(NSColor.white.cgColor)
            for point in [CGPoint(x:box.minX,y:box.minY),CGPoint(x:box.maxX,y:box.minY),CGPoint(x:box.minX,y:box.maxY),CGPoint(x:box.maxX,y:box.maxY)] { ctx.fillEllipse(in:CGRect(x:point.x-3,y:point.y-3,width:6,height:6)) }
        }
        ctx.restoreGState()
        window?.invalidateCursorRects(for:self)
    }
    override func resetCursorRects() {
        guard editingEnabled else { return }
        let r=videoRect
        if eraseMode { addCursorRect(r,cursor:.crosshair); return }
        for (_,box) in hitBoxes { addCursorRect(box.offsetBy(dx:r.minX,dy:r.minY),cursor:.openHand) }
        if let hit=hitBoxes.first(where:{$0.0 == selected}) {
            let band=min(6,(hit.1.height+8)/4)
            for p in sideHandles(hit.1) { addCursorRect(CGRect(x:p.x+r.minX-10,y:p.y+r.minY-band,width:20,height:band*2),cursor:.resizeLeftRight) }
            for p in handles(hit.1) { addCursorRect(CGRect(x:p.x+r.minX-10,y:p.y+r.minY-band,width:20,height:band*2),cursor:.crosshair) }
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard editingEnabled else { return }
        window?.makeFirstResponder(self)
        let location=convert(event.locationInWindow,from:nil),r=videoRect
        let point=CGPoint(x:location.x-r.minX,y:location.y-r.minY)
        if eraseMode {
            guard r.contains(location),r.width>0,r.height>0 else { return }
            eraseAnchor=CGPoint(x:point.x/r.width,y:point.y/r.height); eraseRect=nil; onEraseStarted?(eraseAnchor!); needsDisplay=true; return
        }
        let selectedHit=hitBoxes.first(where:{$0.0 == selected})
        let target=selectedHit.flatMap { resizeTarget(at:point,box:$0.1) }
        let widthEdge=target?.edge
        let onHandle=target?.corner ?? false
        let hit=(onHandle || widthEdge != nil) ? selectedHit : hitBoxes.reversed().first(where:{$0.1.insetBy(dx:-6,dy:-6).contains(point)})
        guard let hit,let cue=project.cues.first(where:{$0.id == hit.0}) else { onDeselect?(); return }
        onSelect?(hit.0)
        gesture=Gesture(id:hit.0,style:project.style(for:cue),origin:point,center:CGPoint(x:hit.1.midX,y:hit.1.midY),resizing:onHandle,widthEdge:widthEdge,box:hit.1)
    }
    override func mouseDragged(with event: NSEvent) {
        if eraseMode,editingEnabled,let anchor=eraseAnchor {
            let location=convert(event.locationInWindow,from:nil),r=videoRect
            guard r.width>0,r.height>0 else { return }
            let x=max(0,min(1,(location.x-r.minX)/r.width)),y=max(0,min(1,(location.y-r.minY)/r.height))
            eraseRect=CGRect(x:min(anchor.x,x),y:min(anchor.y,y),width:abs(anchor.x-x),height:abs(anchor.y-y)); needsDisplay=true; return
        }
        guard editingEnabled,var g=gesture, let cue=project.cues.first(where:{$0.id == g.id}) else { return }
        let location=convert(event.locationInWindow,from:nil),r=videoRect
        guard r.width>0,r.height>0 else { return }
        let point=CGPoint(x:location.x-r.minX,y:location.y-r.minY)
        if !g.changed { onGestureBegan?(); g.changed=true; gesture=g }
        var style=g.style
        if let edge=g.widthEdge {
            let box=VideoGeometry.resizedTextBox(g.box,delta:point.x-g.origin.x,leftEdge:edge == 0,videoWidth:r.width)
            style.width=box.width/r.width; style.x=box.midX/r.width
        } else if g.resizing {
            style.size=VideoGeometry.resizedFontSize(initial:g.style.size,anchor:g.center,handle:g.origin,pointer:point)
        } else {
            style.x=max(0,min(1,g.style.x+(point.x-g.origin.x)/r.width))
            style.y=max(0,min(1,g.style.y+(point.y-g.origin.y)/r.height))
        }
        project.applyStyle(style,for:cue)
        onStyleChange?(g.id,style,false); needsDisplay=true
    }
    override func mouseUp(with event: NSEvent) {
        if eraseMode {
            // Include the final pointer position even when drag events were coalesced.
            if eraseAnchor != nil { mouseDragged(with:event) }
            eraseAnchor=nil
            if let box=eraseRect,box.width*videoRect.width>=3,box.height*videoRect.height>=3 { onEraseSelected?() } else { eraseRect=nil }
            needsDisplay=true; return
        }
        if let g=gesture,g.changed,let cue=project.cues.first(where:{$0.id == g.id}) { onStyleChange?(g.id,project.style(for:cue),true) }
        gesture=nil; window?.invalidateCursorRects(for:self)
    }
    override func cancelOperation(_ sender: Any?) {
        if eraseMode { eraseAnchor=nil; eraseRect=nil; eraseMode=false; onEraseCancelled?(); needsDisplay=true; return }
        if gesture?.changed == true { onGestureCancelled?() }; gesture=nil; needsDisplay=true
    }

}
final class TimelineView: NSView {
    var project=Project(); var current: Int64=0; var selected: UUID? { didSet { needsDisplay=true; window?.invalidateCursorRects(for:self) } }; var pointsPerSecond: CGFloat=65
    var clipThumbnails: [UUID:[NSImage?]]=[:]
    var selectedMusic: UUID?
    var selectMusic: ((UUID)->Void)?
    var editMusic: (()->Void)?
    var moveMusic: ((BackgroundMusic)->Void)?
    private var musicDrag: (BackgroundMusic,CGFloat,Int)?
    var selectedClip: UUID?
    var selectVideo: ((UUID)->Void)?
    var editVideo: (()->Void)?
    var editVideoRange: ((UUID,Int64,Int64)->Void)?
    private var videoDrag: (VideoClip,CGFloat,Int)?
    var editingEnabled=true
    var onDeselect: (()->Void)?
    var select: ((UUID)->Void)?; var seek: ((Int64)->Void)?; var edit: ((UUID,Int64,Int64)->Void)?
    private var drag: (Cue,CGFloat,Int)?
    var leading: CGFloat=InterfaceLanguage.current == .en ? 104 : 84
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    func x(_ ms: Int64) -> CGFloat { leading+CGFloat(ms)/1000*pointsPerSecond }
    func ms(_ x: CGFloat) -> Int64 { max(0,min(project.duration,Int64(max(0,x-leading)/pointsPerSecond*1000))) }
    var videoY: CGFloat { 139+CGFloat(project.tracks.count)*44 }
    var contentHeight: CGFloat { videoY+66+CGFloat(project.music.count)*44 }
    func rect(_ cue: Cue) -> CGRect {
        let row=cue.trackID.flatMap { id in project.tracks.firstIndex(where:{$0.id == id}) }.map{$0+2} ?? (cue.language == .fr ? 0 : 1)
        return CGRect(x:x(cue.start),y:47+CGFloat(row)*44,width:max(2,x(cue.end)-x(cue.start)),height:32)
    }
    private func edgeHandle(_ cue: Cue, left: Bool) -> CGRect {
        let r=rect(cue)
        return CGRect(x:(left ? r.minX : r.maxX)-5,y:r.minY-2,width:10,height:r.height+4)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        guard editingEnabled else { return }
        for cue in project.cues where project.visible(cue) {
            addCursorRect(rect(cue),cursor:.openHand)
        }
        if let cue=project.cues.first(where:{$0.id == selected && project.visible($0)}) {
            addCursorRect(edgeHandle(cue,left:true),cursor:.resizeLeftRight)
            addCursorRect(edgeHandle(cue,left:false),cursor:.resizeLeftRight)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed:0.08,green:0.09,blue:0.105,alpha:1).setFill(); bounds.fill()
        let paragraph=NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        func text(_ s: String, _ rect: CGRect, _ color: NSColor = muted, _ size: CGFloat=10) {
            (s as NSString).draw(in:rect,withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:size,weight:.medium),.foregroundColor:color,.paragraphStyle:paragraph])
        }
        let step: Int = pointsPerSecond > 45 ? 1 : (pointsPerSecond > 15 ? 5 : 10)
        let first=max(0,Int((dirtyRect.minX-leading)/pointsPerSecond)/step*step), last=min(Int(project.timelineExtent/1000)+1,Int((dirtyRect.maxX-leading)/pointsPerSecond)+1)
        if first <= last { for sec in stride(from:first,through:last,by:step) {
            let px=x(Int64(sec)*1000); NSColor(white:0.23,alpha:1).setFill(); CGRect(x:px,y:28,width:1,height:bounds.height-28).fill()
            text(String(format:"%02d:%02d",sec/60,sec%60),CGRect(x:px+4,y:8,width:55,height:16))
        } }
        for (title,y) in [(L("FR · 法语"),55.0),(L("ZH · 中文"),99.0),(L("视频"),Double(videoY+14))] { text(title,CGRect(x:10,y:y,width:70,height:20)) }
        for (i,track) in project.tracks.enumerated() { text(track.name,CGRect(x:10,y:143+CGFloat(i)*44,width:70,height:20),accent) }
        for cue in project.cues where project.visible(cue) && rect(cue).intersects(dirtyRect) {
            let r=rect(cue); let visible=project.visible(cue)
            (cue.trackID != nil ? NSColor.systemTeal : cue.language == .fr ? NSColor(srgbRed:0.35,green:0.31,blue:0.61,alpha:visible ? 1:0.35) : NSColor(srgbRed:0.65,green:0.36,blue:0.24,alpha:visible ? 1:0.35)).setFill()
            NSBezierPath(roundedRect:r,xRadius:5,yRadius:5).fill()
            text(cue.text,r.insetBy(dx:7,dy:8),.white,11)

        }
        for p in project.placements {
            let r=CGRect(x:x(p.start),y:videoY,width:max(2,x(p.end)-x(p.start)),height:55)
            guard r.intersects(dirtyRect) else { continue }
            NSColor(srgbRed:0.10,green:0.31,blue:0.34,alpha:1).setFill(); r.fill()
            if let images=clipThumbnails[p.clip.id],!images.isEmpty {
                NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect:r).addClip()
                let first=max(0,Int((dirtyRect.minX-r.minX)/90)),last=min(Int(r.width/90),Int((dirtyRect.maxX-r.minX)/90))
                if first<=last { for i in first...last {
                    let ratio=min(0.999,(CGFloat(i)*90+45)/max(1,r.width))
                    let index=min(images.count-1,Int(ratio*CGFloat(images.count)))
                    guard let image=images[index] ?? images.compactMap({$0}).first else { continue }
                    let tile=CGRect(x:r.minX+CGFloat(i)*90,y:videoY+1,width:89,height:53)
                    // Fill each tile without stretching portrait footage.
                    let scale=max(tile.width/image.size.width,tile.height/image.size.height)
                    let sourceSize=CGSize(width:tile.width/scale,height:tile.height/scale)
                    let source=CGRect(x:(image.size.width-sourceSize.width)/2,y:(image.size.height-sourceSize.height)/2,width:sourceSize.width,height:sourceSize.height)
                    image.draw(in:tile,from:source,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
                } }
                NSGraphicsContext.restoreGraphicsState()
            }
            NSColor.black.withAlphaComponent(0.5).setFill()
            CGRect(x:r.minX,y:videoY+34,width:r.width,height:21).fill()
            text(URL(fileURLWithPath:p.clip.path).lastPathComponent,CGRect(x:r.minX+7,y:videoY+35,width:max(1,r.width-14),height:18),.white)
            if p.clip.transition>0 {
                let transition=CGRect(x:r.minX,y:videoY,width:CGFloat(p.clip.transition)/1000*pointsPerSecond,height:55)
                NSColor.systemOrange.withAlphaComponent(0.45).setFill(); transition.fill()
                text(L("叠化"),transition.insetBy(dx:3,dy:5),.white)
            }
            (selectedClip == p.clip.id ? NSColor.white : NSColor.black).setStroke()
            let border=NSBezierPath(rect:r.insetBy(dx:1,dy:1)); border.lineWidth=selectedClip == p.clip.id ? 2 : 1; border.stroke()
            if selectedClip == p.clip.id { for px in [r.minX,r.maxX-5] { NSColor.white.setFill(); CGRect(x:px,y:r.minY,width:5,height:r.height).fill() } }
        }
        // Draw selection after all clips so adjacent clips cannot cover its handles.
        if let cue=project.cues.first(where:{$0.id == selected && project.visible($0)}) {
            let r=rect(cue)
            NSColor.white.setStroke()
            let border=NSBezierPath(roundedRect:r.insetBy(dx:-1,dy:-1),xRadius:4,yRadius:4)
            border.lineWidth=2; border.stroke()
            for left in [true,false] {
                let handle=edgeHandle(cue,left:left)
                NSColor.white.setFill(); NSBezierPath(roundedRect:handle,xRadius:3,yRadius:3).fill()
                NSColor.black.withAlphaComponent(0.65).setFill()
                CGRect(x:handle.midX-1,y:handle.midY-6,width:2,height:12).fill()
            }
        }
        for (i,music) in project.music.enumerated() {
            let r=musicRect(music)
            text(L("音乐")+" \(i+1)",CGRect(x:8,y:r.minY+8,width:leading-12,height:20),muted,10)
            NSColor.systemGreen.withAlphaComponent(0.55).setFill(); NSBezierPath(roundedRect:r,xRadius:4,yRadius:4).fill()
            text(URL(fileURLWithPath:music.path).lastPathComponent,r.insetBy(dx:7,dy:7),.white,11)
            if music.id == selectedMusic { NSColor.white.setStroke(); let border=NSBezierPath(rect:r.insetBy(dx:1,dy:1)); border.lineWidth=2; border.stroke() }
        }
        let px=x(current); accent.setFill(); CGRect(x:px,y:29,width:1.5,height:bounds.height-29).fill()
        let head=NSBezierPath(); head.move(to:CGPoint(x:px-5,y:25)); head.line(to:CGPoint(x:px+5,y:25)); head.line(to:CGPoint(x:px,y:33)); head.close(); head.fill()
    }
    func musicRect(_ music: BackgroundMusic) -> CGRect {
        let index=project.music.firstIndex(where:{$0.id == music.id}) ?? 0
        return CGRect(x:x(music.start),y:videoY+66+CGFloat(index)*44,width:max(2,x(music.start+music.duration)-x(music.start)),height:32)
    }
    override func mouseDown(with event: NSEvent) {
        let p=convert(event.locationInWindow,from:nil)
        guard editingEnabled else { return }
        window?.makeFirstResponder(self)
        if let music=project.music.first(where:{ musicRect($0).contains(p) || (p.x<leading && (musicRect($0).minY...musicRect($0).maxY).contains(p.y)) }) {
            if p.x>=leading { seek?(ms(p.x)) }; selectMusic?(music.id); selectedMusic=music.id
            if event.clickCount == 2 { editMusic?(); return }
            let r=musicRect(music); musicDrag=(music,p.x,p.x-r.minX<8 ? -1 : r.maxX-p.x<8 ? 1 : 0); needsDisplay=true; return
        }
        if let p=project.placements.reversed().first(where:{CGRect(x:x($0.start),y:videoY,width:x($0.end)-x($0.start),height:55).contains(p)}) {
            selectVideo?(p.clip.id); selectedClip=p.clip.id
            let point=convert(event.locationInWindow,from:nil)
            seek?(ms(point.x))
            if event.clickCount == 2 { editVideo?(); return }
            let mode=abs(point.x-x(p.start))<8 ? -1 : abs(point.x-x(p.end))<8 ? 1 : 0
            if mode != 0 { videoDrag=(p.clip,point.x,mode) }
            needsDisplay=true; return
        }
        if let cue=project.cues.first(where:{$0.id == selected && project.visible($0)}),
           edgeHandle(cue,left:true).contains(p) || edgeHandle(cue,left:false).contains(p) {
            let left=abs(p.x-rect(cue).minX) <= abs(p.x-rect(cue).maxX)
            select?(cue.id); drag=(cue,p.x,left ? -1 : 1)
        } else if let cue=project.cues.first(where:{project.visible($0) && rect($0).contains(p)}) {
            select?(cue.id); let r=rect(cue)
            let edge=min(7,r.width/3)
            drag=(cue,p.x,p.x-r.minX < edge ? -1 : (r.maxX-p.x < edge ? 1 : 0))
        } else { seek?(ms(p.x)); if p.y>32 { onDeselect?() } }
    }
    override func mouseDragged(with event: NSEvent) {
        guard editingEnabled else { return }
        let p=convert(event.locationInWindow,from:nil)
        if let (original,origin,mode)=musicDrag,let index=project.music.firstIndex(where:{$0.id == original.id}) {
            let delta=Int64((p.x-origin)/pointsPerSecond*1000); var value=original
            if mode == 0 { value.start=max(0,min(max(0,project.duration-1),original.start+delta)) }
            else if mode == -1 {
                let change=max(-min(original.start,original.sourceStart),min(original.duration-1,delta)); value.start+=change; value.sourceStart+=change
            } else { value.sourceEnd=max(original.sourceStart+1,min(original.sourceDuration,original.sourceEnd+delta)) }
            project.backgroundMusic?[index]=value; needsDisplay=true; return
        }
        if let (original,origin,mode)=videoDrag {
            let delta=Int64((p.x-origin)/pointsPerSecond*1000)
            var clips=project.clips
            guard let i=clips.firstIndex(where:{$0.id == original.id}) else { return }
            if mode == -1 { clips[i].sourceStart=max(0,min(original.sourceEnd-1,original.sourceStart+delta)) }
            else { clips[i].sourceEnd=min(original.sourceDuration,max(original.sourceStart+1,original.sourceEnd+delta)) }
            if let next=try? project.replacingClips(clips) { project=next; needsDisplay=true }
            return
        }
        guard let (original,origin,mode)=drag,let index=project.cues.firstIndex(where:{$0.id == original.id}) else { seek?(ms(p.x)); return }
        let delta=Int64((p.x-origin)/pointsPerSecond*1000), range=project.allowedRange(for:original)
        var cue=original
        if mode == -1 { cue.start=max(range.lowerBound,min(original.end-1,original.start+delta)) }
        else if mode == 1 { cue.end=min(range.upperBound,max(original.start+1,original.end+delta)) }
        else { cue.start=max(range.lowerBound,min(range.upperBound-(original.end-original.start),original.start+delta)); cue.end=cue.start+(original.end-original.start) }
        project.cues[index]=cue; needsDisplay=true
    }
    override func mouseUp(with event: NSEvent) {
        if let (music,_,_)=musicDrag,let value=project.music.first(where:{$0.id == music.id}) { musicDrag=nil; moveMusic?(value); return }
        if let (clip,_,_)=videoDrag,let value=project.clips.first(where:{$0.id == clip.id}) {
            videoDrag=nil; editVideoRange?(clip.id,value.sourceStart,value.sourceEnd); return
        }
        if let (cue,_,_)=drag,let value=project.cues.first(where:{$0.id == cue.id}) { if value.start != cue.start || value.end != cue.end { edit?(cue.id,value.start,value.end) } }; drag=nil; window?.invalidateCursorRects(for:self)
    }
}

/// Brackets with a center cut; dotted brackets indicate the side being removed.
func timelineCutIcon(_ mode: Int) -> NSImage {
    let image=NSImage(size:NSSize(width:20,height:18),flipped:false) { _ in
        NSColor.labelColor.setStroke()
        let cut=NSBezierPath(); cut.lineWidth=1.5
        cut.move(to:NSPoint(x:10,y:2)); cut.line(to:NSPoint(x:10,y:16)); cut.stroke()
        for isLeft in [true,false] {
            let path=NSBezierPath(); path.lineWidth=1.5
            let edge: CGFloat=isLeft ? 3 : 17, inner: CGFloat=isLeft ? 7 : 13
            path.move(to:NSPoint(x:inner,y:3)); path.line(to:NSPoint(x:edge,y:3))
            path.line(to:NSPoint(x:edge,y:15)); path.line(to:NSPoint(x:inner,y:15))
            if (mode == 1 && isLeft) || (mode == 2 && !isLeft) { path.setLineDash([1.5,1.5],count:2,phase:0) }
            path.stroke()
        }
        return true
    }
    image.isTemplate=true; return image
}
