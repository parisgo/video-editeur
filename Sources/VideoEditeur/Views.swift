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
        self.init(frame:.zero); self.title=title; bezelStyle = .rounded; target=self; self.action=#selector(invoke); actionBlock=action
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
        toolTip="上下拖动调整预览与时间轴高度；双击恢复默认"
        setAccessibilityElement(true); setAccessibilityRole(.splitter)
        setAccessibilityLabel("调整预览与时间轴高度")
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
        ctx.restoreGState()
        window?.invalidateCursorRects(for:self)
    }
    override func resetCursorRects() {
        guard editingEnabled else { return }
        let r=videoRect
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
        if let g=gesture,g.changed,let cue=project.cues.first(where:{$0.id == g.id}) { onStyleChange?(g.id,project.style(for:cue),true) }
        gesture=nil; window?.invalidateCursorRects(for:self)
    }
    override func cancelOperation(_ sender: Any?) {
        if gesture?.changed == true { onGestureCancelled?() }; gesture=nil; needsDisplay=true
    }

}
final class TimelineView: NSView {
    var project=Project(); var current: Int64=0; var selected: UUID? { didSet { needsDisplay=true; window?.invalidateCursorRects(for:self) } }; var pointsPerSecond: CGFloat=65
    var thumbnails: [NSImage]=[]
    var editingEnabled=true
    var onDeselect: (()->Void)?
    var select: ((UUID)->Void)?; var seek: ((Int64)->Void)?; var edit: ((UUID,Int64,Int64)->Void)?
    private var drag: (Cue,CGFloat,Int)?
    var leading: CGFloat=84
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    func x(_ ms: Int64) -> CGFloat { leading+CGFloat(ms)/1000*pointsPerSecond }
    func ms(_ x: CGFloat) -> Int64 { max(0,min(project.duration,Int64(max(0,x-leading)/pointsPerSecond*1000))) }
    var videoY: CGFloat { 139+CGFloat(project.tracks.count)*44 }
    var contentHeight: CGFloat { videoY+66 }
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
        let first=max(0,Int((dirtyRect.minX-leading)/pointsPerSecond)/step*step), last=min(Int(project.duration/1000)+1,Int((dirtyRect.maxX-leading)/pointsPerSecond)+1)
        if first <= last { for sec in stride(from:first,through:last,by:step) {
            let px=x(Int64(sec)*1000); NSColor(white:0.23,alpha:1).setFill(); CGRect(x:px,y:28,width:1,height:bounds.height-28).fill()
            text(String(format:"%02d:%02d",sec/60,sec%60),CGRect(x:px+4,y:8,width:55,height:16))
        } }
        for (title,y) in [("FR · 法语",55.0),("ZH · 中文",99.0),("视频",Double(videoY+14))] { text(title,CGRect(x:10,y:y,width:70,height:20)) }
        for (i,track) in project.tracks.enumerated() { text(track.name,CGRect(x:10,y:143+CGFloat(i)*44,width:70,height:20),accent) }
        for cue in project.cues where project.visible(cue) && rect(cue).intersects(dirtyRect) {
            let r=rect(cue); let visible=project.visible(cue)
            (cue.trackID != nil ? NSColor.systemTeal : cue.language == .fr ? NSColor(srgbRed:0.35,green:0.31,blue:0.61,alpha:visible ? 1:0.35) : NSColor(srgbRed:0.65,green:0.36,blue:0.24,alpha:visible ? 1:0.35)).setFill()
            NSBezierPath(roundedRect:r,xRadius:5,yRadius:5).fill()
            text(cue.text,r.insetBy(dx:7,dy:8),.white,11)

        }
        if project.duration > 0 {
            let r=CGRect(x:leading,y:videoY,width:CGFloat(project.duration)/1000*pointsPerSecond,height:55)
            NSColor(srgbRed:0.10,green:0.31,blue:0.34,alpha:1).setFill(); r.fill()
            if !thumbnails.isEmpty {
                NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect:r).addClip()
                let tileWidth: CGFloat=90
                let firstTile=max(0,Int((dirtyRect.minX-leading)/tileWidth)),lastTile=min(Int(r.width/tileWidth),Int((dirtyRect.maxX-leading)/tileWidth))
                if firstTile <= lastTile { for i in firstTile...lastTile {
                    let ratio=CGFloat(i)*tileWidth/max(1,r.width), index=min(thumbnails.count-1,Int(ratio*CGFloat(thumbnails.count)))
                    thumbnails[index].draw(in:CGRect(x:leading+CGFloat(i)*tileWidth,y:videoY+1,width:tileWidth-1,height:52),from:.zero,operation:.sourceOver,fraction:0.75,respectFlipped:true,hints:nil)
                } }
                NSGraphicsContext.restoreGraphicsState()
            }
            text(URL(fileURLWithPath:project.videoPath).lastPathComponent,CGRect(x:leading+7,y:videoY+37,width:250,height:17),.white)
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
        let px=x(current); accent.setFill(); CGRect(x:px,y:29,width:1.5,height:bounds.height-29).fill()
        let head=NSBezierPath(); head.move(to:CGPoint(x:px-5,y:25)); head.line(to:CGPoint(x:px+5,y:25)); head.line(to:CGPoint(x:px,y:33)); head.close(); head.fill()
    }
    override func mouseDown(with event: NSEvent) {
        let p=convert(event.locationInWindow,from:nil)
        guard editingEnabled else { return }
        window?.makeFirstResponder(self)
        if let cue=project.cues.first(where:{$0.id == selected && project.visible($0)}),
           edgeHandle(cue,left:true).contains(p) || edgeHandle(cue,left:false).contains(p) {
            let left=abs(p.x-rect(cue).minX) <= abs(p.x-rect(cue).maxX)
            select?(cue.id); drag=(cue,p.x,left ? -1 : 1)
        } else if let cue=project.cues.first(where:{project.visible($0) && rect($0).contains(p)}) {
            select?(cue.id); let r=rect(cue)
            let edge=min(7,r.width/3)
            drag=(cue,p.x,p.x-r.minX < edge ? -1 : (r.maxX-p.x < edge ? 1 : 0))
        } else { seek?(ms(p.x)); onDeselect?() }
    }
    override func mouseDragged(with event: NSEvent) {
        guard editingEnabled else { return }
        let p=convert(event.locationInWindow,from:nil)
        guard let (original,origin,mode)=drag,let index=project.cues.firstIndex(where:{$0.id == original.id}) else { seek?(ms(p.x)); return }
        let delta=Int64((p.x-origin)/pointsPerSecond*1000), range=project.allowedRange(for:original)
        var cue=original
        if mode == -1 { cue.start=max(range.lowerBound,min(original.end-1,original.start+delta)) }
        else if mode == 1 { cue.end=min(range.upperBound,max(original.start+1,original.end+delta)) }
        else { cue.start=max(range.lowerBound,min(range.upperBound-(original.end-original.start),original.start+delta)); cue.end=cue.start+(original.end-original.start) }
        project.cues[index]=cue; needsDisplay=true
    }
    override func mouseUp(with event: NSEvent) {
        if let (cue,_,_)=drag,let value=project.cues.first(where:{$0.id == cue.id}) { if value.start != cue.start || value.end != cue.end { edit?(cue.id,value.start,value.end) } }; drag=nil; window?.invalidateCursorRects(for:self)
    }
}
