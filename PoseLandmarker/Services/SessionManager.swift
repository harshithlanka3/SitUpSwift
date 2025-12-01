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

import Foundation
import MediaPipeTasksVision

/**
 * Manages recording sessions for pose landmarks.
 * Uses batch uploading to Firebase to avoid memory issues.
 * All frames are stored under one session using Firestore subcollections.
 */
class SessionManager {
  static let shared = SessionManager()
  
  private var isSessionActive: Bool = false
  private var currentBatch: [PoseLandmarkerResult] = []  // Small buffer (max batchSize frames)
  private var sessionStartTime: Date?
  private var sessionId: String?
  private var totalFrameCount: Int = 0
  private var imageWidth: CGFloat? = nil  // Store image dimensions for posture calculation
  private var imageHeight: CGFloat? = nil
  // Thread-safe storage for posture data by frame index
  private var postureData: [Int: PostureDetectionResult] = [:]
  private let postureQueue = DispatchQueue(label: "com.mediapipe.sessionManager.posture", attributes: .concurrent)
  private let batchSize = 50  // Upload every 50 frames to keep memory low
  private let queue = DispatchQueue(label: "com.mediapipe.sessionManager", attributes: .concurrent)
  
  private init() {}
  
  /**
   * Starts a new recording session.
   * Clears any previous session data and creates session metadata in Firebase.
   * @param imageWidth Optional image width for posture calculation
   * @param imageHeight Optional image height for posture calculation
   */
  func startSession(imageWidth: CGFloat? = nil, imageHeight: CGFloat? = nil) {
    queue.async(flags: .barrier) { [weak self] in
      guard let self = self else { return }
      self.isSessionActive = true
      self.currentBatch.removeAll()
      self.sessionStartTime = Date()
      self.sessionId = UUID().uuidString
      self.totalFrameCount = 0
      self.imageWidth = imageWidth
      self.imageHeight = imageHeight
      
      // Clear posture data
      self.postureQueue.async(flags: .barrier) {
        self.postureData.removeAll()
      }
      
      // Create session metadata document in Firebase
      if let sessionId = self.sessionId, 
         let startTime = self.sessionStartTime,
         let userId = UserAuthService.shared.currentUserId {
        FirebaseSessionService.shared.createOrUpdateSessionMetadata(
          sessionId: sessionId,
          startTime: startTime,
          frameCount: 0,
          userId: userId
        )
      }
    }
  }
  
  /**
   * Stops the current recording session.
   * Uploads any remaining frames in the buffer and finalizes the session.
   */
  func stopSession(saveToFirebase: Bool = true, completion: ((Result<String, Error>) -> Void)? = nil) {
    var sessionId: String?
    var startTime: Date?
    let endTime = Date()
    
    // First, mark session as inactive to stop accepting new frames
    queue.sync(flags: .barrier) {
      self.isSessionActive = false
      sessionId = self.sessionId
      startTime = self.sessionStartTime
    }
    
    // Wait for all pending operations to complete
    let waitGroup = DispatchGroup()
    waitGroup.enter()
    queue.async(flags: .barrier) {
      // This barrier ensures all pending addLandmarks operations complete
      waitGroup.leave()
    }
    waitGroup.wait()
    
    // Capture the final batch after all operations have completed
    var finalBatch: [PoseLandmarkerResult] = []
    var frameCount: Int = 0
    
    queue.sync(flags: .barrier) {
      finalBatch = self.currentBatch
      frameCount = self.totalFrameCount
      self.currentBatch.removeAll()
    }
    
    // Upload final batch if any remaining frames
    if saveToFirebase, 
       let sessionId = sessionId, 
       let startTime = startTime,
       let userId = UserAuthService.shared.currentUserId,
       !finalBatch.isEmpty {
      uploadBatch(
        sessionId: sessionId,
        startTime: startTime,
        batch: finalBatch,
        frameOffset: frameCount - finalBatch.count,
        userId: userId,
        completion: { (uploadResult: Result<Int, Error>) in
          // After final batch upload, finalize session
          if case .success = uploadResult {
            FirebaseSessionService.shared.finalizeSession(
              sessionId: sessionId,
              endTime: endTime,
              userId: userId
            ) { result in
              completion?(result)
            }
          } else {
            // Even if upload fails, try to finalize
            FirebaseSessionService.shared.finalizeSession(
              sessionId: sessionId,
              endTime: endTime,
              userId: userId
            ) { result in
              completion?(result)
            }
          }
        }
      )
    } else if saveToFirebase, 
              let sessionId = sessionId,
              let userId = UserAuthService.shared.currentUserId {
      // No remaining frames, just finalize
      FirebaseSessionService.shared.finalizeSession(
        sessionId: sessionId,
        endTime: endTime,
        userId: userId
      ) { result in
        completion?(result)
      }
    } else {
      // Not saving to Firebase
      completion?(.success(sessionId ?? ""))
    }
    
    // Clean up
    queue.async(flags: .barrier) { [weak self] in
      self?.sessionId = nil
      self?.sessionStartTime = nil
      self?.totalFrameCount = 0
      self?.imageWidth = nil
      self?.imageHeight = nil
    }
    
    // Clear posture data
    postureQueue.async(flags: .barrier) { [weak self] in
      self?.postureData.removeAll()
    }
  }
  
  /**
   * Adds landmarks to the current session if active.
   * Automatically uploads batch when batchSize is reached.
   * @param result The pose landmarker result
   * @param posture Optional posture detection result (calculated on main thread)
   */
  func addLandmarks(_ result: PoseLandmarkerResult?, posture: PostureDetectionResult? = nil) {
    guard let result = result else { return }
    
    queue.async(flags: .barrier) { [weak self] in
      guard let self = self, self.isSessionActive else { return }
      
      let currentFrameIndex = self.totalFrameCount
      self.currentBatch.append(result)
      self.totalFrameCount += 1
      
      // Store posture data if provided (thread-safe)
      if let posture = posture {
        self.postureQueue.async(flags: .barrier) {
          self.postureData[currentFrameIndex] = posture
        }
      }
      
      // Upload batch when it reaches batchSize
      if self.currentBatch.count >= self.batchSize {
        let batchToUpload = self.currentBatch
        let frameOffset = self.totalFrameCount - batchToUpload.count
        self.currentBatch.removeAll()  // Clear buffer after copying
        
        // Upload asynchronously
        if let sessionId = self.sessionId, 
           let startTime = self.sessionStartTime,
           let userId = UserAuthService.shared.currentUserId {
          self.uploadBatch(
            sessionId: sessionId,
            startTime: startTime,
            batch: batchToUpload,
            frameOffset: frameOffset,
            userId: userId,
            completion: nil
          )
        }
      }
    }
  }
  
  /**
   * Uploads a batch of frames to Firebase
   */
  private func uploadBatch(
    sessionId: String,
    startTime: Date,
    batch: [PoseLandmarkerResult],
    frameOffset: Int,
    userId: String,
    completion: ((Result<Int, Error>) -> Void)? = nil
  ) {
    // Retrieve posture data for this batch (thread-safe read)
    let batchPostureData = postureQueue.sync { () -> [Int: PostureDetectionResult] in
      var batchPostures: [Int: PostureDetectionResult] = [:]
      for index in 0..<batch.count {
        let frameIndex = frameOffset + index
        if let posture = self.postureData[frameIndex] {
          batchPostures[frameIndex] = posture
        }
      }
      return batchPostures
    }
    
    // Convert to PoseFrameData asynchronously to avoid blocking
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let frames = batch.enumerated().map { index, result in
        let frameIndex = frameOffset + index
        let frameTimestamp = startTime.addingTimeInterval(Double(frameIndex) * 0.033) // ~30fps
        let posture = batchPostureData[frameIndex]
        return PoseFrameData(from: result, timestamp: frameTimestamp, posture: posture)
      }
      
      // Clean up posture data for this batch after creating frames
      self?.postureQueue.async(flags: .barrier) {
        for index in 0..<batch.count {
          let frameIndex = frameOffset + index
          self?.postureData.removeValue(forKey: frameIndex)
        }
      }
      
      // Upload batch to Firebase
      FirebaseSessionService.shared.uploadFrameBatch(
        sessionId: sessionId,
        frames: frames,
        userId: userId
      ) { [weak self] result in
        switch result {
        case .success(let count):
          print("Uploaded batch of \(count) frames to session \(sessionId)")
          // Update session metadata with current frame count
          if let self = self, 
             let sessionId = self.sessionId, 
             let startTime = self.sessionStartTime,
             let currentUserId = UserAuthService.shared.currentUserId {
            FirebaseSessionService.shared.createOrUpdateSessionMetadata(
              sessionId: sessionId,
              startTime: startTime,
              frameCount: self.totalFrameCount,
              userId: currentUserId
            )
          }
          completion?(result)
        case .failure(let error):
          print("Failed to upload batch: \(error.localizedDescription)")
          completion?(result)
        }
      }
    }
    
  }
  
  /**
   * Returns whether a session is currently active.
   */
  func getSessionActive() -> Bool {
    return queue.sync {
      return self.isSessionActive
    }
  }
  
  /**
   * Returns the count of landmarks captured in the current session.
   */
  func getLandmarkCount() -> Int {
    return queue.sync {
      return self.totalFrameCount
    }
  }
  
  /**
   * Returns the session duration in seconds.
   */
  func getSessionDuration() -> TimeInterval? {
    return queue.sync {
      guard let startTime = self.sessionStartTime else { return nil }
      return Date().timeIntervalSince(startTime)
    }
  }
  
  /**
   * Clears the current session data without stopping the session.
   */
  func clearSession() {
    queue.async(flags: .barrier) { [weak self] in
      guard let self = self else { return }
      self.currentBatch.removeAll()
      self.totalFrameCount = 0
      self.sessionStartTime = Date()
    }
  }
}

