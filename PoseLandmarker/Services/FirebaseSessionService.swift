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
import FirebaseFirestore
import MediaPipeTasksVision

/**
 * Serializable models for Firebase storage
 * Stores world coordinates (in meters) for pose landmarks
 */
struct LandmarkData: Codable {
  let x: Float
  let y: Float
  let z: Float
  let visibility: Float?
  let presence: Float?
  
  // Initializer for NormalizedLandmark (kept for backward compatibility if needed)
  init(from landmark: NormalizedLandmark) {
    self.x = landmark.x
    self.y = landmark.y
    self.z = landmark.z
    self.visibility = landmark.visibility?.floatValue
    self.presence = landmark.presence?.floatValue
  }
  
  // Initializer for Landmark (world coordinates) - used for storage
  init(from landmark: Landmark) {
    self.x = landmark.x
    self.y = landmark.y
    self.z = landmark.z
    self.visibility = landmark.visibility?.floatValue
    self.presence = landmark.presence?.floatValue
  }
}

/**
 * Represents a single pose (person) with its landmarks
 * This structure avoids nested arrays which Firestore doesn't support
 */
struct PoseData: Codable {
  let landmarks: [LandmarkData]
  
  init(landmarks: [LandmarkData]) {
    self.landmarks = landmarks
  }
}

/**
 * Posture information for a frame
 */
struct PostureInfo: Codable {
  let postureType: String  // "good", "lPosture", "tPosture"
  let theta1: Double  // Angle between head and neck
  let theta2: Double  // Angle between neck and chest
  let theta3: Double  // Angle between chest and hip
  let theta4: Double  // Weighted angle
  let isSideView: Bool
  
  init(from postureResult: PostureDetectionResult) {
    // Convert posture type to string
    switch postureResult.postureType {
    case .good:
      self.postureType = "good"
    case .lPosture:
      self.postureType = "lPosture"
    case .tPosture:
      self.postureType = "tPosture"
    }
    self.theta1 = postureResult.theta1
    self.theta2 = postureResult.theta2
    self.theta3 = postureResult.theta3
    self.theta4 = postureResult.theta4
    self.isSideView = postureResult.isSideView
  }
}

struct PoseFrameData: Codable {
  let timestamp: Date
  let poses: [PoseData]  // Changed from [[LandmarkData]] to [PoseData]
  let posture: PostureInfo?  // Posture information (calculated on main thread, stored separately)
  
  init(from result: PoseLandmarkerResult, timestamp: Date, posture: PostureDetectionResult? = nil) {
    self.timestamp = timestamp
    // Use worldLandmarks (world coordinates in meters) for storage
    // Note: Display still uses normalized landmarks from result.landmarks
    self.poses = result.worldLandmarks.map { poseWorldLandmarks in
      let landmarks = poseWorldLandmarks.map { LandmarkData(from: $0) }
      return PoseData(landmarks: landmarks)
    }
    
    // Use pre-calculated posture if provided
    self.posture = posture.map { PostureInfo(from: $0) }
  }
}

struct SessionData: Codable {
  let sessionId: String
  let startTime: Date
  let endTime: Date
  let duration: TimeInterval
  let frameCount: Int
  let frames: [PoseFrameData]
  
  init(sessionId: String, startTime: Date, endTime: Date, frames: [PoseFrameData]) {
    self.sessionId = sessionId
    self.startTime = startTime
    self.endTime = endTime
    self.duration = endTime.timeIntervalSince(startTime)
    self.frameCount = frames.count
    self.frames = frames
  }
}

/**
 * Service to handle Firebase Firestore operations for pose landmark sessions
 */
class FirebaseSessionService {
  static let shared = FirebaseSessionService()
  private let db = Firestore.firestore()
  private let sessionsCollection = "pose_sessions"
  
  private init() {}
  
  /**
   * Saves a session to Firestore
   * @param sessionData The session data to save
   * @param completion Optional completion handler with document ID or error
   */
  func saveSession(
    _ sessionData: SessionData,
    completion: ((Result<String, Error>) -> Void)? = nil
  ) {
    do {
      // Convert to dictionary for Firestore
      let encoder = Firestore.Encoder()
      let data = try encoder.encode(sessionData)
      
      // Add document to Firestore
      var ref: DocumentReference?
      ref = db.collection(sessionsCollection).addDocument(data: data) { error in
        if let error = error {
          print("Error saving session to Firebase: \(error.localizedDescription)")
          completion?(.failure(error))
        } else if let documentId = ref?.documentID {
          print("Session saved successfully with ID: \(documentId)")
          completion?(.success(documentId))
        }
      }
    } catch {
      print("Error encoding session data: \(error.localizedDescription)")
      completion?(.failure(error))
    }
  }
  
  /**
   * Creates a SessionData object from landmarks and metadata
   */
  func createSessionData(
    sessionId: String,
    startTime: Date,
    endTime: Date,
    landmarks: [PoseLandmarkerResult]
  ) -> SessionData {
    let frames = landmarks.enumerated().map { index, result in
      // Use startTime + estimated time offset for each frame
      let frameTimestamp = startTime.addingTimeInterval(Double(index) * 0.033) // ~30fps
      return PoseFrameData(from: result, timestamp: frameTimestamp)
    }
    
    return SessionData(
      sessionId: sessionId,
      startTime: startTime,
      endTime: endTime,
      frames: frames
    )
  }
  
  /**
   * Uploads a batch of frames to a session subcollection
   * All frames are stored under one session using subcollections
   */
  func uploadFrameBatch(
    sessionId: String,
    frames: [PoseFrameData],
    userId: String,
    completion: ((Result<Int, Error>) -> Void)? = nil
  ) {
    let batch = db.batch()
    let framesRef = db.collection("users")
      .document(userId)
      .collection(sessionsCollection)
      .document(sessionId)
      .collection("frames")
    
    for frame in frames {
      let frameRef = framesRef.document()
      do {
        let encoder = Firestore.Encoder()
        let data = try encoder.encode(frame)
        batch.setData(data, forDocument: frameRef)
      } catch {
        print("Error encoding frame: \(error.localizedDescription)")
        completion?(.failure(error))
        return
      }
    }
    
    batch.commit { error in
      if let error = error {
        print("Error uploading batch: \(error.localizedDescription)")
        completion?(.failure(error))
      } else {
        print("Successfully uploaded batch of \(frames.count) frames")
        completion?(.success(frames.count))
      }
    }
  }
  
  /**
   * Creates or updates session metadata document
   * This is the main document for the session
   */
  func createOrUpdateSessionMetadata(
    sessionId: String,
    startTime: Date,
    frameCount: Int,
    userId: String,
    isActive: Bool = true
  ) {
    let sessionRef = db.collection("users")
      .document(userId)
      .collection(sessionsCollection)
      .document(sessionId)
    sessionRef.setData([
      "sessionId": sessionId,
      "startTime": startTime,
      "frameCount": frameCount,
      "isActive": isActive,
      "lastUpdated": Date()
    ], merge: true) { error in
      if let error = error {
        print("Error updating session metadata: \(error.localizedDescription)")
      }
    }
  }
  
  /**
   * Finalizes session by updating metadata with end time
   */
  func finalizeSession(
    sessionId: String,
    endTime: Date,
    userId: String,
    completion: ((Result<String, Error>) -> Void)? = nil
  ) {
    let sessionRef = db.collection("users")
      .document(userId)
      .collection(sessionsCollection)
      .document(sessionId)
    
    // Get start time first to calculate duration
    sessionRef.getDocument { document, error in
      if let error = error {
        completion?(.failure(error))
        return
      }
      
      guard let data = document?.data(),
            let startTime = (data["startTime"] as? Timestamp)?.dateValue() else {
        completion?(.failure(NSError(domain: "SessionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not retrieve session start time"])))
        return
      }
      
      let duration = endTime.timeIntervalSince(startTime)
      
      sessionRef.updateData([
        "endTime": endTime,
        "isActive": false,
        "duration": duration,
        "lastUpdated": Date()
      ]) { error in
        if let error = error {
          completion?(.failure(error))
        } else {
          print("Session finalized successfully: \(sessionId)")
          completion?(.success(sessionId))
        }
      }
    }
  }
  
  /**
   * Fetches all sessions from Firestore
   */
  func fetchAllSessions(completion: @escaping (Result<[SessionData], Error>) -> Void) {
    db.collection(sessionsCollection)
      .order(by: "startTime", descending: true)
      .getDocuments { snapshot, error in
        if let error = error {
          completion(.failure(error))
          return
        }
        
        guard let documents = snapshot?.documents else {
          completion(.success([]))
          return
        }
        
        let decoder = Firestore.Decoder()
        let sessions = documents.compactMap { doc -> SessionData? in
          try? decoder.decode(SessionData.self, from: doc.data())
        }
        completion(.success(sessions))
      }
  }
}

