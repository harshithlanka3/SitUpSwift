// Copyright 2023 The MediaPipe Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import AVFoundation
import MediaPipeTasksVision
import UIKit

/**
 * The view controller is responsible for performing detection on incoming frames from the live camera and presenting the frames with the
 * landmark of the landmarked poses to the user.
 */
class CameraViewController: UIViewController {
  private struct Constants {
    static let edgeOffset: CGFloat = 2.0
  }
  
  weak var inferenceResultDeliveryDelegate: InferenceResultDeliveryDelegate?
  weak var interfaceUpdatesDelegate: InterfaceUpdatesDelegate?

  @IBOutlet weak var previewView: UIView!
  @IBOutlet weak var cameraUnavailableLabel: UILabel!
  @IBOutlet weak var resumeButton: UIButton!
  @IBOutlet weak var overlayView: OverlayView!
  @IBOutlet weak var cameraSwitchButton: UIButton!
  
  // Session recording UI elements
  private var sessionButton: UIButton!
  private var sessionStatusLabel: UILabel!
  private var sessionUpdateTimer: Timer?
  
  // Posture detection UI elements
  private var postureLabel: UILabel!
  private var postureDebugLabel: UILabel!
  
  private var isSessionRunning = false
  private var isObserving = false
  private let backgroundQueue = DispatchQueue(label: "com.google.mediapipe.cameraController.backgroundQueue")
  
  // Monotonic timestamp tracking for MediaPipe
  private var lastTimestamp: Int = 0
  private let timestampQueue = DispatchQueue(label: "com.google.mediapipe.cameraController.timestampQueue")
  
  // MARK: Controllers that manage functionality
  // Handles all the camera related functionality
  private lazy var cameraFeedService = CameraFeedService(previewView: previewView)
  
  private let poseLandmarkerServiceQueue = DispatchQueue(
    label: "com.google.mediapipe.cameraController.poseLandmarkerServiceQueue",
    attributes: .concurrent)
  
  // Queuing reads and writes to poseLandmarkerService using the Apple recommended way
  // as they can be read and written from multiple threads and can result in race conditions.
  private var _poseLandmarkerService: PoseLandmarkerService?
  private var poseLandmarkerService: PoseLandmarkerService? {
    get {
      poseLandmarkerServiceQueue.sync {
        return self._poseLandmarkerService
      }
    }
    set {
      poseLandmarkerServiceQueue.async(flags: .barrier) {
        self._poseLandmarkerService = newValue
      }
    }
  }

#if !targetEnvironment(simulator)
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    initializePoseLandmarkerServiceOnSessionResumption()
    cameraFeedService.startLiveCameraSession {[weak self] cameraConfiguration in
      DispatchQueue.main.async {
        switch cameraConfiguration {
        case .failed:
          self?.presentVideoConfigurationErrorAlert()
        case .permissionDenied:
          self?.presentCameraPermissionsDeniedAlert()
        default:
          break
        }
      }
    }
  }
  
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    cameraFeedService.stopSession()
    clearPoseLandmarkerServiceOnSessionInterruption()
    stopSessionUpdateTimer()
    // Stop session if active when leaving view
    if SessionManager.shared.getSessionActive() {
      _ = SessionManager.shared.stopSession()
    }
  }
  
  override func viewDidLoad() {
    super.viewDidLoad()
    cameraFeedService.delegate = self
    setupSessionUI()
    setupPostureUI()
    // Do any additional setup after loading the view.
  }
  
  private func setupSessionUI() {
    // Create session button
    sessionButton = UIButton(type: .system)
    sessionButton.setTitle("Start Session", for: .normal)
    sessionButton.setTitle("Stop Session", for: .selected)
    sessionButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.8)
    sessionButton.setTitleColor(.white, for: .normal)
    sessionButton.layer.cornerRadius = 25
    sessionButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
    sessionButton.addTarget(self, action: #selector(toggleSession), for: .touchUpInside)
    sessionButton.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(sessionButton)
    
    // Create session status label
    sessionStatusLabel = UILabel()
    sessionStatusLabel.text = "Session: Stopped"
    sessionStatusLabel.textColor = .white
    sessionStatusLabel.font = UIFont.systemFont(ofSize: 14)
    sessionStatusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
    sessionStatusLabel.textAlignment = .center
    sessionStatusLabel.layer.cornerRadius = 8
    sessionStatusLabel.clipsToBounds = true
    sessionStatusLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(sessionStatusLabel)
    
    // Layout constraints
    NSLayoutConstraint.activate([
      // Session button - bottom center
      sessionButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      sessionButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -100),
      sessionButton.widthAnchor.constraint(equalToConstant: 150),
      sessionButton.heightAnchor.constraint(equalToConstant: 50),
      
      // Session status label - top center
      sessionStatusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      sessionStatusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
      sessionStatusLabel.widthAnchor.constraint(equalToConstant: 200),
      sessionStatusLabel.heightAnchor.constraint(equalToConstant: 30)
    ])
  }
  
  private func setupPostureUI() {
    // Create posture label
    postureLabel = UILabel()
    postureLabel.text = "Posture: --"
    postureLabel.textColor = .white
    postureLabel.font = UIFont.boldSystemFont(ofSize: 20)
    postureLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
    postureLabel.textAlignment = .center
    postureLabel.layer.cornerRadius = 8
    postureLabel.clipsToBounds = true
    postureLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(postureLabel)
    
    // Create posture debug label
    postureDebugLabel = UILabel()
    postureDebugLabel.text = ""
    postureDebugLabel.textColor = UIColor(white: 0.8, alpha: 1.0)
    postureDebugLabel.font = UIFont.systemFont(ofSize: 12)
    postureDebugLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
    postureDebugLabel.textAlignment = .left
    postureDebugLabel.layer.cornerRadius = 8
    postureDebugLabel.clipsToBounds = true
    postureDebugLabel.numberOfLines = 0
    postureDebugLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(postureDebugLabel)
    
    // Layout constraints
    NSLayoutConstraint.activate([
      // Posture label - below session status
      postureLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      postureLabel.topAnchor.constraint(equalTo: sessionStatusLabel.bottomAnchor, constant: 10),
      postureLabel.widthAnchor.constraint(equalToConstant: 250),
      postureLabel.heightAnchor.constraint(equalToConstant: 40),
      
      // Posture debug label - below posture label
      postureDebugLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 30),
      postureDebugLabel.topAnchor.constraint(equalTo: postureLabel.bottomAnchor, constant: 10),
      postureDebugLabel.widthAnchor.constraint(equalToConstant: 350),
      postureDebugLabel.heightAnchor.constraint(equalToConstant: 60)
    ])
  }
  
  @objc private func toggleSession() {
    if SessionManager.shared.getSessionActive() {
      // Get frame count before stopping
      let frameCount = SessionManager.shared.getLandmarkCount()
      
      // Stop session and save to Firebase
      SessionManager.shared.stopSession(saveToFirebase: true) { [weak self] result in
        DispatchQueue.main.async {
          switch result {
          case .success(let documentId):
            print("Session saved to Firebase with document ID: \(documentId)")
            // Show success message
            let successAlert = UIAlertController(
              title: "Session Saved",
              message: "Captured \(frameCount) frames\nSaved to Firebase successfully",
              preferredStyle: .alert
            )
            successAlert.addAction(UIAlertAction(title: "OK", style: .default))
            self?.present(successAlert, animated: true)
          case .failure(let error):
            print("Failed to save session: \(error.localizedDescription)")
            // Show error alert
            let errorAlert = UIAlertController(
              title: "Save Error",
              message: "Failed to save session to Firebase: \(error.localizedDescription)",
              preferredStyle: .alert
            )
            errorAlert.addAction(UIAlertAction(title: "OK", style: .default))
            self?.present(errorAlert, animated: true)
          }
        }
      }
      
      sessionButton.isSelected = false
      sessionButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.8)
      updateSessionStatus()
      stopSessionUpdateTimer()
      
      // Show alert with session summary
      let alert = UIAlertController(
        title: "Session Stopped",
        message: "Captured \(frameCount) landmark frames\nUploading final batch to Firebase...",
        preferredStyle: .alert
      )
      alert.addAction(UIAlertAction(title: "OK", style: .default))
      present(alert, animated: true)
    } else {
      // Start session with image dimensions for posture calculation
      let imageSize = cameraFeedService.videoResolution
      SessionManager.shared.startSession(imageWidth: imageSize.width, imageHeight: imageSize.height)
      sessionButton.isSelected = true
      sessionButton.backgroundColor = UIColor.systemRed.withAlphaComponent(0.8)
      updateSessionStatus()
      startSessionUpdateTimer()
    }
  }
  
  private func updateSessionStatus() {
    let isActive = SessionManager.shared.getSessionActive()
    if isActive {
      let count = SessionManager.shared.getLandmarkCount()
      let duration = SessionManager.shared.getSessionDuration() ?? 0
      sessionStatusLabel.text = "Recording: \(count) frames | \(String(format: "%.1f", duration))s"
      sessionStatusLabel.backgroundColor = UIColor.systemRed.withAlphaComponent(0.8)
    } else {
      sessionStatusLabel.text = "Session: Stopped"
      sessionStatusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
    }
  }
  
  private func startSessionUpdateTimer() {
    sessionUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      self?.updateSessionStatus()
    }
  }
  
  private func stopSessionUpdateTimer() {
    sessionUpdateTimer?.invalidate()
    sessionUpdateTimer = nil
  }
  
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    cameraFeedService.updateVideoPreviewLayer(toFrame: previewView.bounds)
  }
  
  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    cameraFeedService.updateVideoPreviewLayer(toFrame: previewView.bounds)
  }
#endif
  
  // Resume camera session when click button resume
  @IBAction func onClickResume(_ sender: Any) {
    cameraFeedService.resumeInterruptedSession {[weak self] isSessionRunning in
      if isSessionRunning {
        self?.resumeButton.isHidden = true
        self?.cameraUnavailableLabel.isHidden = true
        self?.initializePoseLandmarkerServiceOnSessionResumption()
      }
    }
  }
  
  // Switch between front and back camera
  @IBAction func onClickCameraSwitch(_ sender: Any) {
    cameraFeedService.switchCameraPosition()
  }
  
  private func presentCameraPermissionsDeniedAlert() {
    let alertController = UIAlertController(
      title: "Camera Permissions Denied",
      message:
        "Camera permissions have been denied for this app. You can change this by going to Settings",
      preferredStyle: .alert)
    
    let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
    let settingsAction = UIAlertAction(title: "Settings", style: .default) { (action) in
      UIApplication.shared.open(
        URL(string: UIApplication.openSettingsURLString)!, options: [:], completionHandler: nil)
    }
    alertController.addAction(cancelAction)
    alertController.addAction(settingsAction)
    
    present(alertController, animated: true, completion: nil)
  }
  
  private func presentVideoConfigurationErrorAlert() {
    let alert = UIAlertController(
      title: "Camera Configuration Failed",
      message: "There was an error while configuring camera.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
    
    self.present(alert, animated: true)
  }
  
  private func initializePoseLandmarkerServiceOnSessionResumption() {
    clearAndInitializePoseLandmarkerService()
    startObserveConfigChanges()
  }
  
  @objc private func clearAndInitializePoseLandmarkerService() {
    poseLandmarkerService = nil
    // Reset timestamp counter when reinitializing pose landmarker
    timestampQueue.async { [weak self] in
      self?.lastTimestamp = 0
    }
    poseLandmarkerService = PoseLandmarkerService
      .liveStreamPoseLandmarkerService(
        modelPath: InferenceConfigurationManager.sharedInstance.model.modelPath,
        numPoses: InferenceConfigurationManager.sharedInstance.numPoses,
        minPoseDetectionConfidence: InferenceConfigurationManager.sharedInstance.minPoseDetectionConfidence,
        minPosePresenceConfidence: InferenceConfigurationManager.sharedInstance.minPosePresenceConfidence,
        minTrackingConfidence: InferenceConfigurationManager.sharedInstance.minTrackingConfidence,
        liveStreamDelegate: self,
        delegate: InferenceConfigurationManager.sharedInstance.delegate)
  }
  
  private func clearPoseLandmarkerServiceOnSessionInterruption() {
    stopObserveConfigChanges()
    poseLandmarkerService = nil
  }
  
  private func startObserveConfigChanges() {
    NotificationCenter.default
      .addObserver(self,
                   selector: #selector(clearAndInitializePoseLandmarkerService),
                   name: InferenceConfigurationManager.notificationName,
                   object: nil)
    isObserving = true
  }
  
  private func stopObserveConfigChanges() {
    if isObserving {
      NotificationCenter.default
        .removeObserver(self,
                        name:InferenceConfigurationManager.notificationName,
                        object: nil)
    }
    isObserving = false
  }
}

extension CameraViewController: CameraFeedServiceDelegate {
  
  func didOutput(sampleBuffer: CMSampleBuffer, orientation: UIImage.Orientation) {
    // Generate monotonic timestamp to ensure MediaPipe receives strictly increasing timestamps
    let timestamp = timestampQueue.sync { [weak self] in
      guard let self = self else { return 0 }
      let currentTimeMs = Int(Date().timeIntervalSince1970 * 1000)
      // Ensure timestamp is always greater than the last one
      if currentTimeMs <= self.lastTimestamp {
        self.lastTimestamp += 1
      } else {
        self.lastTimestamp = currentTimeMs
      }
      return self.lastTimestamp
    }
    
    // Pass the pixel buffer to mediapipe
    backgroundQueue.async { [weak self] in
      self?.poseLandmarkerService?.detectAsync(
        sampleBuffer: sampleBuffer,
        orientation: orientation,
        timeStamps: timestamp)
    }
  }
  
  // MARK: Session Handling Alerts
  func sessionWasInterrupted(canResumeManually resumeManually: Bool) {
    // Updates the UI when session is interupted.
    if resumeManually {
      resumeButton.isHidden = false
    } else {
      cameraUnavailableLabel.isHidden = false
    }
    clearPoseLandmarkerServiceOnSessionInterruption()
  }
  
  func sessionInterruptionEnded() {
    // Updates UI once session interruption has ended.
    cameraUnavailableLabel.isHidden = true
    resumeButton.isHidden = true
    initializePoseLandmarkerServiceOnSessionResumption()
  }
  
  func didEncounterSessionRuntimeError() {
    // Handles session run time error by updating the UI and providing a button if session can be
    // manually resumed.
    resumeButton.isHidden = false
    clearPoseLandmarkerServiceOnSessionInterruption()
  }
}

// MARK: PoseLandmarkerServiceLiveStreamDelegate
extension CameraViewController: PoseLandmarkerServiceLiveStreamDelegate {

  func poseLandmarkerService(
    _ poseLandmarkerService: PoseLandmarkerService,
    didFinishDetection result: ResultBundle?,
    error: Error?) {
      DispatchQueue.main.async { [weak self] in
        guard let weakSelf = self else { return }
        weakSelf.inferenceResultDeliveryDelegate?.didPerformInference(result: result)
        guard let poseLandmarkerResult = result?.poseLandmarkerResults.first as? PoseLandmarkerResult else { return }
        
        let imageSize = weakSelf.cameraFeedService.videoResolution
        
        // Calculate posture on main thread (safe access to landmarks) - used for both storage and UI
        var postureResult: PostureDetectionResult? = nil
        if let firstPoseLandmarks = poseLandmarkerResult.landmarks.first {
          postureResult = PostureDetectionService.detectPosture(
            from: firstPoseLandmarks,
            imageWidth: imageSize.width,
            imageHeight: imageSize.height
          )
          
          // Update posture UI
          if let posture = postureResult {
            weakSelf.postureLabel.text = "Posture: \(posture.postureType.label)"
            weakSelf.postureLabel.backgroundColor = posture.postureType.color.withAlphaComponent(0.8)
            
            let viewAngle = posture.isSideView ? "SIDE" : (posture.isFacingLeft ? "LEFT" : "RIGHT")
            let debugText = String(format: "T1:%.0f T2:%.0f T3:%.0f T4:%.0f\nView: %@",
                                   posture.theta1, posture.theta2, posture.theta3, posture.theta4,
                                   viewAngle)
            weakSelf.postureDebugLabel.text = debugText
          } else {
            weakSelf.postureLabel.text = "Posture: --"
            weakSelf.postureLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
            weakSelf.postureDebugLabel.text = ""
          }
        }
        
        // Store landmarks if session is active (with pre-calculated posture)
        if SessionManager.shared.getSessionActive() {
          SessionManager.shared.addLandmarks(poseLandmarkerResult, posture: postureResult)
        }
        
        let poseOverlays = OverlayView.poseOverlays(
            fromMultiplePoseLandmarks: poseLandmarkerResult.landmarks,
          inferredOnImageOfSize: imageSize,
          ovelayViewSize: weakSelf.overlayView.bounds.size,
          imageContentMode: weakSelf.overlayView.imageContentMode,
          andOrientation: UIImage.Orientation.from(
            deviceOrientation: UIDevice.current.orientation))
        
        weakSelf.overlayView.postureResult = postureResult
        weakSelf.overlayView.draw(poseOverlays: poseOverlays,
                         inBoundsOfContentImageOfSize: imageSize,
                         imageContentMode: weakSelf.cameraFeedService.videoGravity.contentMode)
      }
    }
}

// MARK: - AVLayerVideoGravity Extension
extension AVLayerVideoGravity {
  var contentMode: UIView.ContentMode {
    switch self {
    case .resizeAspectFill:
      return .scaleAspectFill
    case .resizeAspect:
      return .scaleAspectFit
    case .resize:
      return .scaleToFill
    default:
      return .scaleAspectFill
    }
  }
}
