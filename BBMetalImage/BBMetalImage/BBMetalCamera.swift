//
//  BBMetalCamera.swift
//  BBMetalImage
//
//  Created by Kaibo Lu on 4/8/19.
//  Copyright © 2019 Kaibo Lu. All rights reserved.
//

import AVFoundation
import BBMetalImageObjC

/// Camera photo delegate defines handling taking photo result behaviors
public protocol BBMetalCameraPhotoDelegate: AnyObject {
    /// Called when camera did take a photo and get Metal texture
    ///
    /// - Parameters:
    ///   - camera: camera to use
    ///   - texture: Metal texture of the original photo which is not filtered
    func camera(_ camera: BBMetalCamera, didOutput texture: MTLTexture)
    
    /// Called when camera fail taking a photo
    ///
    /// - Parameters:
    ///   - camera: camera to use
    ///   - error: error for taking the photo
    func camera(_ camera: BBMetalCamera, didFail error: Error)
}

public protocol BBMetalCameraMetadataObjectDelegate: AnyObject {
    /// Called when camera did get metadata objects
    ///
    /// - Parameters:
    ///   - camera: camera to use
    ///   - metadataObjects: metadata objects
    func camera(_ camera: BBMetalCamera, didOutput metadataObjects: [AVMetadataObject])
}

/// Camera capturing image and providing Metal texture
public class BBMetalCamera: NSObject {
    /// Image consumers
    public var consumers: [BBMetalImageConsumer] {
        lock.wait()
        let c = _consumers
        lock.signal()
        return c
    }
    private var _consumers: [BBMetalImageConsumer]
    
    /// A block to call before processing each video sample buffer
    public var preprocessVideo: ((CMSampleBuffer) -> Void)? {
        get {
            lock.wait()
            let p = _preprocessVideo
            lock.signal()
            return p
        }
        set {
            lock.wait()
            _preprocessVideo = newValue
            lock.signal()
        }
    }
    private var _preprocessVideo: ((CMSampleBuffer) -> Void)?
    
    /// A block to call before transmiting texture to image consumers
    public var willTransmitTexture: ((MTLTexture, CMTime) -> Void)? {
        get {
            lock.wait()
            let w = _willTransmitTexture
            lock.signal()
            return w
        }
        set {
            lock.wait()
            _willTransmitTexture = newValue
            lock.signal()
        }
    }
    private var _willTransmitTexture: ((MTLTexture, CMTime) -> Void)?
    
    /// Camera position
    public var position: AVCaptureDevice.Position { return camera.position }
    
    /// Camera active format
    public var activeFormat: AVCaptureDevice.Format { camera.activeFormat }
    
    /// Output texture size
    public var textureSize: BBMetalIntSize {
        lock.wait()
        let dimensions = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        var size = BBMetalIntSize(width: Int(dimensions.width), height: Int(dimensions.height))
        if let orientation = videoOutput.connections.first?.videoOrientation {
            let isLandscape: (AVCaptureVideoOrientation) -> Bool = { orientation in
                orientation == .landscapeLeft || orientation == .landscapeRight
            }
            if isLandscape(orientation) != isLandscape(originalOrientation) {
                swap(&size.width, &size.height)
            }
        }
        lock.signal()
        return size
    }
    
    public var videoOrientation: AVCaptureVideoOrientation {
        get {
            lock.wait()
            let v = videoOutput.connections.first?.videoOrientation ?? .portrait
            lock.signal()
            return v
        }
        set {
            lock.wait()
            if let connection = videoOutput.connections.first,
               connection.isVideoOrientationSupported {
                connection.videoOrientation = newValue
            }
            lock.signal()
        }
    }
    
    private var originalOrientation: AVCaptureVideoOrientation
    
    /// Whether to run benchmark or not.
    /// Running benchmark records frame duration.
    /// False by default.
    public var benchmark: Bool {
        get {
            lock.wait()
            let b = _benchmark
            lock.signal()
            return b
        }
        set {
            lock.wait()
            _benchmark = newValue
            lock.signal()
        }
    }
    private var _benchmark: Bool
    
    /// Average frame duration, or 0 if not valid value.
    /// To get valid value, set `benchmark` to true.
    public var averageFrameDuration: Double {
        lock.wait()
        let d = capturedFrameCount > ignoreInitialFrameCount ? totalCaptureFrameTime / Double(capturedFrameCount - ignoreInitialFrameCount) : 0
        lock.signal()
        return d
    }
    
    private var capturedFrameCount: Int
    private var totalCaptureFrameTime: Double
    private let ignoreInitialFrameCount: Int
    
    private let lock: DispatchSemaphore
    
    private var session: AVCaptureSession!
    private var camera: AVCaptureDevice!
    private var videoInput: AVCaptureDeviceInput!
    private var videoOutput: AVCaptureVideoDataOutput!
    private var videoOutputQueue: DispatchQueue!
    
    private let multipleSessions: Bool
    private var audioSession: AVCaptureSession!
    private var audioInput: AVCaptureDeviceInput!
    private var audioOutput: AVCaptureAudioDataOutput!
    private var audioOutputQueue: DispatchQueue!
    
    /// Audio consumer processing audio sample buffer.
    /// Set this property to nil (default value) if not recording audio.
    /// Set this property to a given audio consumer if recording audio.
    public var audioConsumer: BBMetalAudioConsumer? {
        get {
            lock.wait()
            let a = _audioConsumer
            lock.signal()
            return a
        }
        set {
            lock.wait()
            _audioConsumer = newValue
            if newValue != nil {
                if !addAudioInputAndOutput() { _audioConsumer = nil }
            } else {
                removeAudioInputAndOutput()
            }
            lock.signal()
        }
    }
    private var _audioConsumer: BBMetalAudioConsumer?
    
    private var photoOutput: AVCapturePhotoOutput!
    
    /// Whether can take photo or not.
    /// Set this property to true before calling `takePhoto()` method.
    public var canTakePhoto: Bool {
        get {
            lock.wait()
            let c = _canTakePhoto
            lock.signal()
            return c
        }
        set {
            lock.wait()
            _canTakePhoto = newValue
            if newValue {
                if !addPhotoOutput() { _canTakePhoto = false }
            } else {
                removePhotoOutput()
            }
            lock.signal()
        }
    }
    private var _canTakePhoto: Bool
    
    /// Camera photo delegate handling taking photo result.
    /// To take photo, this property should not be nil.
    public weak var photoDelegate: BBMetalCameraPhotoDelegate? {
        get {
            lock.wait()
            let p = _photoDelegate
            lock.signal()
            return p
        }
        set {
            lock.wait()
            _photoDelegate = newValue
            lock.signal()
        }
    }
    private weak var _photoDelegate: BBMetalCameraPhotoDelegate?
    
    private var _needPhoto: Bool
    
    private var _capturePhotoCompletion: BBMetalFilterCompletion?
    
    private var metadataOutput: AVCaptureMetadataOutput!
    private var metadataOutputQueue: DispatchQueue!
    
    public weak var metadataObjectDelegate: BBMetalCameraMetadataObjectDelegate? {
        get {
            lock.wait()
            let m = _metadataObjectDelegate
            lock.signal()
            return m
        }
        set {
            lock.wait()
            _metadataObjectDelegate = newValue
            lock.signal()
        }
    }
    private weak var _metadataObjectDelegate: BBMetalCameraMetadataObjectDelegate?
    
    /// Whether can get depth data or not
    @available(iOS 11.0, *)
    public var canGetDepthData: Bool {
        get {
            lock.wait()
            let c = _canGetDepthData
            lock.signal()
            return c
        }
        set {
            lock.wait()
            _canGetDepthData = newValue
            if newValue {
                if !addDepthDataOutput() { _canGetDepthData = false }
            } else {
                removeDepthDataOutput()
            }
            lock.signal()
        }
    }
    private var _canGetDepthData: Bool
    
    @available(iOS 11.0, *)
    private var depthDataOutput: AVCaptureDepthDataOutput! {
        get { _depthDataOutput as? AVCaptureDepthDataOutput }
        set { _depthDataOutput = newValue }
    }
    private var _depthDataOutput: Any!
    
    @available(iOS 11.0, *)
    private var outputSynchronizer: AVCaptureDataOutputSynchronizer! {
        get { _outputSynchronizer as? AVCaptureDataOutputSynchronizer }
        set { _outputSynchronizer = newValue }
    }
    private var _outputSynchronizer: Any!
    
    private let depthImageSource: CameraDepthImageSource
    
    /// When this property is false, received video/audio sample buffer will not be processed
    public var isPaused: Bool {
        get {
            lock.wait()
            let p = _isPaused
            lock.signal()
            return p
        }
        set {
            lock.wait()
            _isPaused = newValue
            lock.signal()
        }
    }
    private var _isPaused: Bool
    
    private var textureCache: CVMetalTextureCache!
    
    /// Creates a camera
    /// - Parameters:
    ///   - captureSession: An object that manages capture activity and coordinates the flow of data from input devices to capture outputs
    ///   - sessionPreset: a constant value indicating the quality level or bit rate of the output
    ///   - deviceType: camera device type
    ///   - position: camera position
    ///   - multitpleSessions: whether to use independent video session and audio session (false by default). Switching camera position while recording leads to the video and audio out of sync.
    /// Set true if we allow the user to switch camera position while recording.
    public init?(
        captureSession: AVCaptureSession = .init(),
        sessionPreset: AVCaptureSession.Preset = .high,
        deviceType: AVCaptureDevice.DeviceType = .builtInWideAngleCamera,
        position: AVCaptureDevice.Position = .back,
        multipleSessions: Bool = false
    ) {
        _consumers = []
        _canGetDepthData = false
        _canTakePhoto = false
        _needPhoto = false
        _isPaused = false
        _benchmark = false
        capturedFrameCount = 0
        totalCaptureFrameTime = 0
        ignoreInitialFrameCount = 5
        originalOrientation = .portrait
        depthImageSource = .init()
        self.multipleSessions = multipleSessions
        lock = DispatchSemaphore(value: 1)
        
        super.init()
        
        guard let videoDevice = AVCaptureDevice.default(deviceType, for: .video, position: position),
            let videoDeviceInput = try? AVCaptureDeviceInput(device: videoDevice) else { return nil }
        
        session = captureSession
        session.beginConfiguration()
        
        if !(session is AVCaptureMultiCamSession) {
            session.sessionPreset = sessionPreset
        }
        
        if !session.canAddInput(videoDeviceInput) {
            session.commitConfiguration()
            return nil
        }
        
        session.addInput(videoDeviceInput)
        camera = videoDevice
        videoInput = videoDeviceInput
        
        let videoDataOutput = AVCaptureVideoDataOutput()
        videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String : kCVPixelFormatType_32BGRA]
        videoOutputQueue = DispatchQueue(label: "com.Kaibo.BBMetalImage.Camera.videoOutput")
        videoDataOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
        if !session.canAddOutput(videoDataOutput) {
            session.commitConfiguration()
            return nil
        }
        session.addOutput(videoDataOutput)
        videoOutput = videoDataOutput
        
        guard let connection = videoDataOutput.connections.first,
            connection.isVideoOrientationSupported else {
                session.commitConfiguration()
                return nil
        }
        originalOrientation = connection.videoOrientation
        connection.videoOrientation = .portrait
        
        session.commitConfiguration()
        
        #if !targetEnvironment(simulator)
        if CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, BBMetalDevice.sharedDevice, nil, &textureCache) != kCVReturnSuccess ||
            textureCache == nil {
            return nil
        }
        #endif
    }
    
    @discardableResult
    private func addAudioInputAndOutput() -> Bool {
        if audioOutput != nil { return true }
        
        var session: AVCaptureSession = self.session
        if multipleSessions {
            session = AVCaptureSession()
            audioSession = session
        }
        
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        
        guard let audioDevice = AVCaptureDevice.default(.builtInMicrophone, for: .audio, position: .unspecified),
            let input = try? AVCaptureDeviceInput(device: audioDevice),
            session.canAddInput(input) else {
                print("Can not add audio input")
                return false
        }
        session.addInput(input)
        audioInput = input
        
        let output = AVCaptureAudioDataOutput()
        let outputQueue = DispatchQueue(label: "com.Kaibo.BBMetalImage.Camera.audioOutput")
        output.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(output) else {
            _removeAudioInputAndOutput()
            print("Can not add audio output")
            return false
        }
        session.addOutput(output)
        audioOutput = output
        audioOutputQueue = outputQueue
        
        return true
    }
    
    private func removeAudioInputAndOutput() {
        session.beginConfiguration()
        _removeAudioInputAndOutput()
        session.commitConfiguration()
    }
    
    private func _removeAudioInputAndOutput() {
        let session: AVCaptureSession = multipleSessions ? audioSession : self.session
        if let input = audioInput {
            session.removeInput(input)
            audioInput = nil
        }
        if let output = audioOutput {
            session.removeOutput(output)
            audioOutput = nil
        }
        if audioOutputQueue != nil {
            audioOutputQueue = nil
        }
        if audioSession != nil {
            audioSession = nil
        }
    }
    
    @discardableResult
    private func addPhotoOutput() -> Bool {
        if photoOutput != nil { return true }
        
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        
        let output = AVCapturePhotoOutput()
        if !session.canAddOutput(output) {
            print("Can not add photo output")
            return false
        }
        session.addOutput(output)
        photoOutput = output
        
        return true
    }
    
    private func removePhotoOutput() {
        session.beginConfiguration()
        if let output = photoOutput {
            session.removeOutput(output)
            photoOutput = nil
        }
        session.commitConfiguration()
    }
    
    @discardableResult
    public func addMetadataOutput(with types: [AVMetadataObject.ObjectType]) -> Bool {
        var result = false
        
        lock.wait()
        
        if metadataOutput != nil {
            lock.signal()
            return result
        }
        
        session.beginConfiguration()
        
        let output = AVCaptureMetadataOutput()
        let outputQueue = DispatchQueue(label: "com.Kaibo.BBMetalImage.Camera.metadataOutput")
        output.setMetadataObjectsDelegate(self, queue: outputQueue)
        
        if session.canAddOutput(output) {
            session.addOutput(output)
            let validTypes = types.filter { output.availableMetadataObjectTypes.contains($0) }
            output.metadataObjectTypes = validTypes
            metadataOutput = output
            metadataOutputQueue = outputQueue
            result = true
        }
        
        session.commitConfiguration()
        lock.signal()
        return result
    }
    
    public func removeMetadataOutput() {
        lock.wait()
        
        if metadataOutput == nil {
            lock.signal()
            return
        }
        
        session.beginConfiguration()
        
        session.removeOutput(metadataOutput)
        metadataOutput = nil
        metadataOutputQueue = nil
        
        session.commitConfiguration()
        lock.signal()
    }
    
    @available(iOS 11.0, *)
    @discardableResult
    private func addDepthDataOutput() -> Bool {
        if depthDataOutput != nil { return true }
        
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        
        return _addDepthDataOutput()
    }
    
    @available(iOS 11.0, *)
    private func _addDepthDataOutput() -> Bool {
        let output = AVCaptureDepthDataOutput()
        output.setDelegate(self, callbackQueue: videoOutputQueue)
        if !session.canAddOutput(output) {
            print("Can not add depth data output")
            return false
        }
        session.addOutput(output)
        depthDataOutput = output
        
        guard let connection = depthDataOutput.connections.first,
            connection.isVideoOrientationSupported else {
                session.removeOutput(output)
                depthDataOutput = nil
                return false
        }
        connection.videoOrientation = videoOutput.connections.first?.videoOrientation ?? .portrait
        
        outputSynchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthDataOutput])
        outputSynchronizer.setDelegate(self, queue: videoOutputQueue)
        
        return true
    }
    
    @available(iOS 11.0, *)
    private func removeDepthDataOutput() {
        session.beginConfiguration()
        _removeDepthDataOutput()
        session.commitConfiguration()
    }
    
    @available(iOS 11.0, *)
    private func _removeDepthDataOutput() {
        if let output = depthDataOutput {
            session.removeOutput(output)
            depthDataOutput = nil
        }
        outputSynchronizer = nil
    }
    
    /// Captures frame texture as a photo.
    /// Get original frame texture in the completion closure.
    /// To get filtered texture, use `addCompletedHandler(_:)` method of `BBMetalBaseFilter`, check whether the filtered texture is camera photo.
    /// This method is much faster than `takePhoto()` method.
    /// - Parameter completion: a closure to call after capturing. If success, get original frame texture. If failure, get error.
    public func capturePhoto(completion: BBMetalFilterCompletion? = nil) {
        lock.wait()
        _needPhoto = true
        _capturePhotoCompletion = completion
        lock.signal()
    }
    
    /// Takes a photo.
    /// Before calling this method, set `canTakePhoto` property to true and `photoDelegate` property to nonnull.
    /// Get original frame texture in `camera(_:didOutput:)` method of `BBMetalCameraPhotoDelegate`.
    /// To get filtered texture, use `capturePhoto(completion:)` method, or create new filter to process the original frame texture.
    public func takePhoto() {
        lock.wait()
        if let output = photoOutput,
            _photoDelegate != nil {
            let currentSettings = AVCapturePhotoSettings(format: [kCVPixelBufferPixelFormatTypeKey as String : kCVPixelFormatType_32BGRA])
            output.capturePhoto(with: currentSettings, delegate: self)
        }
        lock.signal()
    }
    
    /// Switches camera position (back to front, or front to back)
    ///
    /// - Returns: true if succeed, or false if fail
    @discardableResult
    public func switchCameraPosition() -> Bool {
        lock.wait()
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            lock.signal()
        }
        
        var position: AVCaptureDevice.Position = .back
        if camera.position == .back { position = .front }
        
        var tempDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
        
        if _canGetDepthData,
           #available(iOS 10.2, *) {
            tempDevice = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: position)
            if tempDevice == nil,
               #available(iOS 13.0, *) {
                tempDevice = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: position)
            }
            if tempDevice == nil,
               #available(iOS 11.1, *) {
                tempDevice = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: position)
            }
        }
        
        guard let videoDevice = tempDevice,
            let videoDeviceInput = try? AVCaptureDeviceInput(device: videoDevice) else { return false }
        
        session.removeInput(videoInput)
        
        guard session.canAddInput(videoDeviceInput) else {
            session.addInput(videoInput)
            return false
        }
        session.addInput(videoDeviceInput)
        camera = videoDevice
        videoInput = videoDeviceInput
        
        guard let connection = videoOutput.connections.first,
            connection.isVideoOrientationSupported else { return false }
        originalOrientation = connection.videoOrientation
        connection.videoOrientation = .portrait
        
        if _canGetDepthData,
           #available(iOS 11.0, *) {
            _removeDepthDataOutput()
            if !_addDepthDataOutput() { return false }
        }
        
        return true
    }
    
    /// Sets camera frame rate
    ///
    /// - Parameter frameRate: camera frame rate
    /// - Returns: true if succeed, or false if fail
    @discardableResult
    public func setFrameRate(_ frameRate: Float64) -> Bool {
        var success = false
        lock.wait()
        do {
            try camera.lockForConfiguration()
            var targetFormat: AVCaptureDevice.Format?
            let dimensions = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
            for format in camera.formats {
                let newDimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                if dimensions.width == newDimensions.width,
                    dimensions.height == newDimensions.height {
                    for range in format.videoSupportedFrameRateRanges {
                        if range.maxFrameRate >= frameRate,
                            range.minFrameRate <= frameRate {
                            targetFormat = format
                            break
                        }
                    }
                    if targetFormat != nil { break }
                }
            }
            if let format = targetFormat {
                camera.activeFormat = format
                camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
                camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
                success = true
            } else {
                print("Can not find valid format for camera frame rate \(frameRate)")
            }
            camera.unlockForConfiguration()
        } catch {
            print("Error for camera lockForConfiguration: \(error)")
        }
        lock.signal()
        return success
    }
    
    /// Configures camera.
    /// Configure camera in the block, without calling `lockForConfiguration` and `unlockForConfiguration` methods.
    ///
    /// - Parameter block: closure configuring camera
    public func configureCamera(_ block: (AVCaptureDevice) -> Void) {
        lock.wait()
        do {
            try camera.lockForConfiguration()
            block(camera)
            camera.unlockForConfiguration()
        } catch {
            print("Error for camera lockForConfiguration: \(error)")
        }
        lock.signal()
    }
    
    /// Starts capturing
    public func start() {
        lock.wait()
        session.startRunning()
        if multipleSessions, let session = audioSession { session.startRunning() }
        lock.signal()
    }
    
    /// Stops capturing
    public func stop() {
        lock.wait()
        session.stopRunning()
        if multipleSessions, let session = audioSession { session.stopRunning() }
        lock.signal()
    }
    
    /// Resets benchmark record data
    public func resetBenchmark() {
        lock.wait()
        capturedFrameCount = 0
        totalCaptureFrameTime = 0
        lock.signal()
    }
}

extension BBMetalCamera: BBMetalImageSource {
    @discardableResult
    public func add<T: BBMetalImageConsumer>(consumer: T) -> T {
        lock.wait()
        _consumers.append(consumer)
        lock.signal()
        consumer.add(source: self)
        return consumer
    }
    
    public func add(consumer: BBMetalImageConsumer, at index: Int) {
        lock.wait()
        _consumers.insert(consumer, at: index)
        lock.signal()
        consumer.add(source: self)
    }
    
    public func remove(consumer: BBMetalImageConsumer) {
        lock.wait()
        if let index = _consumers.firstIndex(where: { $0 === consumer }) {
            _consumers.remove(at: index)
            lock.signal()
            consumer.remove(source: self)
        } else {
            lock.signal()
        }
    }
    
    public func removeAllConsumers() {
        lock.wait()
        let consumers = _consumers
        _consumers.removeAll()
        lock.signal()
        for consumer in consumers {
            consumer.remove(source: self)
        }
    }
}

extension BBMetalCamera: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Audio
        if output is AVCaptureAudioDataOutput {
            lock.wait()
            let paused = _isPaused
            let currentAudioConsumer = _audioConsumer
            lock.signal()
            if !paused,
                let consumer = currentAudioConsumer {
                consumer.newAudioSampleBufferAvailable(sampleBuffer)
            }
            return
        }
        
        processVideo(sampleBuffer)
    }
    
    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        print("Camera drops \(output is AVCaptureAudioDataOutput ? "audio" : "video") sample buffer")
    }
    
    private func processVideo(_ sampleBuffer: CMSampleBuffer) {
        // Video
        lock.wait()
        let paused = _isPaused
        let consumers = _consumers
        let willTransmit = _willTransmitTexture
        let preprocessVideo = _preprocessVideo
        let cameraPosition = camera.position
        
        let isCameraPhoto = _needPhoto
        if _needPhoto { _needPhoto = false }
        
        let capturePhotoCompletion = _capturePhotoCompletion
        if _capturePhotoCompletion != nil { _capturePhotoCompletion = nil }
        
        let startTime = _benchmark ? CACurrentMediaTime() : 0
        lock.signal()
        
        guard !paused, !consumers.isEmpty else { return }
        
        preprocessVideo?(sampleBuffer)
        
        guard let texture = texture(with: sampleBuffer) else {
            if let completion = capturePhotoCompletion {
                let error = NSError(domain: "BBMetalCameraErrorDomain", code: 0, userInfo: [NSLocalizedDescriptionKey: "Can not get Metal texture"])
                let info = BBMetalFilterCompletionInfo(result: .failure(error),
                                                       sampleTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                                                       cameraPosition: cameraPosition,
                                                       isCameraPhoto: isCameraPhoto)
                completion(info)
            }
            return
        }
        
        let sampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        if let completion = capturePhotoCompletion {
            var result: Result<MTLTexture, Error>
            let filter = BBMetalPassThroughFilter(createTexture: true)
            if let metalTexture = filter.filteredTexture(with: texture.metalTexture) {
                result = .success(metalTexture)
            } else {
                let error = NSError(domain: "BBMetalCameraErrorDomain", code: 0, userInfo: [NSLocalizedDescriptionKey: "Can not get Metal texture"])
                result = .failure(error)
            }
            let info = BBMetalFilterCompletionInfo(result: result,
                                                   sampleTime: sampleTime,
                                                   cameraPosition: cameraPosition,
                                                   isCameraPhoto: isCameraPhoto)
            completion(info)
        }
        
        willTransmit?(texture.metalTexture, sampleTime)
        let output = BBMetalDefaultTexture(metalTexture: texture.metalTexture,
                                           sampleTime: sampleTime,
                                           cameraPosition: cameraPosition,
                                           isCameraPhoto: isCameraPhoto,
                                           cvMetalTexture: texture.cvMetalTexture)
        for consumer in consumers { consumer.newTextureAvailable(output, from: self) }
        
        // Benchmark
        if startTime != 0 {
            lock.wait()
            capturedFrameCount += 1
            if capturedFrameCount > ignoreInitialFrameCount {
                totalCaptureFrameTime += CACurrentMediaTime() - startTime
            }
            lock.signal()
        }
    }
    
    private func texture(with sampleBuffer: CMSampleBuffer) -> BBMetalVideoTextureItem? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        return texture(with: imageBuffer, pixelFormat: .bgra8Unorm) // camera ouput BGRA
    }
    
    private func texture(with imageBuffer: CVImageBuffer, pixelFormat: MTLPixelFormat) -> BBMetalVideoTextureItem? {
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        
        #if !targetEnvironment(simulator)
        var cvMetalTextureOut: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                               textureCache,
                                                               imageBuffer,
                                                               nil,
                                                               pixelFormat,
                                                               width,
                                                               height,
                                                               0,
                                                               &cvMetalTextureOut)
        if result == kCVReturnSuccess,
            let cvMetalTexture = cvMetalTextureOut,
            let texture = CVMetalTextureGetTexture(cvMetalTexture) {
            return BBMetalVideoTextureItem(metalTexture: texture, cvMetalTexture: cvMetalTexture)
        }
        #endif
        return nil
    }
}

extension BBMetalCamera: AVCapturePhotoCaptureDelegate {    
    public func photoOutput(_ output: AVCapturePhotoOutput,
                            didFinishProcessingPhoto photoSampleBuffer: CMSampleBuffer?,
                            previewPhoto previewPhotoSampleBuffer: CMSampleBuffer?,
                            resolvedSettings: AVCaptureResolvedPhotoSettings,
                            bracketSettings: AVCaptureBracketedStillImageSettings?,
                            error: Error?) {
        
        guard let delegate = photoDelegate else { return }
        
        if let error = error {
            delegate.camera(self, didFail: error)
            
        } else if let sampleBuffer = photoSampleBuffer,
            let texture = texture(with: sampleBuffer),
            let rotatedTexture = rotatedTexture(with: texture.metalTexture, angle: 90) {
            // Setting `videoOrientation` of `AVCaptureConnection` dose not work. So rotate texture here.
            delegate.camera(self, didOutput: rotatedTexture)
            
        } else {
            delegate.camera(self, didFail: NSError(domain: "BBMetalCamera.Photo", code: 0, userInfo: [NSLocalizedDescriptionKey : "Can not get Metal texture"]))
        }
    }
    
    private func rotatedTexture(with inTexture: MTLTexture, angle: Float) -> MTLTexture? {
        let source = BBMetalStaticImageSource(texture: inTexture)
        let filter = BBMetalRotateFilter(angle: angle, fitSize: true)
        source.add(consumer: filter).runSynchronously = true
        source.transmitTexture()
        return filter.outputTexture
    }
}

extension BBMetalCamera: AVCaptureMetadataOutputObjectsDelegate {
    public func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        metadataObjectDelegate?.camera(self, didOutput: metadataObjects)
    }
}

@available(iOS 11.0, *)
extension BBMetalCamera: AVCaptureDepthDataOutputDelegate {
    public func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection) {
        print("Get depth data")
        processDepthData(depthData, timestamp: timestamp)
    }
    
    public func depthDataOutput(_ output: AVCaptureDepthDataOutput, didDrop depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection, reason: AVCaptureOutput.DataDroppedReason) {
        print("Camera drops depth data")
    }
    
    private func processDepthData(_ depthData: AVDepthData, timestamp: CMTime) {
        // Depth
        lock.wait()
        let paused = _isPaused
        let consumers = depthImageSource.consumers
        let cameraPosition = camera.position
        lock.signal()

        guard !paused, !consumers.isEmpty else { return }

        var depthFormatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: depthData.depthDataMap,
            formatDescriptionOut: &depthFormatDescription
        )
        
        guard let depthFormatDescription = depthFormatDescription else { return }
        
        var inputTextureFormat = MTLPixelFormat.invalid
        let inputMediaSubType = CMFormatDescriptionGetMediaSubType(depthFormatDescription)
        if inputMediaSubType == kCVPixelFormatType_DepthFloat16 ||
            inputMediaSubType == kCVPixelFormatType_DisparityFloat16 {
            inputTextureFormat = .r16Float
        } else if inputMediaSubType == kCVPixelFormatType_DepthFloat32 ||
            inputMediaSubType == kCVPixelFormatType_DisparityFloat32 {
            inputTextureFormat = .r32Float
        } else {
            assertionFailure("Input format not supported")
            return
        }
        
        guard let texture = texture(with: depthData.depthDataMap, pixelFormat: inputTextureFormat) else { return }
        
        var min: Float = 0.0
        var max: Float = 0.0
        minMaxFromPixelBuffer(depthData.depthDataMap, &min, &max, inputTextureFormat)
        let depthRenderParameters = DepthRenderParameters(offset: min, range: max - min)
        
        let output = BBMetalDefaultTexture(metalTexture: texture.metalTexture,
                                           sampleTime: timestamp,
                                           cameraPosition: cameraPosition,
                                           isCameraPhoto: false,
                                           depthRenderParameters: depthRenderParameters,
                                           cvMetalTexture: texture.cvMetalTexture)
        for consumer in consumers { consumer.newTextureAvailable(output, from: depthImageSource) }
    }
}

@available(iOS 11.0, *)
extension BBMetalCamera: AVCaptureDataOutputSynchronizerDelegate {
    public func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer, didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        
        lock.wait()
        let videoOutput = videoOutput
        let depthDataOutput = depthDataOutput
        lock.signal()
        
        if let videoOutput = videoOutput,
           let sampleBufferData = synchronizedDataCollection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData,
            !sampleBufferData.sampleBufferWasDropped {
            processVideo(sampleBufferData.sampleBuffer)
        }
        
        if let depthDataOutput = depthDataOutput,
           let syncedDepthData = synchronizedDataCollection.synchronizedData(for: depthDataOutput) as? AVCaptureSynchronizedDepthData,
           !syncedDepthData.depthDataWasDropped {
            processDepthData(syncedDepthData.depthData, timestamp: syncedDepthData.timestamp)
        }
    }
}

class CameraDepthImageSource: BBMetalImageSource {
    
    var consumers: [BBMetalImageConsumer] = []
    
    @discardableResult
    public func add<T: BBMetalImageConsumer>(consumer: T) -> T {
        consumers.append(consumer)
        consumer.add(source: self)
        return consumer
    }
    
    public func add(consumer: BBMetalImageConsumer, at index: Int) {
        consumers.insert(consumer, at: index)
        consumer.add(source: self)
    }
    
    public func remove(consumer: BBMetalImageConsumer) {
        if let index = consumers.firstIndex(where: { $0 === consumer }) {
            consumers.remove(at: index)
            consumer.remove(source: self)
        }
    }
    
    public func removeAllConsumers() {
        for consumer in consumers {
            consumer.remove(source: self)
        }
        consumers.removeAll()
    }
}

public extension BBMetalCamera {
    @discardableResult
    func add<T: BBMetalImageConsumer>(depthConsumer: T) -> T {
        lock.wait()
        let c = depthImageSource.add(consumer: depthConsumer)
        lock.signal()
        return c
    }
    
    func add(depthConsumer: BBMetalImageConsumer, at index: Int) {
        lock.wait()
        depthImageSource.add(consumer: depthConsumer, at: index)
        lock.signal()
    }
    
    func remove(depthConsumer: BBMetalImageConsumer) {
        lock.wait()
        depthImageSource.remove(consumer: depthConsumer)
        lock.signal()
    }
    
    func removeAllDepthConsumers() {
        lock.wait()
        depthImageSource.removeAllConsumers()
        lock.signal()
    }
}
