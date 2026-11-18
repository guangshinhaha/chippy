import CoreGraphics

/// Last good read of the frontmost app's menu bar item frames. An empty or failed read keeps the last good
/// one only for the SAME app; a different app, or lost Accessibility trust, drops it.
public struct AppMenuCache {
    private var pid: Int32?
    public private(set) var frames: [CGRect]?

    public init() {}

    @discardableResult
    public mutating func update(pid: Int32?, read: [CGRect]?, trusted: Bool) -> [CGRect]? {
        if !trusted || pid != self.pid { frames = nil }
        self.pid = pid
        if trusted, let read, !read.isEmpty { frames = read }
        return frames
    }
}
