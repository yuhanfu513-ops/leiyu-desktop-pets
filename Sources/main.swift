import AppKit
import AVFoundation
import Darwin

// Window and drag interaction adapted from SunPet; see LICENSE-SunPet.
enum Role: String, Codable {
    case lei, yu
    var name: String { self == .lei ? "雷军" : "余承东" }
    var appName: String { name + "桌宠" }
    var other: Role { self == .lei ? .yu : .lei }
    var bundleID: String { "local.leiyupets." + rawValue }
}
struct ClipLine: Codable {
    let start: Double
    let end: Double
    let text: String
}
struct Clip: Codable {
    let id: Int
    let role: Role
    let text: String
    let file: String
    let duration: Double
    let lines: [ClipLine]?
    var timedLines: [ClipLine] {
        if let lines, !lines.isEmpty { return lines }
        return [ClipLine(start:0,end:duration,text:text)]
    }
}
struct DialoguePair: Codable {
    let id: Int
    let lei: Int
    let yu: Int
}
struct Dialogue: Codable {
    var id: String
    var stage: String
    var pairID: Int?
    var leiToken: String?
    var yuToken: String?
    var initiator: String
    var created: Double
}
struct ShuffleBag {
    var remaining: [Int] = []
    var last: Int?
    mutating func next(_ count: Int) -> Int? {
        guard count > 0 else { return nil }
        if remaining.isEmpty {
            remaining = Array(0..<count).shuffled()
            if count > 1 && remaining.last == last { remaining.swapAt(0,count-1) }
        }
        last = remaining.removeLast(); return last
    }
}
struct SharedSettings: Codable {
    var volume: Float = 0.65
    var distance: Double = 32
    var enabled = true
}
struct PeerState: Codable {
    let role: String
    let session: String
    let pid: Int32
    let time: Double
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let playing: Bool
    let animating: Bool
    let angle: Double
    let compression: Double
    let clipID: Int?
    let subtitle: String
    let plays: Int
    var rect: NSRect { NSRect(x:x,y:y,width:width,height:height) }
    func isFresh(now: Double) -> Bool {
        let age = now-time
        return age >= 0 && age < 1.5 && [x,y,width,height].allSatisfy { $0.isFinite } && width > 0 && height > 0
    }
}
struct PlaybackClaim: Codable {
    let session: String
    let token: String
}
struct Proximity {
    static func gap(_ a: NSRect, _ b: NSRect) -> Double {
        hypot(max(0,max(a.minX-b.maxX,b.minX-a.maxX)),max(0,max(a.minY-b.maxY,b.minY-a.maxY)))
    }
    static func angle(dx: Double) -> Double { dx >= 0 ? -0.20 : 0.20 }
}
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
final class PortraitView: NSView {
    var portrait: NSImage?
    var compression: CGFloat = 1 { didSet { needsDisplay = true } }
    var angle: CGFloat = 0 { didSet { needsDisplay = true } }
    var bob: CGFloat = 0 { didSet { needsDisplay = true } }
    var imageRect: NSRect { NSRect(x:48,y:16,width:bounds.width-96,height:bounds.height-48) }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let r = imageRect
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by:r.midX,yBy:r.minY)
        t.rotate(byRadians:angle)
        t.scaleX(by:1,yBy:compression)
        t.translateX(by:-r.midX,yBy:-r.minY)
        t.translateX(by:0,yBy:bob)
        t.concat()
        portrait?.draw(in:r,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
    }
}
final class Caption: NSView {
    var text: String = "" { didSet { needsDisplay = true } }
    var font: NSFont = .systemFont(ofSize:13,weight:.medium) { didSet { needsDisplay = true } }
    private let horizontalPadding: CGFloat = 10
    private let verticalPadding: CGFloat = 6
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private var lineHeight: CGFloat { ceil(font.ascender-font.descender+font.leading) }
    private var textAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        return [.font:font,.foregroundColor:NSColor.white,.paragraphStyle:paragraph]
    }
    func sizeThatFits(maxWidth: CGFloat) -> NSSize {
        let contentWidth = max(1,maxWidth-horizontalPadding*2)
        let rect = (text as NSString).boundingRect(with:NSSize(width:contentWidth,height:.greatestFiniteMagnitude),
                                                   options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:textAttributes)
        let minimum = ceil(lineHeight)+verticalPadding*2
        let maximum = ceil(lineHeight)*4+verticalPadding*2
        let width = min(maxWidth,ceil(rect.width)+horizontalPadding*2)
        return NSSize(width:width,height:min(max(ceil(rect.height)+verticalPadding*2,minimum),maximum))
    }
    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect:bounds,xRadius:9,yRadius:9).fill()
        let inset = bounds.insetBy(dx:horizontalPadding,dy:verticalPadding)
        let measured = (text as NSString).boundingRect(with:NSSize(width:inset.width,height:.greatestFiniteMagnitude),
                                                       options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:textAttributes)
        let rect = NSRect(x:inset.minX,y:inset.minY+max(0,(inset.height-measured.height)/2),
                          width:inset.width,height:min(measured.height,inset.height))
        (text as NSString).draw(with:rect,options:[.usesLineFragmentOrigin,.usesFontLeading,.truncatesLastVisibleLine],attributes:textAttributes)
    }
}
final class PetView: NSView {
    weak var owner: PetApp?
    let face = PortraitView()
    let caption = Caption()
    var startMouse = NSPoint.zero
    var startOrigin = NSPoint.zero
    var dragged = false
    var speaking = false
    var targetAngle: CGFloat = 0
    var animationTimer: Timer?
    var phase = 0.0
    override init(frame: NSRect) {
        super.init(frame:frame)
        wantsLayer = true
        addSubview(face)
        caption.font = .systemFont(ofSize:13,weight:.medium)
        caption.isHidden = true
        addSubview(caption)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        toolTip = "点击说一段 · 靠近点一下两人对话 · 拖近互相歪头 · 右键设置"
    }
    required init?(coder:NSCoder) { fatalError("Unsupported coder") }
    override var isOpaque: Bool { false }
    override func layout() {
        super.layout()
        face.frame = NSRect(x:0,y:0,width:bounds.width,height:bounds.height-64)
        updateCaptionLayout()
    }
    func updateCaptionLayout() {
        let maxWidth = min(bounds.width-12,face.imageRect.width+48)
        let size = caption.sizeThatFits(maxWidth:maxWidth)
        let imageTop = face.frame.minY+face.imageRect.maxY
        caption.frame = NSRect(x:(bounds.width-size.width)/2,y:imageTop+4,width:size.width,height:size.height)
    }
    func setCaption(_ text: String) {
        caption.text = text
        caption.isHidden = text.isEmpty
        updateCaptionLayout()
    }
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    override func mouseDown(with event:NSEvent) {
        startMouse = window?.convertPoint(toScreen:event.locationInWindow) ?? NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero; dragged = false
    }
    override func mouseDragged(with event:NSEvent) {
        let current = window?.convertPoint(toScreen:event.locationInWindow) ?? NSEvent.mouseLocation
        let dx = current.x-startMouse.x, dy=current.y-startMouse.y
        if hypot(dx,dy)>4 { dragged=true }
        if dragged { window?.setFrameOrigin(NSPoint(x:startOrigin.x+dx,y:startOrigin.y+dy)) }
    }
    override func mouseUp(with event:NSEvent) {
        if dragged { owner?.savePosition() } else { owner?.playNext() }
    }
    override func rightMouseDown(with event:NSEvent) {
        guard let menu=owner?.makeMenu() else { return }
        NSMenu.popUpContextMenu(menu,with:event,for:self)
    }
    override func accessibilityPerformPress() -> Bool { owner?.playNext(); return true }
    func setSpeaking(_ value:Bool) {
        guard speaking != value else { return }
        speaking=value
        if !value { face.compression=1;face.bob=0 }
        updateAnimation()
    }
    func setTilt(_ angle:CGFloat) {
        guard abs(angle-targetAngle)>0.001 else { return }
        targetAngle=angle; updateAnimation()
    }
    func updateAnimation() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            animationTimer?.invalidate();animationTimer=nil;face.compression=1;face.bob=0;face.angle=targetAngle;return
        }
        guard speaking || abs(face.angle-targetAngle)>0.001 else {
            animationTimer?.invalidate();animationTimer=nil;face.compression=1;face.bob=0;face.angle=targetAngle;return
        }
        guard animationTimer == nil else { return }
        phase=0
        let timer=Timer(timeInterval:1.0/30,repeats:true) { [weak self] _ in
            guard let self else { return }
            self.face.angle += (self.targetAngle-self.face.angle)*0.22
            if self.speaking {
                self.phase += 0.50
                let pulse=(1-cos(self.phase))/2
                self.face.compression=1-0.14*pulse
                self.face.bob=5*pulse
            } else { self.face.compression=1;self.face.bob=0 }
            if !self.speaking && abs(self.face.angle-self.targetAngle)<0.001 { self.updateAnimation() }
        }
        animationTimer=timer;RunLoop.main.add(timer,forMode:.common)
    }
}
struct TestCommand: Decodable {
    let id:String
    let action:String
    let x:Double?
    let y:Double?
    let clipID:Int?
    let pairID:Int?
}
final class PetApp: NSObject, NSApplicationDelegate, AVAudioPlayerDelegate {
    let role=Role(rawValue:Bundle.main.object(forInfoDictionaryKey:"PetRole") as? String ?? "lei")!
    let session=UUID().uuidString
    let selfTest=CommandLine.arguments.contains("--self-test")
    var integrationRoot:URL? {
        let args=CommandLine.arguments
        if let i=args.firstIndex(of:"--integration-test"),i+1<args.count { return URL(fileURLWithPath:args[i+1]) }
        return nil
    }
    var testing:Bool { selfTest || integrationRoot != nil }
    lazy var stateDirectory:URL = integrationRoot ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("LeiYuDesktopPets",isDirectory:true)
    var settingsURL:URL { stateDirectory.appendingPathComponent("settings.json") }
    var claimURL:URL { stateDirectory.appendingPathComponent("playback.json") }
    var dialogueURL:URL { stateDirectory.appendingPathComponent("dialogue.json") }
    func stateURL(_ r:Role)->URL { stateDirectory.appendingPathComponent(r.rawValue+".json") }
    var settings=SharedSettings()
    var allClips:[Clip]=[]
    var clips:[Clip]=[]
    var pairs:[DialoguePair]=[]
    var bag=ShuffleBag()
    var pairBag=ShuffleBag()
    var currentClip:Clip?
    var pending:(Clip,String)?
    var activeToken:String?
    var lockFD:Int32 = -1
    var hasLock=false
    var near=false
    var panel:PetPanel!
    var pet:PetView!
    var status:NSStatusItem?
    var player:AVAudioPlayer?
    var pollTimer:Timer?
    var captionHideWork:DispatchWorkItem?
    var activeLines:[ClipLine]=[]
    var activeLineIndex = -1
    var activeDialogue:Dialogue?
    var dialogueStage:String?
    var lastYuToken=""
    var size:CGFloat=220
    var imageRatio:CGFloat=1
    var plays=0
    var peer:PeerState?
    var lastCommand=""
    var started=false
    let playbackName=Notification.Name("local.leiyupets.playbackChanged.v2")
    var panelSize:NSSize { NSSize(width:size+96,height:size*imageRatio+112) }
    var resources:URL { Bundle.main.resourceURL! }
    func clipURL(_ c:Clip)->URL { resources.appendingPathComponent("Clips/"+c.file) }
    func applicationDidFinishLaunching(_ notification:Notification) {
        if !testing && NSRunningApplication.runningApplications(withBundleIdentifier:role.bundleID).contains(where:{$0.processIdentifier != getpid()}) { NSApp.terminate(nil);return }
        guard let image=NSImage(contentsOf:resources.appendingPathComponent("face.png")),image.size.width>0 else { fail("人物图片无法读取");return }
        do {
            allClips=try JSONDecoder().decode([Clip].self,from:Data(contentsOf:resources.appendingPathComponent("clips.json")))
            clips=allClips.filter{$0.role==role}
            guard !clips.isEmpty else { throw NSError(domain:"没有该人物的台词",code:1) }
            for c in clips { guard FileManager.default.fileExists(atPath:clipURL(c).path) else { throw NSError(domain:"缺少台词音频",code:c.id) } }
            if let data=try? Data(contentsOf:resources.appendingPathComponent("pairs.json")) {
                pairs=(try? JSONDecoder().decode([DialoguePair].self,from:data)) ?? []
            }
            if !selfTest {
                try FileManager.default.createDirectory(at:stateDirectory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                lockFD=Darwin.open(stateDirectory.appendingPathComponent("audio.lock").path,O_CREAT|O_RDWR,0o600)
                guard lockFD>=0 else { throw NSError(domain:"无法协调音频播放",code:2) }
            }
        } catch { fail(error.localizedDescription);return }
        imageRatio=image.size.height/image.size.width
        if !testing,UserDefaults.standard.object(forKey:"size") != nil { size=min(max(UserDefaults.standard.double(forKey:"size"),150),340) }
        panel=PetPanel(contentRect:NSRect(origin:.zero,size:panelSize),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.title=role.appName;panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=false
        panel.level = .floating;panel.hidesOnDeactivate=false;panel.isReleasedWhenClosed=false
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
        pet=PetView(frame:NSRect(origin:.zero,size:panelSize));pet.owner=self;pet.face.portrait=image
        pet.setAccessibilityLabel("\(role.name)桌宠，点击播放一段自己的台词；靠近时点击两位会由雷军先说、余承东后说")
        panel.contentView=pet;restorePosition();pet.layoutSubtreeIfNeeded()
        if selfTest { runSelfTest();return }
        if integrationRoot==nil {
            panel.orderFrontRegardless()
            status=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
            status?.button?.title=role.name;status?.button?.target=self;status?.button?.action=#selector(openMenu)
            showCaption("点我说一段 · 靠近点一下两人对话",seconds:4)
        }
        DistributedNotificationCenter.default().addObserver(self,selector:#selector(playbackChanged),name:playbackName,object:stateDirectory.path)
        started=true;tick()
        let timer=Timer(timeInterval:0.10,repeats:true){[weak self] _ in self?.tick()}
        pollTimer=timer;RunLoop.main.add(timer,forMode:.common)
    }
    func fail(_ text:String) {
        if testing { fputs("FAIL: \(text)\n",stderr);exit(1) }
        let a=NSAlert();a.messageText="桌宠无法启动";a.informativeText=text;a.runModal();NSApp.terminate(nil)
    }
    func readSettings()->SharedSettings {
        guard let data=try? Data(contentsOf:settingsURL),var v=try? JSONDecoder().decode(SharedSettings.self,from:data),v.volume.isFinite,v.distance.isFinite else { return SharedSettings() }
        v.volume=min(max(v.volume,0),1);v.distance=min(max(v.distance,0),100);return v
    }
    func changeSettings(_ change:(inout SharedSettings)->Void) {
        var v=readSettings();change(&v)
        do { try JSONEncoder().encode(v).write(to:settingsURL,options:.atomic);settings=v }
        catch { showCaption("设置保存失败",seconds:3) }
    }
    func readPeer()->PeerState? {
        guard let data=try? Data(contentsOf:stateURL(role.other)),let v=try? JSONDecoder().decode(PeerState.self,from:data),v.role==role.other.rawValue,v.isFresh(now:ProcessInfo.processInfo.systemUptime),let app=NSRunningApplication(processIdentifier:v.pid),!app.isTerminated,app.bundleIdentifier==role.other.bundleID else { return nil }
        return v
    }
    var portraitRect:NSRect { panel.convertToScreen(pet.face.convert(pet.face.imageRect,to:nil)) }
    func publish() {
        let r=portraitRect
        let v=PeerState(role:role.rawValue,session:session,pid:getpid(),time:ProcessInfo.processInfo.systemUptime,x:r.minX,y:r.minY,width:r.width,height:r.height,playing:player?.isPlaying==true,animating:pet.speaking,angle:pet.face.angle,compression:pet.face.compression,clipID:currentClip?.id,subtitle:pet.caption.isHidden ? "" : pet.caption.text,plays:plays)
        try? JSONEncoder().encode(v).write(to:stateURL(role),options:.atomic)
    }
    func claim()->PlaybackClaim? {
        guard let data=try? Data(contentsOf:claimURL) else { return nil }
        return try? JSONDecoder().decode(PlaybackClaim.self,from:data)
    }
    func postPlaybackChange() {
        DistributedNotificationCenter.default().postNotificationName(playbackName,object:stateDirectory.path,userInfo:nil,deliverImmediately:true)
    }
    @objc func playbackChanged() { reconcilePlayback();if started { publish() } }
    func reconcilePlayback() {
        let owner=claim()
        if let token=activeToken,owner?.session != session || owner?.token != token { stopLocal() }
        guard let (clip,token)=pending else { return }
        guard owner?.session==session && owner?.token==token else { pending=nil;return }
        guard lockFD>=0,flock(lockFD,LOCK_EX|LOCK_NB)==0 else { return }
        hasLock=true
        guard let latest=claim(),latest.session==session,latest.token==token else { releaseLock();pending=nil;return }
        pending=nil
        do {
            let audio=try AVAudioPlayer(contentsOf:clipURL(clip))
            audio.volume=testing ? 0 : settings.volume;audio.delegate=self;audio.prepareToPlay()
            guard audio.play() else { throw NSError(domain:"音频播放失败",code:1) }
            player=audio;activeToken=token;currentClip=clip;plays += 1
            activeLines=clip.timedLines;activeLineIndex = -1
            updateSubtitle(for:0)
            scheduleCaptionHide(after:max(clip.duration+0.4,1.2))
            pet.setSpeaking(true)
        } catch {
            let failed=activeDialogue
            stopLocal()
            if let d=failed { var done=d;done.stage="done";writeDialogue(done) }
            showCaption("这句暂时无法播放，请退出后重新打开桌宠",seconds:4)
        }
    }
    func tick() {
        if integrationRoot != nil { handleTestCommand() }
        settings=readSettings();player?.volume=testing ? 0 : settings.volume
        reconcilePlayback()
        reconcileDialogue()
        if let player,player.isPlaying { updateSubtitle(for:player.currentTime) }
        peer=readPeer()
        if let peer {
            let gap=Proximity.gap(portraitRect,peer.rect)
            if gap<=settings.distance { near=true }
            else if gap>settings.distance+24 { near=false }
            let dx=peer.rect.midX-portraitRect.midX
            pet.setTilt(settings.enabled && near ? Proximity.angle(dx:abs(dx)>0.5 ? dx : (role == .lei ? 1 : -1)) : 0)
        } else { near=false;pet.setTilt(0) }
        pet.setSpeaking(player?.isPlaying==true)
        publish()
    }
    func isNearNow() -> Bool {
        guard let peer=readPeer() else { return false }
        return Proximity.gap(portraitRect,peer.rect) <= settings.distance
    }
    @objc func playNext() {
        if isNearNow(),!pairs.isEmpty { requestPair();return }
        playSoloNext()
    }
    @objc func playSoloNext() { if let index=bag.next(clips.count) { requestPlayback(clips[index]) } }
    @objc func startDuet() {
        guard !pairs.isEmpty else { showCaption("还没有配对台词",seconds:3);return }
        guard isNearNow() else { showCaption("先把两位拖近一点",seconds:3);return }
        requestPair()
    }
    func requestPair(_ pairID:Int? = nil) {
        guard !pairs.isEmpty,isNearNow() else { return }
        let d=Dialogue(id:UUID().uuidString,stage:"request",pairID:pairID,leiToken:nil,yuToken:nil,initiator:session,created:ProcessInfo.processInfo.systemUptime)
        writeDialogue(d)
        if role == .lei { reconcileDialogue() }
        if started { publish() }
    }
    func readDialogue() -> Dialogue? {
        guard let data=try? Data(contentsOf:dialogueURL),let d=try? JSONDecoder().decode(Dialogue.self,from:data),d.created.isFinite else { return nil }
        let age=ProcessInfo.processInfo.systemUptime-d.created
        return age>=0 && age<30 ? d : nil
    }
    func writeDialogue(_ d:Dialogue) {
        try? JSONEncoder().encode(d).write(to:dialogueURL,options:.atomic)
    }
    func cancelDialogueFile() {
        guard var d=readDialogue(),d.stage != "done" else { return }
        d.stage="done";writeDialogue(d)
    }
    func pair(for d:Dialogue) -> DialoguePair? {
        guard let id=d.pairID else { return nil }
        return pairs.first{$0.id==id}
    }
    func nextPair(for d:Dialogue) -> DialoguePair? {
        if let p=pair(for:d) { return p }
        guard let index=pairBag.next(pairs.count) else { return nil }
        return pairs[index]
    }
    func reconcileDialogue() {
        guard let d=readDialogue() else { return }
        if role == .lei { reconcileLeaderDialogue(d) } else { reconcileFollowerDialogue(d) }
    }
    func reconcileLeaderDialogue(_ d:Dialogue) {
        if d.stage=="done" { activeDialogue=nil;dialogueStage=nil;return }
        if d.stage=="request" {
            guard let p=nextPair(for:d) else { return }
            var next=d
            next.stage="lei";next.pairID=p.id
            next.leiToken=UUID().uuidString;next.yuToken=UUID().uuidString
            writeDialogue(next)
            guard let clip=clips.first(where:{$0.id==p.lei}) else { next.stage="done";writeDialogue(next);return }
            requestPlayback(clip,dialogue:next)
            return
        }
        if d.stage=="lei",activeDialogue?.id != d.id,let p=pair(for:d),let clip=clips.first(where:{$0.id==p.lei}) {
            requestPlayback(clip,dialogue:d)
        }
    }
    func reconcileFollowerDialogue(_ d:Dialogue) {
        if d.stage=="done" { activeDialogue=nil;dialogueStage=nil;return }
        guard d.stage=="yu",let p=pair(for:d),let token=d.yuToken,token != lastYuToken,let clip=clips.first(where:{$0.id==p.yu}) else { return }
        lastYuToken=token
        requestPlayback(clip,dialogue:d)
    }
    func requestPlayback(_ clip:Clip,dialogue:Dialogue? = nil) {
        stopLocal()
        activeDialogue=dialogue
        dialogueStage=dialogue?.stage
        if dialogue == nil { cancelDialogueFile() }
        let token=UUID().uuidString
        do {
            try JSONEncoder().encode(PlaybackClaim(session:session,token:token)).write(to:claimURL,options:.atomic)
            pending=(clip,token);postPlaybackChange();reconcilePlayback()
            if started { publish() }
        } catch {
            stopLocal()
            if let d=dialogue { var done=d;done.stage="done";writeDialogue(done) }
            showCaption("暂时无法开始播放，请退出后重新打开桌宠",seconds:4)
        }
    }
    func releaseLock() { if hasLock { _=flock(lockFD,LOCK_UN);hasLock=false } }
    func stopLocal(keepCaption: Bool = false) {
        pending=nil;player?.stop();player=nil;activeToken=nil;currentClip=nil
        activeLines=[];activeLineIndex = -1
        activeDialogue=nil;dialogueStage=nil
        pet?.setSpeaking(false)
        if !keepCaption { hideCaption() }
        releaseLock()
    }
    @objc func stopAll() {
        cancelDialogueFile()
        stopLocal()
        try? JSONEncoder().encode(PlaybackClaim(session:"stopped",token:UUID().uuidString)).write(to:claimURL,options:.atomic)
        postPlaybackChange()
    }
    func audioPlayerDidFinishPlaying(_ player:AVAudioPlayer,successfully flag:Bool) {
        guard player === self.player else { return }
        if let d=activeDialogue,dialogueStage=="lei" {
            stopLocal()
            var next=d;next.stage="yu";writeDialogue(next)
            if started { publish() }
            return
        }
        if let d=activeDialogue,dialogueStage=="yu" {
            stopLocal(keepCaption:true);scheduleCaptionHide(after:0.4)
            var done=d;done.stage="done";writeDialogue(done)
            if started { publish() }
            return
        }
        stopLocal(keepCaption:true);scheduleCaptionHide(after:0.4)
        if started { publish() }
    }
    func audioPlayerDecodeErrorDidOccur(_ player:AVAudioPlayer,error:Error?) {
        guard player === self.player else { return }
        if let d=activeDialogue { var done=d;done.stage="done";writeDialogue(done) }
        stopLocal();showCaption("音频播放中断，请退出后重新打开桌宠",seconds:4)
    }
    func updateSubtitle(for time:Double) {
        guard !activeLines.isEmpty else { return }
        var index=0
        for (i,line) in activeLines.enumerated() where time >= line.start { index=i }
        guard index != activeLineIndex else { return }
        activeLineIndex=index
        pet.setCaption(activeLines[index].text)
    }
    func showSubtitle(_ text:String,minimum:Double) {
        captionHideWork?.cancel()
        pet.setCaption(text)
        let work=DispatchWorkItem{[weak self] in self?.pet.setCaption("")}
        captionHideWork=work
        DispatchQueue.main.asyncAfter(deadline:.now()+minimum,execute:work)
    }
    func scheduleCaptionHide(after seconds:Double) {
        captionHideWork?.cancel()
        let work=DispatchWorkItem{[weak self] in self?.pet.setCaption("")}
        captionHideWork=work
        DispatchQueue.main.asyncAfter(deadline:.now()+seconds,execute:work)
    }
    func hideCaption() {
        captionHideWork?.cancel();captionHideWork=nil;pet?.setCaption("")
    }
    func showCaption(_ text:String,seconds:Double) {
        // Never replace a running sentence's subtitle with a transient notice.
        guard pet?.speaking != true else { return }
        showSubtitle(text,minimum:seconds)
    }
    func defaultOrigin()->NSPoint {
        guard let s=NSScreen.main ?? NSScreen.screens.first else { return .zero }
        return NSPoint(x:s.visibleFrame.minX+(role == .lei ? 24 : 440),y:s.visibleFrame.minY+24)
    }
    func restorePosition() {
        if !testing,UserDefaults.standard.object(forKey:"x") != nil {
            let p=NSPoint(x:UserDefaults.standard.double(forKey:"x"),y:UserDefaults.standard.double(forKey:"y"))
            let r=NSRect(origin:p,size:panelSize)
            if NSScreen.screens.contains(where:{$0.visibleFrame.intersection(r).width>=80 && $0.visibleFrame.intersection(r).height>=80}) { panel.setFrameOrigin(p);return }
        }
        panel.setFrameOrigin(defaultOrigin())
    }
    func savePosition() {
        guard !testing,let panel else { return }
        UserDefaults.standard.set(panel.frame.origin.x,forKey:"x");UserDefaults.standard.set(panel.frame.origin.y,forKey:"y")
    }
    @objc func resetPosition() { panel.setFrameOrigin(defaultOrigin());savePosition() }
    func item(_ title:String,_ action:Selector?,tag:Int=0)->NSMenuItem {
        let i=NSMenuItem(title:title,action:action,keyEquivalent:"");i.target=self;i.tag=tag;return i
    }
    @objc func openMenu() { status?.menu=makeMenu();status?.button?.performClick(nil);status?.menu=nil }
    func makeMenu()->NSMenu {
        settings=readSettings();let m=NSMenu()
        let title=item("\(role.appName) · \(clips.count)段",nil);title.isEnabled=false;m.addItem(title)
        m.addItem(item("随机说一段",#selector(playSoloNext)))
        m.addItem(item("两人对话一句",#selector(startDuet)))
        let choose=item("挑一段",nil), choices=NSMenu()
        for c in clips { choices.addItem(item(c.text.replacingOccurrences(of:"\n",with:" "),#selector(chooseClip(_:)),tag:c.id)) }
        choose.submenu=choices;m.addItem(choose)
        m.addItem(item("停止播放",#selector(stopAll)))
        m.addItem(item("打开\(role.other.name)桌宠",#selector(openOther)))
        m.addItem(.separator())
        let enabled=item("靠近时互相歪头",#selector(toggleTilt));enabled.state=settings.enabled ? .on:.off;m.addItem(enabled)
        let volume=item("音量",nil), volumes=NSMenu()
        for value in [0,25,50,65,80,100] {
            let option=item(value==0 ? "静音":"\(value)%",#selector(setVolume(_:)),tag:value)
            option.state=abs(settings.volume-Float(value)/100)<0.01 ? .on:.off;volumes.addItem(option)
        }
        volume.submenu=volumes;m.addItem(volume)
        let distance=item("歪头距离",nil), distances=NSMenu()
        for (name,value) in [("贴近",8),("靠近",32),("较远",80)] {
            let o=item(name,#selector(setDistance(_:)),tag:value);o.state=Int(settings.distance)==value ? .on:.off;distances.addItem(o)
        }
        distance.submenu=distances;m.addItem(distance)
        let sizing=item("人物大小",nil), sizes=NSMenu()
        for (name,value) in [("小",170),("中",220),("大",290)] {
            let o=item(name,#selector(setSize(_:)),tag:value);o.state=Int(size)==value ? .on:.off;sizes.addItem(o)
        }
        sizing.submenu=sizes;m.addItem(sizing)
        m.addItem(item("恢复默认位置",#selector(resetPosition)))
        m.addItem(.separator());m.addItem(item("退出\(role.name)桌宠",#selector(quit)))
        return m
    }
    @objc func chooseClip(_ sender:NSMenuItem) { if let c=clips.first(where:{$0.id==sender.tag}) { requestPlayback(c) } }
    @objc func setVolume(_ sender:NSMenuItem) { changeSettings{$0.volume=Float(sender.tag)/100} }
    @objc func setDistance(_ sender:NSMenuItem) { changeSettings{$0.distance=Double(sender.tag)} }
    @objc func toggleTilt() { changeSettings{$0.enabled.toggle()} }
    @objc func setSize(_ sender:NSMenuItem) {
        size=CGFloat(sender.tag);panel.setContentSize(panelSize);pet.layoutSubtreeIfNeeded()
        if !testing { UserDefaults.standard.set(Double(size),forKey:"size") };savePosition()
    }
    @objc func openOther() {
        let sibling=Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(role.other.appName+".app")
        let installed=URL(fileURLWithPath:"/Applications/"+role.other.appName+".app")
        NSWorkspace.shared.openApplication(at:FileManager.default.fileExists(atPath:sibling.path) ? sibling:installed,configuration:NSWorkspace.OpenConfiguration()) {[weak self] _,error in
            if error != nil { DispatchQueue.main.async { self?.showCaption("请先安装另一位桌宠",seconds:3) } }
        }
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification:Notification) {
        guard started else { return }
        pollTimer?.invalidate();pet.animationTimer?.invalidate();stopLocal();savePosition()
        if lockFD>=0 { Darwin.close(lockFD) }
        DistributedNotificationCenter.default().removeObserver(self)
        if let data=try? Data(contentsOf:stateURL(role)),let v=try? JSONDecoder().decode(PeerState.self,from:data),v.session==session { try? FileManager.default.removeItem(at:stateURL(role)) }
    }
    func handleTestCommand() {
        guard let data=try? Data(contentsOf:stateDirectory.appendingPathComponent(role.rawValue+"-command.json")),let cmd=try? JSONDecoder().decode(TestCommand.self,from:data),cmd.id != lastCommand else { return }
        lastCommand=cmd.id
        switch cmd.action {
        case "move":if let x=cmd.x,let y=cmd.y { panel.setFrameOrigin(NSPoint(x:x,y:y)) }
        case "click": if let id=cmd.clipID,let c=clips.first(where:{$0.id==id}) { requestPlayback(c) } else { playNext() }
        case "pair": if let id=cmd.pairID { requestPair(id) }
        case "stop":stopAll()
        case "quit":quit()
        default:break
        }
    }
    func runSelfTest() {
        var failed=false
        func check(_ c:Bool,_ label:String) { print("\(c ? "OK":"FAIL") \(label)");if !c { failed=true } }
        check(!panel.isOpaque && !panel.canBecomeKey,"transparent nonactivating panel")
        check(clips.allSatisfy{$0.role==role && !$0.text.isEmpty},"own-speaker clips with subtitles")
        for c in clips {
            let a=try? AVAudioPlayer(contentsOf:clipURL(c))
            check((a?.duration ?? 0)>0.15 && abs((a?.duration ?? 0)-c.duration)<0.1,"clip \(c.id): \(c.text.replacingOccurrences(of:"\n",with:" / "))")
        }
        let timingOK=clips.allSatisfy { c in
            let ls=c.timedLines
            return !ls.isEmpty && ls.allSatisfy { !$0.text.isEmpty && $0.start.isFinite && $0.end.isFinite && $0.start<=$0.end+0.001 }
                && zip(ls,ls.dropFirst()).allSatisfy { $0.start <= $1.start+0.001 }
        }
        check(timingOK,"subtitle lines ordered in time")
        let pairOK=(!pairs.isEmpty)
            && Set(pairs.map{$0.id}).count==pairs.count
            && pairs.allSatisfy { p in
                allClips.contains{$0.id==p.lei && $0.role == .lei} && allClips.contains{$0.id==p.yu && $0.role == .yu}
            }
        check(pairOK,"dialogue pairs complete")
        var b=ShuffleBag();var ok=true;var last:Int?
        for _ in 0..<30 {
            var cycle=Set<Int>()
            for _ in clips { let i=b.next(clips.count)!;if last==i && clips.count>1 { ok=false };cycle.insert(i);last=i }
            if cycle.count != clips.count { ok=false }
        }
        check(ok,"shuffle without repeats")
        check(Proximity.angle(dx:100)<0 && Proximity.angle(dx:-100)>0,"heads lean toward peer")
        let args=CommandLine.arguments
        if let i=args.firstIndex(of:"--preview"),i+1<args.count {
            let preview=clips.max(by:{$0.text.count<$1.text.count})!
            let requested=args.firstIndex(of:"--preview-line").flatMap { j in j+1<args.count ? Int(args[j+1]) : nil } ?? 0
            let line=preview.timedLines[min(max(requested,0),preview.timedLines.count-1)]
            pet.setCaption(args.contains("--preview-no-caption") ? "" : line.text)
            pet.face.angle=role == .lei ? -0.2:0.2
            if args.contains("--preview-speaking") { pet.face.compression=0.86;pet.face.bob=5 }
            pet.layoutSubtreeIfNeeded()
            if let bitmap=pet.bitmapImageRepForCachingDisplay(in:pet.bounds) {
                pet.cacheDisplay(in:pet.bounds,to:bitmap)
                try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:args[i+1]))
            }
        }
        print(failed ? "FAIL":"PASS");fflush(stdout);exit(failed ? 1:0)
    }
}
let app=NSApplication.shared
let delegate=PetApp();app.delegate=delegate;app.setActivationPolicy(.accessory);app.run()
