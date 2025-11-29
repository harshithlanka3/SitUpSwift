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
import UIKit
import MediaPipeTasksVision

/**
 * Posture detection thresholds
 * 
 * Posture Types:
 * - Good Posture: Proper alignment of head, neck, chest, and hips
 * - L-Posture: Excessive forward lean (neck-chest and chest-hip angles too large)
 *   - Indicates slouching or forward head posture
 * - T-Posture: Head tilted forward with overall forward lean (head-neck and weighted angles too small)
 *   - Indicates "tech neck" or forward head posture with rounded shoulders
 * 
 * Note: When viewing from the side, angles naturally appear smaller, so we use adjusted thresholds
 */
struct PostureThresholds {
  // L-Posture thresholds (forward lean detection)
  static let th1: Double = 105.0  // Threshold for Neck-Chest angle
  static let th2: Double = 110.0  // Threshold for Chest-Hip angle
  
  // T-Posture thresholds (forward head posture)
  static let th3: Double = 70.0    // Threshold for Head-Neck angle (front view)
  static let th4: Double = 80.0    // Threshold for Weighted Angle (front view)
  
  // Adjusted thresholds for side view (more lenient)
  static let th3Side: Double = 50.0   // Threshold for Head-Neck angle (side view)
  static let th4Side: Double = 60.0   // Threshold for Weighted Angle (side view)
  
  // Threshold to detect if viewing from side (shoulder width vs height ratio)
  static let sideViewRatio: Double = 0.3  // If shoulder width/height < this, likely side view
}

/**
 * Posture classification result
 */
enum PostureType {
  case good
  case lPosture
  case tPosture
  
  var label: String {
    switch self {
    case .good: return "Good Posture"
    case .lPosture: return "L-Posture"
    case .tPosture: return "T-Posture"
    }
  }
  
  var color: UIColor {
    switch self {
    case .good: return UIColor.green
    case .lPosture: return UIColor(red: 0, green: 165/255.0, blue: 255/255.0, alpha: 1) // Orange
    case .tPosture: return UIColor.red
    }
  }
}

/**
 * Posture detection result containing angles and classification
 */
struct PostureDetectionResult {
  let postureType: PostureType
  let theta1: Double  // Angle between head and neck
  let theta2: Double  // Angle between neck and chest
  let theta3: Double  // Angle between chest and hip
  let theta4: Double  // Weighted angle
  let isFacingLeft: Bool
  let isSideView: Bool  // Whether viewing from side
  let headPoint: CGPoint
  let neckPoint: CGPoint
  let chestPoint: CGPoint
  let hipPoint: CGPoint
}

/**
 * Service for detecting posture from pose landmarks
 * Implements logic similar to PostureDetection.py
 */
class PostureDetectionService {
  
  /**
   * MediaPipe pose landmark indices
   */
  private struct LandmarkIndices {
    static let nose = 0
    static let leftShoulder = 11
    static let rightShoulder = 12
    static let leftHip = 23
    static let rightHip = 24
  }
  
  /**
   * Calculate midpoint between two points
   */
  private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
    return CGPoint(x: (a.x + b.x) / 2.0, y: (a.y + b.y) / 2.0)
  }
  
  /**
   * Calculate angle between two points in degrees
   * Returns absolute angle between 0 and 180
   */
  private static func angleBetween(_ p1: CGPoint, _ p2: CGPoint) -> Double {
    let dx = p1.x - p2.x
    let dy = p1.y - p2.y
    
    var angle = atan2(dy, dx) * 180.0 / .pi
    angle = abs(angle)
    
    if angle > 180 {
      angle = 360 - angle
    }
    
    return angle
  }
  
  /**
   * Detect if viewing from side based on shoulder width relative to body height
   */
  private static func isSideView(
    leftShoulder: CGPoint,
    rightShoulder: CGPoint,
    leftHip: CGPoint,
    rightHip: CGPoint
  ) -> Bool {
    let shoulderWidth = abs(leftShoulder.x - rightShoulder.x)
    let hipWidth = abs(leftHip.x - rightHip.x)
    let avgWidth = (shoulderWidth + hipWidth) / 2.0
    
    let bodyHeight = abs((leftShoulder.y + rightShoulder.y) / 2.0 - (leftHip.y + rightHip.y) / 2.0)
    
    // If width is very small relative to height, likely viewing from side
    if bodyHeight > 0 {
      let ratio = avgWidth / bodyHeight
      return ratio < PostureThresholds.sideViewRatio
    }
    return false
  }
  
  /**
   * Classify posture based on calculated angles
   * Uses adjusted thresholds for side views
   */
  private static func classifyPosture(
    theta1: Double,
    theta2: Double,
    theta3: Double,
    theta4: Double,
    isSideView: Bool
  ) -> PostureType {
    // L-Posture: theta2 > TH1 and theta3 > TH2 (forward lean)
    // This indicates excessive forward lean regardless of viewing angle
    if theta2 > PostureThresholds.th1 && theta3 > PostureThresholds.th2 {
      return .lPosture
    }
    
    // T-Posture: forward head posture
    // Use adjusted thresholds for side views since angles appear smaller
    let th3Threshold = isSideView ? PostureThresholds.th3Side : PostureThresholds.th3
    let th4Threshold = isSideView ? PostureThresholds.th4Side : PostureThresholds.th4
    
    if theta1 <= th3Threshold && theta4 <= th4Threshold {
      return .tPosture
    }
    
    return .good
  }
  
  /**
   * Detect posture from pose landmarks
   * Returns nil if insufficient landmarks are detected
   */
  static func detectPosture(
    from landmarks: [NormalizedLandmark],
    imageWidth: CGFloat,
    imageHeight: CGFloat
  ) -> PostureDetectionResult? {
    
    guard landmarks.count > max(
      LandmarkIndices.nose,
      LandmarkIndices.leftShoulder,
      LandmarkIndices.rightShoulder,
      LandmarkIndices.leftHip,
      LandmarkIndices.rightHip
    ) else {
      return nil
    }
    
    // Convert normalized landmarks to pixel coordinates
    let landmarksPx = landmarks.map { landmark in
      CGPoint(x: CGFloat(landmark.x) * imageWidth, y: CGFloat(landmark.y) * imageHeight)
    }
    
    // Determine orientation (facing left or right)
    let noseX = landmarksPx[LandmarkIndices.nose].x
    let leftShoulderX = landmarksPx[LandmarkIndices.leftShoulder].x
    let rightShoulderX = landmarksPx[LandmarkIndices.rightShoulder].x
    let avgShoulderX = (leftShoulderX + rightShoulderX) / 2.0
    let isFacingLeft = noseX < avgShoulderX
    
    // Mirror coordinates if facing left
    var mathLandmarks = landmarksPx
    if isFacingLeft {
      for i in 0..<mathLandmarks.count {
        mathLandmarks[i].x = imageWidth - mathLandmarks[i].x
      }
    }
    
    // Calculate key points
    let head = mathLandmarks[LandmarkIndices.nose]
    let leftShoulder = mathLandmarks[LandmarkIndices.leftShoulder]
    let rightShoulder = mathLandmarks[LandmarkIndices.rightShoulder]
    let leftHip = mathLandmarks[LandmarkIndices.leftHip]
    let rightHip = mathLandmarks[LandmarkIndices.rightHip]
    
    let neck = midpoint(leftShoulder, rightShoulder)
    let hip = midpoint(leftHip, rightHip)
    let chest = CGPoint(
      x: (leftShoulder.x + rightShoulder.x + leftHip.x + rightHip.x) / 4.0,
      y: (leftShoulder.y + rightShoulder.y + leftHip.y + rightHip.y) / 4.0
    )
    
    // Detect if viewing from side
    let isSideViewAngle = isSideView(
      leftShoulder: leftShoulder,
      rightShoulder: rightShoulder,
      leftHip: leftHip,
      rightHip: rightHip
    )
    
    // Calculate angles
    let theta1 = angleBetween(head, neck)
    let theta2 = angleBetween(neck, chest)
    let theta3 = angleBetween(chest, hip)
    let theta4 = (0.6 * theta1) + (0.2 * theta2) + (0.2 * theta3)
    
    // Classify posture with side view detection
    let postureType = classifyPosture(
      theta1: theta1,
      theta2: theta2,
      theta3: theta3,
      theta4: theta4,
      isSideView: isSideViewAngle
    )
    
    // Convert points back to original coordinate system for display
    var displayHead = head
    var displayNeck = neck
    var displayChest = chest
    var displayHip = hip
    
    if isFacingLeft {
      displayHead.x = imageWidth - head.x
      displayNeck.x = imageWidth - neck.x
      displayChest.x = imageWidth - chest.x
      displayHip.x = imageWidth - hip.x
    }
    
    return PostureDetectionResult(
      postureType: postureType,
      theta1: theta1,
      theta2: theta2,
      theta3: theta3,
      theta4: theta4,
      isFacingLeft: isFacingLeft,
      isSideView: isSideViewAngle,
      headPoint: displayHead,
      neckPoint: displayNeck,
      chestPoint: displayChest,
      hipPoint: displayHip
    )
  }
}

