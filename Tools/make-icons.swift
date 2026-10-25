import AppKit
for role in ["lei", "yu"] {
    let source = NSImage(contentsOfFile: "Assets/\(role).png")!
    let folder = "Work/\(role).iconset"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    for size in [16,32,128,256,512] {
        for scale in [1,2] {
            let pixels = size * scale
            let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            let context = NSGraphicsContext(bitmapImageRep:bitmap)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context; context.imageInterpolation = .high
            let width = CGFloat(pixels), height = width * source.size.height / source.size.width
            source.draw(in:NSRect(x:0,y:(width-height)/2,width:width,height:height))
            NSGraphicsContext.restoreGraphicsState()
            let suffix = scale == 2 ? "@2x" : ""
            try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"\(folder)/icon_\(size)x\(size)\(suffix).png"))
        }
    }
}
