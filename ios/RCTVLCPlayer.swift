//
//  RCTVLCPlayer.swift
//  RCTVLCPlayer
//
//  Created by Konstantin Späth on 25.04.23.
//  Copyright © 2023 Facebook. All rights reserved.
//

import Foundation
import AVFoundation

#if os(iOS)
import MobileVLCKit
#else
import TVVLCKit
#endif

class RCTVLCPlayer : UIView {
    let mediaURL = "https://streams.videolan.org/streams/mp4/Mr_MrsSmith-h264_aac.mp4"
    
    private var _eventDispatcher: RCTEventDispatcher!
    private var _player: VLCMediaPlayer!
    private var _source: NSDictionary!
    private var _paused = false
    private var _started = false
    private var _subtitleUri: String!
    private var _videoInfo: [String: Any]!
    private var _progressTimer: Timer?
    private var _bufferingTimer: Timer?
    private var _bufferingProgress: Float = 0.0
    
    private var _pendingSeek = false
    
    init(eventDispatcher: RCTEventDispatcher!) {
        super.init(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        _eventDispatcher = eventDispatcher
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillResignActive(_:)), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillEnterForeground(_:)), name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    // Events
    @objc var onVideoOpen: RCTDirectEventBlock?
    @objc var onVideoPlaying: RCTDirectEventBlock?
    @objc var onVideoProgress: RCTDirectEventBlock?
    @objc var onVideoPaused: RCTDirectEventBlock?
    @objc var onVideoEnded: RCTDirectEventBlock?
    @objc var onVideoStopped: RCTDirectEventBlock?
    @objc var onVideoLoad: RCTDirectEventBlock?
    @objc var onVideoLoadStart: RCTDirectEventBlock?
    @objc var onVideoBuffering: RCTDirectEventBlock?
    @objc var onVideoError: RCTDirectEventBlock?
    
    @objc
    func applicationWillResignActive(_ notification: NSNotification) {
        if !paused {
            paused = true
        }
    }
    
    @objc
    func applicationWillEnterForeground(_ notification: NSNotification) {
        self.applyModifiers()
    }
    
    func applyModifiers() {
        if !paused {
            self.play()
        }
    }
    
    func play() {
        if _player != nil {
            _player.play()
            _paused = false
            _started = true
            startProgressTimer()
        }
    }
    
    func pause() {
        if _player != nil {
            _player.pause()
            _paused = true
            stopProgressTimer()
        }
    }
    
    @objc
    func setResume(_ autoplay: Bool) {
        if _player != nil {
            _release()
        }
        
        playMedia(_source)
    }
    
    @objc
    func setSource(_ source: NSDictionary) {
        NSLog("Source \(source as AnyObject)")
        
        if _player != nil {
            _release()
        }
        _source = source
        _videoInfo = nil
        
        playMedia(source)
        
        if _subtitleUri != nil, let uri = URL(string: _subtitleUri) {
            _player.addPlaybackSlave(uri, type: .subtitle, enforce: true)
        }
        
        self.play()
    }
    
    private func playMedia(_ source: NSDictionary) {
        guard let uri = source["uri"] as? String else { return }
        let autoPlay = source["autoPlay"] as? Bool ?? true
        
        _player = VLCMediaPlayer()
        
        _player.drawable = self
        _player.delegate = self
        _player.scaleFactor = 0
        
        let media = VLCMedia(url: URL(string: uri)!)
        
        if let initOptions = source["initOptions"] as? [String: String] {
            media.addOptions(initOptions)
        }
        
        _player.media = media
        _player.delegate = self
        
        try? AVAudioSession.sharedInstance().setActive(false, options: AVAudioSession.SetActiveOptions.notifyOthersOnDeactivation)
        NSLog("Autoplay: \(autoPlay)")
        
        self.onVideoLoad?([
            "target": self.reactTag
        ])
    }
    
    @objc
    func setSubtitleUri(_ subtitleUri: String) {
        _subtitleUri = subtitleUri
        
        if _player != nil, let subtitle = URL(string: subtitleUri) {
            _player.addPlaybackSlave(subtitle, type: .subtitle, enforce: true)
        }
    }
    
    @objc
    func setSeek(_ pos: Float) {
        // TODO: add seeking with jumping forward
        NSLog("Seek: \(pos)")
        if _player != nil && pos >= 0 && pos <= 1 {
            _player.position = pos
            if !_player.isPlaying {
                _player.play()
            }
        }
    }
    
    @objc
    func setAudioTrack(_ track: Int) {
        _player.currentAudioTrackIndex = Int32(track)
    }
    
    @objc
    func setTextTrack(_ track: Int) {
        _player.currentVideoTrackIndex = Int32(track)
    }
    
    @objc
    func setVideoAspectRatio(_ ratio: String) {
        let cs = (ratio as NSString).utf8String
        var buffer = UnsafeMutablePointer<Int8>(mutating: cs)
        _player.videoAspectRatio = buffer
    }
    
    @objc
    func setSnapshotPath(_ path: String) {
        _player.saveVideoSnapshot(at: path, withWidth: 0, andHeight: 0)
    }
    
    @objc var paused: Bool = false {
        didSet {
            self._paused = paused
            if _player != nil {
                if !paused {
                    self.play()
                } else if _player.canPause {
                    self.pause()
                }
            }
        }
    }
    
    @objc var muted: Bool = false {
        didSet {
            if _player != nil {
                _player.audio?.setMute(muted)
            }
        }
    }
    
    @objc var rate: Float = 1.0 {
        didSet {
            if _player != nil {
                _player.rate = rate
            }
        }
    }
    
    func _release() {
        if _player != nil {
            _player.pause()
            _player.stop()
            _player = nil
            _eventDispatcher = nil
            NotificationCenter.default.removeObserver(self)
            stopProgressTimer()
            stopBufferingTimer()
        }
    }
    
    func getVideoInfo() -> [String: Any] {
        var info: [String: Any] = [:]
        if _player == nil {
            return info
        }
        
        info["duration"] = _player.media?.length.value
        
        if _player.videoSize.width > 0 {
            info["videoSize"] = [
                "width": _player.videoSize.width,
                "height": _player.videoSize.height
            ]
        }
        
        if _player.numberOfAudioTracks > 0 {
            var tracks: [[String: Any]] = []
            for i in 0..<_player.numberOfAudioTracks {
                if let trackId = _player.audioTrackIndexes[safe: Int(i)], let trackName = _player.audioTrackNames[safe: Int(i)] {
                    tracks.append([
                        "id": trackId,
                        "name": trackName
                    ])
                }
            }
            info["audioTracks"] = tracks
        }
        
        if _player.numberOfSubtitlesTracks > 0 {
            var tracks: [[String: Any]] = []
            for i in 0..<_player.numberOfSubtitlesTracks {
                if let trackId = _player.videoSubTitlesIndexes[safe: Int(i)], let trackName = _player.videoSubTitlesNames[safe: Int(i)] {
                    tracks.append([
                        "id": trackId,
                        "name": trackName
                    ])
                }
            }
            info["trackTracks"] = tracks
        }

        return info
    }
    
    override func removeFromSuperview() {
        NSLog("Remove from Superview")
        _release()
        super.removeFromSuperview()
    }
    
    private func startProgressTimer() {
        _progressTimer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(updateVideoProgress), userInfo: nil, repeats: true)
    }
    
    private func stopProgressTimer() {
        _progressTimer?.invalidate()
        _progressTimer = nil
    }
    
    private func startBufferingTimer() {
        _bufferingProgress = 0.0
        _bufferingTimer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(updateBufferingProgress), userInfo: nil, repeats: true)
    }
    
    private func stopBufferingTimer() {
        _bufferingTimer?.invalidate()
        _bufferingTimer = nil
    }
    
    @objc private func updateVideoProgress() {
        if _player != nil {
            let curTime = _player.time.intValue
            let remainingTime = _player.remainingTime?.intValue ?? 0
            let duration = _player.media?.length.intValue ?? 0
            
            if curTime > 0 && curTime < duration {
                onVideoProgress?([
                    "currentTime": NSNumber(value: curTime),
                    "remainingTime": NSNumber(value: remainingTime),
                    "duration": NSNumber(value: duration),
                    "target": reactTag,
                ])
            }
        }
    }
    
    @objc private func updateBufferingProgress() {
        _bufferingProgress += 5.0
        if _bufferingProgress > 100.0 {
            _bufferingProgress = 100.0
        }
        onVideoBuffering?([
            "target": reactTag,
            "bufferRate": _bufferingProgress
        ])
    }
}

extension RCTVLCPlayer: VLCMediaPlayerDelegate {
    
    internal func mediaPlayerTimeChanged(_ aNotification: Notification) {
        self.updateVideoProgress()
    }
    
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        let defaults = UserDefaults.standard
        NSLog("userInfo \(aNotification.userInfo)")
        
        if _player != nil {
            let state = _player.state
            switch state {
            case .opening:
                NSLog("VLCMediaPlayerStateOpening \(_player.numberOfAudioTracks)")
                onVideoOpen?([
                    "target": reactTag,
                ])
            case .paused:
                _paused = true
                NSLog("VLCMediaPlayerStatePaused \(_player.numberOfAudioTracks)")
                onVideoPaused?([
                    "target": reactTag,
                ])
                stopProgressTimer()
                stopBufferingTimer()
            case .stopped:
                NSLog("VLCMediaPlayerStateStopped \(_player.numberOfAudioTracks)")
                onVideoStopped?([
                    "target": reactTag,
                ])
                stopProgressTimer()
                stopBufferingTimer()
            case .buffering:
                NSLog("VLCMediaPlayerStateBuffering \(_player.numberOfAudioTracks)")
                _videoInfo = getVideoInfo()
                onVideoBuffering?([
                    "target": reactTag,
                    "bufferRate": _bufferingProgress,
                ])
                startBufferingTimer()
            case .ended:
                NSLog("VLCMediaPlayerStateEnded \(_player.numberOfAudioTracks)")
                let currentTime = _player.time.intValue
                let remainingTime = _player.remainingTime?.intValue ?? 0
                let duration = _player.media?.length.intValue ?? 0
                
                NSLog("VideoCallback Null: \(onVideoEnded)")
                
                onVideoEnded?([
                    "currentTime": NSNumber(value: currentTime),
                    "remainingTime": NSNumber(value: remainingTime),
                    "duration": NSNumber(value: duration),
                    "target": reactTag,
                ])
                stopProgressTimer()
                stopBufferingTimer()
            case .playing:
                NSLog("VLCMediaPlayerStatePlaying \(_player.numberOfAudioTracks)")
                let videoInfo = getVideoInfo()
                onVideoPlaying?([
                    "duration": NSNumber(value: _player.media?.length.intValue ?? 0),
                    "seekable": NSNumber(value: _player.isSeekable),
                    "target": reactTag,
                    "videoInfo": videoInfo
                ])
                startProgressTimer()
                stopBufferingTimer()
            case .esAdded:
                NSLog("VLCMediaPlayerStateESAdded \(_player.numberOfAudioTracks)")
            case .error:
                NSLog("VLCMediaPlayerStateError \(_player.numberOfAudioTracks)")
                onVideoError?([
                    "target": reactTag,
                ])
                _release()
            @unknown default:
                NSLog("VLCMediaPlayerStateUnknown \(_player.numberOfAudioTracks)")
                break
            }
        }
    }
}

extension Collection {
    /// Returns the element at the specified index if it is within bounds, otherwise nil.
    subscript (safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
