import Foundation
import CoreGraphics
public enum VideoGeometry {
    /// Keep the opposite edge fixed while moving one horizontal edge.
    public static func resizedTextBox(_ box: CGRect, delta: Double, leftEdge: Bool, videoWidth: Double) -> CGRect {
        guard videoWidth>0 else { return box }
        let minimum=videoWidth*0.1
        if leftEdge {
            let right=min(videoWidth,max(minimum,box.maxX))
            let left=max(0,min(right-minimum,box.minX+delta))
            return CGRect(x:left,y:box.minY,width:right-left,height:box.height)
        }
        let left=max(0,min(videoWidth-minimum,box.minX))
        let right=min(videoWidth,max(left+minimum,box.maxX+delta))
        return CGRect(x:left,y:box.minY,width:right-left,height:box.height)
    }

    public static func resizedFontSize(initial: Double, anchor: CGPoint, handle: CGPoint, pointer: CGPoint) -> Double {
        let dx=handle.x-anchor.x, dy=handle.y-anchor.y
        let lengthSquared=dx*dx+dy*dy
        guard lengthSquared > 0.001 else { return initial }
        let ratio=((pointer.x-anchor.x)*dx+(pointer.y-anchor.y)*dy)/lengthSquared
        return max(8,min(200,initial*ratio))
    }
    public static func aspectFit(video: CGSize, container: CGRect) -> CGRect {
        guard video.width > 0, video.height > 0 else { return .zero }
        let scale=min(container.width/video.width,container.height/video.height)
        let size=CGSize(width:video.width*scale,height:video.height*scale)
        return CGRect(x:container.midX-size.width/2,y:container.midY-size.height/2,width:size.width,height:size.height)
    }
    public static func anchoredBox(size: CGSize, video: CGSize, x: Double, y: Double) -> CGRect {
        let w=min(size.width,video.width),h=min(size.height,video.height)
        return CGRect(x:max(0,min(video.width-w,x*video.width-w/2)),y:max(0,min(video.height-h,y*video.height-h/2)),width:w,height:h)
    }
}
